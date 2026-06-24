import SwiftUI
import AVFoundation
import MapKit

// MARK: – FEEDBACK TRACKER
// Registra localmente qué matches ya respondieron la encuesta de cierre, para
// no volver a pedirla al viajero (incluso si fue el buddy quien cerró).
enum FeedbackTracker {
    private static let key = "buddy.feedbackSubmittedMatchIds"
    static func isSubmitted(_ matchId: String) -> Bool {
        (UserDefaults.standard.array(forKey: key) as? [String])?.contains(matchId) ?? false
    }
    static func markSubmitted(_ matchId: String) {
        var ids = (UserDefaults.standard.array(forKey: key) as? [String]) ?? []
        guard !ids.contains(matchId) else { return }
        ids.append(matchId)
        UserDefaults.standard.set(ids, forKey: key)
    }
}

// MARK: – CONTACTAR BUDDY SHEET

struct ContactarBuddyView: View {
    let journey: APIJourney
    var preselectedCategory: String? = nil
    /// Si viene seteado, se crea la solicitud de inmediato (la Home ya eligió
    /// categoría/texto) → el usuario aterriza directo en "buscando", sin repetir
    /// la pantalla de categorías.
    var initialRequest: (category: String, description: String?)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .loading
    @State private var match: APIMatch?
    @State private var pollTimer: Timer?
    @State private var sseMatchTask: Task<Void, Never>? = nil
    @State private var buddyCount: Int = 0
    @State private var activeRequestId: String? = nil   // solicitud en curso (para cancelarla)

    enum Phase: Equatable {
        case loading, selectCategory, searching, matched, error(String)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.canvas.ignoresSafeArea()
                switch phase {
                case .loading:        loadingView
                case .selectCategory: CategoryPickerView(buddyCount: buddyCount, preselectedCategory: preselectedCategory, onRequest: handleRequest)
                case .searching:      SearchingView(buddyCount: buddyCount, onCancel: cancelSearch)
                case .matched:        chatView
                case .error(let m):   errorView(m)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if phase == .selectCategory {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color.inkMuted)
                        }
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .task { await checkStatus() }
        .task { await loadBuddyCount() }
        .onDisappear { pollTimer?.invalidate() }
        // Dirigido por evento: el push "¡Tienes un buddy!" llega al aceptar → consulta UNA vez.
        // El timer queda solo como red de seguridad (15s), no como mecanismo principal.
        .onReceive(NotificationCenter.default.publisher(for: .pushReceivedForeground)) { _ in
            if phase == .searching { Task { await pollForMatch() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pushNotificationTapped)) { _ in
            if phase == .searching { Task { await pollForMatch() } }
        }
    }

    private var loadingView: some View {
        VStack { Spacer(); ProgressView().tint(Color.teal); Spacer() }
    }

    private var chatView: some View {
        Group {
            if let match { BuddyChatView(match: match, journey: journey, onDismiss: { dismiss() }) }
            else { loadingView }
        }
    }

    private func errorView(_ msg: String) -> some View {
        VStack(spacing: Spacing.md) {
            Spacer()
            Image(systemName: "exclamationmark.triangle").font(.system(size: 36)).foregroundStyle(Color.sand)
            Text(msg).font(BT.callout).foregroundStyle(Color.inkMuted).multilineTextAlignment(.center).padding(.horizontal, Spacing.edge)
            Button("Reintentar") { Task { await checkStatus() } }.font(BT.footnoteBold).foregroundStyle(Color.teal)
            Spacer()
        }
    }

    // MARK: Logic

    private func loadBuddyCount() async {
        let destIdOpt: String? = journey.destination?.id ?? journey.destinationId
        guard let destId = destIdOpt else { return }
        if let count = try? await APIClient.shared.fetchBuddyCount(destinationId: destId) {
            buddyCount = count
        }
    }

    private func checkStatus() async {
        phase = .loading
        guard let userId = AuthService.shared.userId else { phase = .error("Sin sesión."); return }
        do {
            let matches = try await APIClient.shared.fetchMatches(userId: userId)
            print("🔎 [checkStatus] userId=\(userId) — \(matches.count) match(es) recibidos")
            for m in matches {
                print("   • match id=\(m.id) status=\(m.status ?? "nil") travelerId=\(m.travelerId) buddyId=\(m.buddyId ?? "nil")")
            }
            // 'pending' = buddy recién asignado (el backend crea el match así).
            // Si ya hay un buddy vinculado, abrimos ESE chat en vez de permitir
            // pedir otro buddy.
            let activeStatuses = ["pending", "accepted", "active"]
            if let active = matches.first(where: { activeStatuses.contains($0.status ?? "") && $0.travelerId == userId }) {
                print("✅ [checkStatus] match activo encontrado id=\(active.id) status=\(active.status ?? "nil") → abriendo chat")
                match = active; phase = .matched; return
            }
            print("⚠️ [checkStatus] NINGÚN match activo para userId=\(userId) (status válidos: \(activeStatuses)) → buscando solicitudes abiertas")
            // La encuesta pendiente la presenta RootView globalmente (en cualquier
            // tab y en tiempo real), así que aquí no hace falta detectarla.
            let destIdOpt: String? = journey.destination?.id ?? journey.destinationId
            guard let destId = destIdOpt else { phase = .selectCategory; return }
            let requests = try await APIClient.shared.fetchOpenRequests(destinationId: destId)
            if let open = requests.first(where: { $0.travelerId == userId && $0.isActive }) {
                print("🔄 [checkStatus] solicitud abierta encontrada id=\(open.id) → searching")
                activeRequestId = open.id
                phase = .searching; startPolling(); startSSEMatch(requestId: open.id)
            } else if let seed = initialRequest {
                // La Home ya eligió → crear la solicitud directamente.
                print("⚡️ [checkStatus] initialRequest=\(seed.category) → solicitando directo")
                await handleRequest(category: seed.category, description: seed.description)
            } else {
                print("📋 [checkStatus] sin match ni solicitud → mostrando selector de categoría")
                phase = .selectCategory
            }
        } catch { phase = .error(error.localizedDescription) }
    }

    func handleRequest(category: String, description: String?) async {
        guard let userId = AuthService.shared.userId else { return }
        let destIdOpt2: String? = journey.destination?.id ?? journey.destinationId
        guard let destId = destIdOpt2 else { return }
        phase = .searching
        do {
            let req = try await APIClient.shared.createHelpRequest(
                travelerId: userId, destinationId: destId, journeyId: journey.id,
                category: category, description: description, arrivalAt: journey.arrivalAt)
            activeRequestId = req.id
            startPolling(); startSSEMatch(requestId: req.id)
        } catch { phase = .error(error.localizedDescription) }
    }

    private func cancelSearch() {
        pollTimer?.invalidate()
        stopSSEMatch()
        if let rid = activeRequestId {
            Task { try? await APIClient.shared.cancelHelpRequest(requestId: rid) }
            activeRequestId = nil
        }
        phase = .selectCategory
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { await pollForMatch() }
        }
    }

    private func startSSEMatch(requestId: String) {
        sseMatchTask?.cancel()
        guard let token = AuthService.shared.accessToken,
              let url = URL(string: "\(APIClient.shared.baseURL)/matching/request/\(requestId)/stream") else { return }

        sseMatchTask = Task {
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 300

            guard let (stream, _) = try? await URLSession.shared.bytes(for: request) else { return }
            do {
                for try await line in stream.lines {
                    guard !Task.isCancelled else { break }
                    if line.hasPrefix("event: matched") || line.hasPrefix("data:") {
                        await pollForMatch()
                    }
                }
            } catch { }
        }
    }

    private func stopSSEMatch() {
        sseMatchTask?.cancel()
        sseMatchTask = nil
    }

    private func pollForMatch() async {
        guard let userId = AuthService.shared.userId else { return }
        do {
            let matches = try await APIClient.shared.fetchMatches(userId: userId)
            let activeStatuses = ["pending", "accepted", "active"]
            if let active = matches.first(where: { activeStatuses.contains($0.status ?? "") && $0.travelerId == userId }) {
                pollTimer?.invalidate()
                stopSSEMatch()
                match = active
                withAnimation(.spring(response: 0.5, dampingFraction: 0.75)) { phase = .matched }
            }
        } catch { }
    }
}

// MARK: – CATEGORY PICKER

// Reutilizable: el mismo composer del modal se embebe en la Home para iniciar
// el flujo de ayuda sin pasos intermedios.
struct CategoryPickerView: View {
    var buddyCount: Int = 0
    var preselectedCategory: String? = nil
    let onRequest: (String, String?) async -> Void

    @State private var selected: BuddyCategory? = nil
    @State private var customText = ""
    @FocusState private var fieldFocused: Bool

    struct BuddyCategory: Identifiable {
        let id = UUID()
        let icon: String; let label: String; let apiKey: String
    }

    private let categories: [BuddyCategory] = [
        .init(icon: "map",              label: "Cómo llegar", apiKey: "transport"),
        .init(icon: "cup.and.saucer",   label: "Comer",       apiKey: "food"),
        .init(icon: "bubble.left",      label: "Traducir",    apiKey: "translation"),
        .init(icon: "sparkles",         label: "Qué hacer",   apiKey: "activities"),
        .init(icon: "bed.double",       label: "Alojamiento", apiKey: "accommodation"),
        .init(icon: "shield",           label: "Seguridad",   apiKey: "emergency"),
    ]

    private var canRequest: Bool {
        selected != nil || !customText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Nunca un "0" desangelado — la promesa es que siempre habrá alguien.
    private var availabilityText: String {
        if buddyCount <= 0 { return "Te conectamos con el primer buddy disponible" }
        return buddyCount == 1
            ? "1 buddy disponible para ti ahora"
            : "\(buddyCount) buddies disponibles para ti ahora"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Title — sin etiqueta redundante; el título ya explica la sección.
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 0) {
                    Text("¿En qué ").font(BT.title1).foregroundStyle(Color.ink)
                    Text("te ayudamos?").font(BT.displayLarge).foregroundStyle(Color.sand)
                }
                Text("Un local te responde en minutos.")
                    .font(BT.callout).foregroundStyle(Color.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, Spacing.edge)
            .padding(.top, Spacing.md)

            Spacer().frame(height: Spacing.xl)

            // 2×2 grid
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(categories) { cat in
                    Button {
                        withAnimation(.spring(response: 0.28)) {
                            selected = selected?.id == cat.id ? nil : cat
                        }
                        Haptic.light()
                        fieldFocused = false
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: cat.icon)
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(Color.teal)   // iconos teal — voz de iconografía del app
                            Text(cat.label)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(selected?.id == cat.id ? Color.teal : Color.ink)
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                            Spacer()
                        }
                        .padding(.horizontal, 16).padding(.vertical, 18)
                        .background(selected?.id == cat.id ? Color.teal.opacity(0.10) : Color.surface)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.md))
                        .overlay(RoundedRectangle(cornerRadius: Radius.md)
                            .stroke(selected?.id == cat.id ? Color.teal : Color.border,
                                    lineWidth: selected?.id == cat.id ? 1.5 : 1))
                    }
                    .buttonStyle(.pressable)
                }
            }
            .padding(.horizontal, Spacing.edge)

            Spacer().frame(height: Spacing.md)

            // Free text
            TextField("Cuéntanos qué necesitas…", text: $customText, axis: .vertical)
                .font(BT.callout).lineLimit(3).focused($fieldFocused)
                .onChange(of: customText) { _, v in if !v.isEmpty { selected = nil } }
                .padding(.horizontal, 16).padding(.vertical, 14)
                .background(Color.surface)
                .clipShape(RoundedRectangle(cornerRadius: Radius.md))
                .overlay(RoundedRectangle(cornerRadius: Radius.md)
                    .stroke(fieldFocused ? Color.teal : Color.border, lineWidth: 1))
                .padding(.horizontal, Spacing.edge)

            Spacer()

            VStack(spacing: 10) {
                Button {
                    guard canRequest else { return }
                    Haptic.medium()
                    let cat  = selected?.apiKey ?? "general"
                    let desc = customText.trimmingCharacters(in: .whitespaces)
                    Task { await onRequest(cat, desc.isEmpty ? nil : desc) }
                } label: {
                    Text("Pedir ayuda")
                        .font(BT.headline).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).frame(height: 52)
                        .background(canRequest ? Color.teal : Color.teal.opacity(0.35))
                        .clipShape(Capsule())
                }
                .disabled(!canRequest)

                VStack(spacing: 2) {
                    HStack(spacing: 5) {
                        Circle().fill(buddyCount > 0 ? Color.onlineGreen : Color.sand).frame(width: 6, height: 6)
                        Text(availabilityText).font(BT.caption1).foregroundStyle(Color.inkMuted)
                    }
                    if buddyCount > 0 {
                        Text("Suelen responder en pocos minutos")
                            .font(BT.caption2).foregroundStyle(Color.inkMuted.opacity(0.7))
                    }
                }
            }
            .padding(.horizontal, Spacing.edge)
            .padding(.bottom, Spacing.lg)
        }
        .onAppear {
            if let key = preselectedCategory, selected == nil {
                selected = categories.first { $0.apiKey == key }
            }
        }
    }
}

// MARK: – SEARCHING VIEW

private struct SearchingView: View {
    let buddyCount: Int
    let onCancel: () -> Void
    @State private var appear = false

    private var statusText: String {
        if buddyCount <= 0 { return "Avisaremos al primer buddy disponible" }
        return buddyCount == 1 ? "1 buddy disponible cerca" : "\(buddyCount) buddies disponibles cerca"
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Text("UN MOMENTO")
                .font(BT.eyebrow).tracking(3).foregroundStyle(Color.inkMuted)
                .padding(.bottom, 8)

            VStack(spacing: 0) {
                Text("Buscando").font(BT.title1).foregroundStyle(Color.ink)
                Text("un buddy para ti.").font(BT.displayLarge).foregroundStyle(Color.sand)
            }
            .multilineTextAlignment(.center)

            Text("Avisamos a los buddies disponibles cerca.\nSuele tomar solo unos minutos.")
                .font(BT.callout).foregroundStyle(Color.inkMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Spacing.sm)
                .padding(.horizontal, Spacing.edge)

            Spacer().frame(height: 52)

            // Radar — teal (el color "vivo/humano" del app), con un buddy al centro
            ZStack {
                ForEach([230, 160, 100], id: \.self) { size in
                    let s = CGFloat(size)
                    let delay = (230 - s) / 700.0
                    Circle()
                        .stroke(Color.teal.opacity(appear ? 0.18 : 0.0), lineWidth: 1)
                        .frame(width: s, height: s)
                        .scaleEffect(appear ? 1.0 : 0.7)
                        .animation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true).delay(delay), value: appear)
                }
                Circle()
                    .fill(Color.teal.opacity(0.12))
                    .frame(width: 64, height: 64)
                    .overlay(
                        Image(systemName: "person.wave.2.fill")
                            .font(.system(size: 24, weight: .medium))
                            .foregroundStyle(Color.teal)
                    )
            }
            .onAppear { appear = true }

            Spacer().frame(height: 52)

            HStack(spacing: 6) {
                Circle().fill(buddyCount > 0 ? Color.onlineGreen : Color.sand).frame(width: 6, height: 6)
                Text(statusText)
                    .font(.system(size: 15, weight: .medium)).foregroundStyle(Color.ink)
            }

            Spacer().frame(height: Spacing.xl)

            Button("Cancelar", action: onCancel)
                .font(BT.subhead).foregroundStyle(Color.inkMuted)

            Spacer().frame(height: 40)
        }
    }
}

// MARK: – BUDDY CHAT VIEW

struct BuddyChatView: View {
    let match: APIMatch
    let journey: APIJourney
    var onDismiss: (() -> Void)? = nil

    @EnvironmentObject private var locationService: LocationService

    @State private var matchStatus:   String = ""
    @State private var messages:      [APIMessage] = []
    @State private var inputText      = ""
    @State private var isSending      = false
    @State private var sseTask:       Task<Void, Never>?
    @StateObject private var recVM    = AudioRecorderVM()
    @Namespace private var bottomID
    @FocusState private var inputFocused: Bool
    @GestureState private var micDragX: CGFloat = .zero
    /// Burbuja optimista de audio: se muestra inmediatamente con el archivo local
    @State private var pendingAudioLocalURL: URL? = nil
    /// Card de cierre de ciclo — dismissible si el usuario quiere seguir
    @State private var closeCardDismissed = false
    @State private var showReportSheet    = false
    @State private var reportSent         = false
    /// Sheet de feedback antes de cerrar apoyo (solo viajero)
    @State private var showCloseSheet = false
    /// Modal de confirmación simple (solo buddy — no responde encuesta)
    @State private var showCloseConfirm = false
    @State private var isSendingLocation = false
    @State private var showAttachSheet   = false
    // Pagination
    @State private var hasMoreMessages = true
    @State private var isLoadingMore   = false

    /// Muestra la card si han pasado >10 min desde el inicio del match y el último msg es del buddy
    private var shouldShowCloseCard: Bool {
        guard matchStatus != "completed" else { return false }
        guard !closeCardDismissed, pendingAudioLocalURL == nil else { return false }
        guard let last = messages.last else { return false }
        let isFromBuddy = last.senderId != AuthService.shared.userId
        let matchStart = match.matchedAt ?? match.createdAt ?? Date()
        let tenMinPassed = Date().timeIntervalSince(matchStart) > 10 * 60
        return isFromBuddy && tenMinPassed
    }

    // When the current user is the buddy, show traveler info (not their own)
    private var isCurrentUserBuddy: Bool {
        AuthService.shared.userId == match.buddyId
    }
    private var buddyName: String {
        let person = isCurrentUserBuddy ? match.traveler : match.buddy
        return person?.fullName?.components(separatedBy: " ").first?.lowercased() ?? (isCurrentUserBuddy ? "viajero" : "buddy")
    }
    private var buddyInitials: String {
        let person = isCurrentUserBuddy ? match.traveler : match.buddy
        let name = person?.fullName ?? "?"
        return name.split(separator: " ").prefix(2).compactMap { $0.first.map(String.init) }.joined()
    }
    private var buddyAvatarUrl: String? {
        isCurrentUserBuddy ? match.traveler?.avatarUrl : match.buddy?.avatarUrl
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Header ──────────────────────────────────────────────
            HStack(spacing: 12) {
                Button { Haptic.light(); onDismiss?() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.ink)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .padding(.leading, -10)   // mantiene el glifo cerca del borde pese al target 44

                // Avatar
                Circle()
                    .fill(Color.sandLight)
                    .frame(width: 38, height: 38)
                    .overlay(
                        Text(buddyInitials)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Color.sand)
                    )
                    .overlay(alignment: .bottomTrailing) {
                        Circle().fill(Color.onlineGreen).frame(width: 10, height: 10)
                            .overlay(Circle().stroke(Color.surface, lineWidth: 1.5))
                    }

                VStack(alignment: .leading, spacing: 1) {
                    Text(buddyName)
                        .font(BT.headline)
                        .foregroundStyle(Color.ink)
                    Text("en línea")
                        .font(BT.caption1)
                        .foregroundStyle(Color.onlineGreen)
                }

                Spacer()

                Menu {
                    if matchStatus != "completed" {
                        Button(role: .destructive) {
                            requestClose()
                        } label: {
                            Label("Cerrar apoyo", systemImage: "checkmark.circle")
                        }
                    }
                    Divider()
                    Button(role: .destructive) {
                        showReportSheet = true
                    } label: {
                        Label("Reportar usuario", systemImage: "flag")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Color.ink)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
            }
            .padding(.horizontal, Spacing.edge)
            .padding(.vertical, 12)
            .background(Color.surface)
            .overlay(alignment: .bottom) { Divider() }

            // ── Dedicated banner ─────────────────────────────────────
            Text(isCurrentUserBuddy
                 ? "Estás acompañando a \(buddyName). Respóndele con calma; cuando todo esté resuelto, cierra el apoyo."
                 : "\(buddyName) está dedicado solo a ti. Cierra el ciclo cuando termines para que pueda ayudar a otro viajero.")
                .font(BT.caption1)
                .foregroundStyle(Color.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Spacing.edge)
                .padding(.vertical, 10)
                .background(Color.canvas)
                .overlay(alignment: .bottom) { Divider().opacity(0.5) }

            // ── Messages ─────────────────────────────────────────────
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        // Load-more trigger at top of list
                        if hasMoreMessages {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .onAppear { Task { await loadMoreMessages() } }
                        }
                        if messages.isEmpty {
                            welcomeMessage.padding(.top, Spacing.xl)
                        }
                        ForEach(Array(messages.enumerated()), id: \.element.id) { i, msg in
                            // Date separator
                            if i == 0 || !sameDay(messages[i-1].createdAt, msg.createdAt) {
                                dateSeparator(msg.createdAt)
                            }
                            BuddyMessageBubble(
                                message: msg,
                                isMe: msg.senderId != nil && msg.senderId == AuthService.shared.userId
                            )
                            .padding(.bottom, 4)
                        }
                        // Card de cierre de ciclo
                        if shouldShowCloseCard {
                            CloseCycleCard(buddyName: buddyName, isHelper: isCurrentUserBuddy) {
                                requestClose()
                            } onKeepOpen: {
                                // "tengo otra pregunta" — dismiss card
                                withAnimation { closeCardDismissed = true }
                            }
                            .padding(.top, 8)
                            .padding(.bottom, 4)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }

                        // Burbuja optimista — aparece al soltar el mic, desaparece cuando llega por SSE
                        if let localURL = pendingAudioLocalURL {
                            AudioPlayerBubble(audioUrl: localURL.absoluteString, isMe: true)
                            .padding(.bottom, 4)
                            .overlay(alignment: .bottomTrailing) {
                                // Indicador de "enviando…"
                                ProgressView()
                                    .scaleEffect(0.6)
                                    .padding(.trailing, 6)
                                    .padding(.bottom, 10)
                            }
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }
                        Color.clear.frame(height: 1).id(bottomID)
                    }
                    .padding(.horizontal, Spacing.edge)
                    .padding(.vertical, Spacing.md)
                }
                .onChange(of: messages.count) { _, _ in
                    withAnimation { proxy.scrollTo(bottomID, anchor: .bottom) }
                }
                .onChange(of: pendingAudioLocalURL) { _, _ in
                    withAnimation { proxy.scrollTo(bottomID, anchor: .bottom) }
                }
            }

            // ── Input bar ────────────────────────────────────────────
            if matchStatus == "completed" {
                closedBar
            } else {
                chatInputBar
            }
        }
        .background(Color.canvas)
        .navigationBarHidden(true)
        .background(KeyboardPrewarmer())
        .sheet(isPresented: $showCloseSheet) {
            CloseFeedbackSheet(buddyName: buddyName, buddyAvatarUrl: buddyAvatarUrl) { feeling, pressure in
                showCloseSheet = false
                Task { await closeMatch(feeling: feeling, pressure: pressure) }
            } onDismiss: {
                showCloseSheet = false
            }
        }
        .sheet(isPresented: $showReportSheet) {
            ReportUserSheet(
                buddyName: buddyName,
                matchId: match.id,
                reportedUserId: (isCurrentUserBuddy ? match.traveler?.id : match.buddy?.id) ?? ""
            ) {
                showReportSheet = false
                reportSent = true
            }
        }
        .toast(isPresented: $reportSent, message: "Reporte enviado. Lo revisaremos pronto.")
        .task {
            matchStatus = match.status
            await loadMessages()
            startSSE()
            await APIClient.shared.markMessagesRead(matchId: match.id)
            // La encuesta obligatoria (buddy cerró) la presenta RootView de forma
            // global; aquí solo manejamos el cierre iniciado por el viajero.
            await ChatStore.shared.load()
        }
        .onDisappear { sseTask?.cancel() }
        // Re-evalúa la card cada 60s (por si el tiempo supera los 10 min mientras el chat está abierto)
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
            if shouldShowCloseCard { closeCardDismissed = false }
        }
        // Confirmación simple para el buddy (no responde encuesta)
        .alert("¿Cerrar acompañamiento?", isPresented: $showCloseConfirm) {
            Button("Cancelar", role: .cancel) {}
            Button("Cerrar", role: .destructive) {
                Task { await closeAsHelper() }
            }
        } message: {
            Text("\(buddyName) quedará libre para acompañar a otro viajero.")
        }
    }

    /// Enruta el cierre según el rol: el buddy confirma; el viajero responde la
    /// encuesta de cierre.
    private func requestClose() {
        if isCurrentUserBuddy { showCloseConfirm = true }
        else                  { showCloseSheet = true }
    }

    // ── Conexión cerrada ─────────────────────────────────────────────
    private var closedBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.teal)
                .font(.system(size: 16))
            Text("Conexión cerrada · gracias por usar buddy")
                .font(BT.footnote)
                .foregroundStyle(Color.inkMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(Color.surface)
        .overlay(alignment: .top) { Divider() }
    }

    // ── WhatsApp-style input bar ──────────────────────────────────────
    private var chatInputBar: some View {
        let hasText = !inputText.trimmingCharacters(in: .whitespaces).isEmpty
        // Cancel threshold: drag left more than 100pt cancels recording
        let cancelled = micDragX < -100

        return Group {
            if recVM.isRecording {
                // ── Recording state: full-width bar with slide-to-cancel ──
                HStack(spacing: 0) {
                    // Blinking red dot + timer
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 8, height: 8)
                            .opacity(recVM.seconds % 2 == 0 ? 1 : 0.25)
                            .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true),
                                       value: recVM.seconds)
                        Text(fmtSecs(recVM.seconds))
                            .font(.system(size: 15, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color.ink)
                    }
                    .frame(width: 70, alignment: .leading)

                    Spacer()

                    // "< slide to cancel" — se desplaza con el dedo
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .medium))
                        Text("Desliza para cancelar")
                            .font(BT.callout)
                    }
                    .foregroundStyle(cancelled ? Color.red : Color.inkMuted)
                    .offset(x: max(micDragX, -120))
                    .animation(.interactiveSpring(), value: micDragX)

                    Spacer()

                    // Mic button (held, draggable, red pulse)
                    ZStack {
                        Circle()
                            .fill(cancelled ? Color.red.opacity(0.15) : Color.teal.opacity(0.15))
                            .frame(width: 54, height: 54)
                            .scaleEffect(1.1)
                            .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true),
                                       value: recVM.isRecording)
                        Image(systemName: "mic.fill")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(cancelled ? Color.red : Color.teal)
                            .frame(width: 42, height: 42)
                            .background(cancelled ? Color.red.opacity(0.1) : Color.teal.opacity(0.1))
                            .clipShape(Circle())
                    }
                    .offset(x: max(micDragX * 0.3, -40))
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .updating($micDragX) { val, state, _ in
                                state = min(0, val.translation.width) // only left
                            }
                            .onEnded { val in
                                if val.translation.width < -100 {
                                    recVM.cancel()
                                    Haptic.light()
                                } else {
                                    Task { await stopAndSendAudio() }
                                }
                            }
                    )
                }
                .padding(.horizontal, Spacing.edge)
                .padding(.vertical, 14)
                .background(Color.surface)
                .overlay(alignment: .top) { Divider() }
                .transition(.opacity)

            } else {
                // ── Normal state ──────────────────────────────────────
                HStack(spacing: 8) {
                    // + attach button
                    Button {
                        Haptic.light()
                        inputFocused = false
                        showAttachSheet = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Color.inkMuted)
                            .frame(width: 38, height: 38)
                            .background(Color.canvas)
                            .clipShape(Circle())
                            .overlay(Circle().stroke(Color.border, lineWidth: 1))
                    }

                    // Campo de texto (pill)
                    TextField("escríbele a \(buddyName)…", text: $inputText, axis: .vertical)
                        .font(BT.body)
                        .lineLimit(4)
                        .foregroundStyle(Color.ink)
                        .focused($inputFocused)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color.canvas)
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(Color.border, lineWidth: 1))

                    // Botón derecho: send si hay texto, mic si no
                    if hasText {
                        Button {
                            Task { await sendMessage() }
                        } label: {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 17, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 42, height: 42)
                                .background(isSending ? Color.teal.opacity(0.4) : Color.teal)
                                .clipShape(Circle())
                        }
                        .disabled(isSending)
                        .transition(.scale.combined(with: .opacity))
                    } else {
                        // Mic — hold to record, drag left to cancel
                        Image(systemName: "mic.fill")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(Color.inkMuted)
                            .frame(width: 42, height: 42)
                            .background(Color.canvas)
                            .clipShape(Circle())
                            .overlay(Circle().stroke(Color.border, lineWidth: 1))
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .updating($micDragX) { val, state, _ in
                                        state = min(0, val.translation.width)
                                    }
                                    .onChanged { _ in
                                        if !recVM.isRecording {
                                            Task {
                                                let ok = await recVM.start()
                                                if ok { Haptic.medium() }
                                            }
                                        }
                                    }
                                    .onEnded { val in
                                        if val.translation.width < -100 {
                                            recVM.cancel()
                                            Haptic.light()
                                        } else {
                                            // Siempre intentar enviar — stopAndSendAudio() hace guard internamente
                                            Task { await stopAndSendAudio() }
                                        }
                                    }
                            )
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .padding(.horizontal, Spacing.edge)
                .padding(.vertical, 10)
                .background(Color.surface)
                .overlay(alignment: .top) { Divider() }
                .animation(.spring(response: 0.25, dampingFraction: 0.8), value: hasText)
            }
        }
        .sheet(isPresented: $showAttachSheet) {
            attachSheet
                .presentationDetents([.height(200)])
                .presentationDragIndicator(.visible)
        }
    }

    private var attachSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Compartir")
                .font(BT.footnoteBold)
                .foregroundStyle(Color.inkMuted)
                .padding(.horizontal, Spacing.edge)
                .padding(.top, Spacing.md)
                .padding(.bottom, Spacing.sm)

            Divider()

            Button {
                showAttachSheet = false
                Task { await sendLocation() }
            } label: {
                HStack(spacing: Spacing.md) {
                    ZStack {
                        Circle()
                            .fill(Color.teal.opacity(0.12))
                            .frame(width: 44, height: 44)
                        Image(systemName: "location.fill")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(Color.teal)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ubicación actual")
                            .font(BT.footnoteBold)
                            .foregroundStyle(Color.ink)
                        Text("Comparte dónde estás ahora mismo")
                            .font(BT.caption1)
                            .foregroundStyle(Color.inkMuted)
                    }
                    Spacer()
                    if isSendingLocation {
                        ProgressView().tint(Color.teal)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.border)
                    }
                }
                .padding(.horizontal, Spacing.edge)
                .padding(.vertical, Spacing.md)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isSendingLocation)
        }
        .background(Color.canvas)
    }

    private var welcomeMessage: some View {
        VStack(spacing: Spacing.sm) {
            Circle()
                .fill(Color.sandLight)
                .frame(width: 64, height: 64)
                .overlay {
                    if let urlStr = buddyAvatarUrl, let url = URL(string: urlStr) {
                        AsyncImage(url: url) { img in img.resizable().scaledToFill() }
                            placeholder: { Color.sandLight }
                            .clipShape(Circle())
                    } else {
                        Text(buddyInitials)
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(Color.sand)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    Circle().fill(Color.onlineGreen).frame(width: 14, height: 14)
                        .overlay(Circle().stroke(Color.canvas, lineWidth: 2))
                }
            Text(isCurrentUserBuddy ? "Acompañando a \(buddyName)" : "Conectado con \(buddyName)")
                .font(BT.title3).foregroundStyle(Color.ink)
            Text(isCurrentUserBuddy
                 ? "Puedes ayudar a \(buddyName) con lo que necesite al llegar."
                 : "Tu buddy te ayudará con todo en \(journey.destination?.name ?? "tu destino").")
                .font(BT.callout).foregroundStyle(Color.inkMuted).multilineTextAlignment(.center)
        }
        .padding(Spacing.edge)
    }

    private func dateSeparator(_ date: Date?) -> some View {
        let label: String = {
            guard let d = date else { return "" }
            let f = DateFormatter()
            f.locale = Locale(identifier: "es_PE")
            f.dateFormat = "EEEE · H:mm"
            return f.string(from: d)
        }()
        return Text(label)
            .font(BT.caption1)
            .foregroundStyle(Color.inkMuted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.md)
    }

    private func sameDay(_ a: Date?, _ b: Date?) -> Bool {
        guard let a, let b else { return false }
        return Calendar.current.isDate(a, inSameDayAs: b)
    }

    private func loadMessages() async {
        do {
            let fetched = try await APIClient.shared.fetchMessages(matchId: match.id, limit: 30)
            messages = fetched
            hasMoreMessages = fetched.count == 30
        } catch {
            print("❌ loadMessages error → \(error)")
        }
    }

    private func loadMoreMessages() async {
        guard hasMoreMessages, !isLoadingMore, let oldest = messages.first?.createdAt else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let fetched = try await APIClient.shared.fetchMessages(matchId: match.id, limit: 30, before: oldest)
            if fetched.isEmpty {
                hasMoreMessages = false
            } else {
                messages = fetched + messages
                hasMoreMessages = fetched.count == 30
            }
        } catch {
            print("❌ loadMoreMessages error → \(error)")
        }
    }

    private func sendMessage() async {
        let text = inputText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, let userId = AuthService.shared.userId else { return }
        Haptic.light()
        inputText = ""; isSending = true
        if let msg = try? await APIClient.shared.sendMessage(matchId: match.id, senderId: userId, content: text) {
            messages.append(msg)
        }
        isSending = false
        Task { await ChatStore.shared.load() }
    }

    private func sendLocation() async {
        guard let loc = locationService.userLocation,
              let userId = AuthService.shared.userId else {
            Haptic.light()
            return
        }
        isSendingLocation = true
        let lat = loc.coordinate.latitude
        let lng = loc.coordinate.longitude
        let content = "location:\(lat),\(lng)"
        if let msg = try? await APIClient.shared.sendMessage(matchId: match.id, senderId: userId, content: content) {
            messages.append(msg)
        }
        isSendingLocation = false
        Task { await ChatStore.shared.load() }
    }

    private func stopAndSendAudio() async {
        guard let fileURL = recVM.stop() else { return }
        withAnimation(.spring(response: 0.3)) { pendingAudioLocalURL = fileURL }
        Haptic.light()
        do {
            let msg = try await recVM.upload(fileURL: fileURL, matchId: match.id)
            if !messages.contains(where: { $0.id == msg.id }) {
                messages.append(msg)
            }
            withAnimation(.easeOut(duration: 0.2)) { pendingAudioLocalURL = nil }
            try? FileManager.default.removeItem(at: fileURL)
        } catch {
            print("❌ audio send error: \(error)")
            withAnimation { pendingAudioLocalURL = nil }
        }
        Task { await ChatStore.shared.load() }
    }

    private func closeMatch(feeling: String, pressure: String) async {
        // El match puede estar ya en "completed" si fue el buddy quien cerró; ignoramos el error
        try? await APIClient.shared.updateMatchStatus(matchId: match.id, status: "completed")
        Task {
            try? await APIClient.shared.submitFeedback(matchId: match.id, feeling: feeling, commercialPressure: pressure)
        }
        FeedbackTracker.markSubmitted(match.id)   // viajero ya respondió → no volver a preguntar
        await MainActor.run {
            if ChatStore.shared.pendingFeedbackMatch?.id == match.id {
                ChatStore.shared.pendingFeedbackMatch = nil
            }
        }
        Haptic.success()
        Task { await ChatStore.shared.load() }
        NotificationCenter.default.post(name: .helpCompleted, object: nil)
        onDismiss?()
    }

    /// Cierre del buddy (quien ayuda): sin encuesta, solo marca completado.
    private func closeAsHelper() async {
        try? await APIClient.shared.updateMatchStatus(matchId: match.id, status: "completed")
        Haptic.success()
        Task { await ChatStore.shared.load() }
        NotificationCenter.default.post(name: .helpCompleted, object: nil)
        onDismiss?()
    }

    private func fmtSecs(_ s: Int) -> String {
        "\(s / 60):\(String(format: "%02d", s % 60))"
    }

    private func startSSE() {
        sseTask?.cancel()
        sseTask = Task {
            await connectSSE()
        }
    }

    private func connectSSE() async {
        guard let url = URL(string: "\(APIClient.shared.baseURL)/messages/\(match.id)/stream") else { return }
        var request = URLRequest(url: url)
        if let token = AuthService.shared.accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 300 // 5 min — se reconecta si cae

        do {
            let (bytes, _) = try await URLSession.shared.bytes(for: request)
            // Accumulate raw bytes so multi-byte UTF-8 characters (é, ñ, ü…) are not split
            var rawBuffer = Data()
            let newline2 = Data([0x0A, 0x0A]) // \n\n
            for try await byte in bytes {
                guard !Task.isCancelled else { break }
                rawBuffer.append(byte)
                // SSE messages end with \n\n — only decode once the full frame is in the buffer
                if rawBuffer.suffix(2) == newline2,
                   let chunk = String(data: rawBuffer, encoding: .utf8) {
                    rawBuffer = Data()
                    let lines = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
                        .components(separatedBy: "\n")
                    var eventType = "message"
                    for line in lines {
                        if line.hasPrefix("event:") {
                            eventType = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                        } else if line.hasPrefix("data:"),
                                  let data = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces).data(using: .utf8) {
                            if eventType == "match" {
                                // Cambio de estado del match (el buddy cerró la ayuda)
                                if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                                   let status = obj["status"] as? String, status == "completed" {
                                    await MainActor.run {
                                        // Dispara la encuesta de cierre (2 preguntas)
                                        NotificationCenter.default.post(name: .matchCompleted, object: nil)
                                    }
                                }
                            } else if let msg = try? JSONDecoder.buddy.decode(APIMessage.self, from: data) {
                                await MainActor.run {
                                    if !messages.contains(where: { $0.id == msg.id }) {
                                        messages.append(msg)
                                    }
                                }
                                await APIClient.shared.markMessagesRead(matchId: match.id)
                            }
                        }
                    }
                }
            }
        } catch {
            // Reconectar tras 2s si no fue cancelado por el usuario
            if !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await connectSSE()
            }
        }
    }
}

// MARK: – MESSAGE BUBBLE

struct BuddyMessageBubble: View {
    let message: APIMessage
    let isMe: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let isAudio    = message.type == "audio" || message.type == "audio_message"
        let isLocation = message.content?.hasPrefix("location:") == true
        let isPlace    = message.content?.hasPrefix("place:") == true

        return HStack(spacing: 0) {
            if isMe { Spacer(minLength: 64) }

            VStack(alignment: isMe ? .trailing : .leading, spacing: 3) {
                if isAudio, let url = message.audioUrl {
                    AudioPlayerBubble(audioUrl: url, isMe: isMe)
                } else if isPlace, let content = message.content {
                    placeCard(content: content)
                } else if isLocation, let content = message.content {
                    locationCard(content: content)
                } else {
                    textBubble
                }
                if let date = message.createdAt {
                    Text(shortTime(date))
                        .font(BT.caption2)
                        .foregroundStyle(Color.inkMuted)
                        .padding(.horizontal, 4)
                }
            }

            if !isMe { Spacer(minLength: 64) }
        }
    }

    private var textBubble: some View {
        Text(linkedText(message.content ?? ""))
            .font(BT.body)
            .foregroundStyle(isMe ? Color.white : Color.ink)
            .tint(isMe ? Color.white.opacity(0.85) : Color.teal)
            .environment(\.openURL, OpenURLAction { url in
                UIApplication.shared.open(url)
                return .handled
            })
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(isMe ? Color.teal : Color.surface)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(isMe ? Color.clear : Color.border, lineWidth: 1)
            )
    }

    private func placeCard(content: String) -> some View {
        let raw   = content.dropFirst("place:".count)
        let parts = raw.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false)
        let lat   = Double(parts.count > 0 ? parts[0] : "") ?? 0
        let lng   = Double(parts.count > 1 ? parts[1] : "") ?? 0
        let name  = parts.count > 2 ? String(parts[2]) : "Lugar"
        let addr  = parts.count > 3 ? String(parts[3]) : ""

        return Button {
            NotificationCenter.default.post(
                name: .openPlaceInMap, object: nil,
                userInfo: ["lat": lat, "lng": lng, "name": name]
            )
            dismiss()
        } label: {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.teal.opacity(0.12))
                        .frame(width: 36, height: 36)
                    Image(systemName: "mappin.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Color.teal)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(BT.footnoteBold)
                        .foregroundStyle(Color.ink)
                        .lineLimit(2)
                    if !addr.isEmpty {
                        Text(addr)
                            .font(BT.caption1)
                            .foregroundStyle(Color.inkMuted)
                            .lineLimit(2)
                    }
                    Text("Ver en el mapa")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.teal)
                        .padding(.top, 2)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(width: 240)
            .background(Color.surface)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func locationCard(content: String) -> some View {
        let coords = content.dropFirst("location:".count).split(separator: ",")
        let lat = Double(coords.first ?? "") ?? 0
        let lng = Double(coords.last  ?? "") ?? 0
        let coord = CLLocationCoordinate2D(latitude: lat, longitude: lng)
        let region = MKCoordinateRegion(center: coord,
                                        span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01))

        return Button {
            if let url = URL(string: "maps://?ll=\(lat),\(lng)&q=Mi+ubicación") {
                UIApplication.shared.open(url)
            }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                Map(initialPosition: .region(region)) {
                    Annotation("", coordinate: coord) {
                        ZStack {
                            Circle().fill(Color.teal).frame(width: 16, height: 16)
                            Circle().fill(.white).frame(width: 7, height: 7)
                        }
                    }
                }
                .frame(width: 240, height: 130)
                .disabled(true) // no scroll inside bubble
                .allowsHitTesting(false)

                HStack(spacing: 6) {
                    Image(systemName: "location.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.teal)
                    Text("Mi ubicación actual")
                        .font(BT.footnoteBold)
                        .foregroundStyle(Color.ink)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.inkMuted)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Color.surface)
            }
            .frame(width: 240)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func linkedText(_ raw: String) -> AttributedString {
        var attr = AttributedString(raw)
        let pattern = try? NSRegularExpression(pattern: #"https?://[^\s]+"#, options: .caseInsensitive)
        let nsRaw = raw as NSString
        pattern?.enumerateMatches(in: raw, range: NSRange(location: 0, length: nsRaw.length)) { match, _, _ in
            guard let range = match?.range,
                  let swiftRange = Range(range, in: raw),
                  let url = URL(string: String(raw[swiftRange])) else { return }
            if let attrRange = Range(swiftRange, in: attr) {
                attr[attrRange].link = url
                attr[attrRange].underlineStyle = .single
            }
        }
        return attr
    }

    private func shortTime(_ d: Date) -> String {
        let f = DateFormatter(); f.timeStyle = .short; return f.string(from: d)
    }
}

// MARK: – MessageBubble alias (for legacy use)
typealias MessageBubble = BuddyMessageBubble

// MARK: – Audio Recorder Service

@MainActor
final class AudioRecorderVM: ObservableObject {
    @Published var isRecording  = false
    @Published var isUploading  = false
    @Published var seconds      = 0
    @Published var cancelled    = false

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var fileURL: URL?

    func requestPermission() async -> Bool {
        await withCheckedContinuation { cont in
            AVAudioSession.sharedInstance().requestRecordPermission { cont.resume(returning: $0) }
        }
    }

    func start() async -> Bool {
        guard await requestPermission() else { return false }
        try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default, options: .defaultToSpeaker)
        try? AVAudioSession.sharedInstance().setActive(true)

        let dir = FileManager.default.temporaryDirectory
        fileURL = dir.appendingPathComponent("audio_\(Date().timeIntervalSince1970).m4a")

        let settings: [String: Any] = [
            AVFormatIDKey:             Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey:           44100,
            AVNumberOfChannelsKey:     1,
            AVEncoderAudioQualityKey:  AVAudioQuality.high.rawValue
        ]
        guard let url = fileURL,
              let rec = try? AVAudioRecorder(url: url, settings: settings) else { return false }
        recorder = rec
        rec.record()
        isRecording = true; seconds = 0; cancelled = false

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.seconds += 1 }
        }
        return true
    }

    func stop() -> URL? {
        timer?.invalidate(); timer = nil
        recorder?.stop(); recorder = nil
        isRecording = false
        return cancelled ? nil : fileURL
    }

    func cancel() {
        cancelled = true
        timer?.invalidate(); timer = nil
        recorder?.stop(); recorder = nil
        if let url = fileURL { try? FileManager.default.removeItem(at: url) }
        isRecording = false
    }

    // Upload to buddy-core storage proxy (multipart)
    // El endpoint /audio ya crea el registro en DB y devuelve el APIMessage completo
    func upload(fileURL: URL, matchId: String) async throws -> APIMessage {
        isUploading = true
        defer { isUploading = false }

        let endpoint = "\(APIClient.shared.baseURL)/messages/\(matchId)/audio"
        guard let url = URL(string: endpoint) else { throw URLError(.badURL) }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        let boundary = "Boundary-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let token = AuthService.shared.accessToken {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let audioData = try Data(contentsOf: fileURL)
        let senderId = AuthService.shared.userId ?? ""
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"sender_id\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(senderId)\r\n".data(using: .utf8)!)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"audio\"; filename=\"audio.m4a\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/mp4\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 201 else {
            throw URLError(.badServerResponse)
        }
        // El servidor devuelve el APIMessage ya creado — lo parseamos directamente
        return try JSONDecoder.buddy.decode(APIMessage.self, from: data)
    }
}

// MARK: – Audio Player Bubble

@MainActor
final class AudioPlayerVM: ObservableObject {
    @Published var isPlaying = false
    @Published var progress  = 0.0
    @Published var duration  = 0.0
    @Published var isLoading = true
    @Published var hasError  = false

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?

    func load(urlString: String) {
        guard let url = URL(string: urlString) else { hasError = true; isLoading = false; return }
        let item = AVPlayerItem(url: url)
        player   = AVPlayer(playerItem: item)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)

        Task {
            do {
                let dur = try await item.asset.load(.duration)
                if dur.isValid && !dur.isIndefinite { self.duration = CMTimeGetSeconds(dur) }
                self.isLoading = false
            } catch { self.isLoading = false; self.hasError = true }
        }

        let interval = CMTime(seconds: 0.05, preferredTimescale: 600)
        timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self, let dur = self.player?.currentItem?.duration,
                  dur.isValid, !dur.isIndefinite else { return }
            let total = CMTimeGetSeconds(dur)
            if self.duration == 0 { self.duration = total }
            self.progress = total > 0 ? CMTimeGetSeconds(time) / total : 0
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            self?.isPlaying = false; self?.progress = 0
            self?.player?.seek(to: .zero)
        }
    }

    func togglePlay() {
        guard let player else { return }
        isPlaying ? player.pause() : player.play()
        isPlaying.toggle()
    }

    func seek(to ratio: Double) {
        guard let player, duration > 0 else { return }
        player.seek(to: CMTime(seconds: ratio * duration, preferredTimescale: 600))
        progress = ratio
    }

    deinit {
        if let obs = timeObserver { player?.removeTimeObserver(obs) }
        if let obs = endObserver  { NotificationCenter.default.removeObserver(obs) }
    }
}

private let waveHeights: [CGFloat] = [3,5,9,5,13,7,16,10,5,12,8,15,4,10,7,5,13,7,11,4,8,14,6,10,5,12,9,4,15,7]

struct AudioPlayerBubble: View {
    let audioUrl: String
    let isMe: Bool

    @StateObject private var vm = AudioPlayerVM()

    private var bubbleBg:   Color { isMe ? Color.teal   : Color.surface }
    private var playFg:     Color { isMe ? Color.ink    : Color.white }
    private var playBg:     Color { isMe ? Color.white  : Color.ink }
    private var waveActive: Color { isMe ? Color.white  : Color.teal }
    private var waveIdle:   Color { isMe ? Color.white.opacity(0.35) : Color.inkMuted.opacity(0.3) }
    private var dotColor:   Color { isMe ? Color.white  : Color.teal }
    private var timeFg:     Color { isMe ? Color.white.opacity(0.55) : Color.inkMuted }

    var body: some View {
        HStack(spacing: 10) {

            // ── Play / pause ────────────────────────────────────────
            Button { vm.togglePlay() } label: {
                ZStack {
                    if vm.isLoading {
                        ProgressView().tint(isMe ? Color.white : Color.ink).scaleEffect(0.7)
                            .frame(width: 24, height: 24)
                    } else {
                        Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(isMe ? Color.white : Color.ink)
                            .offset(x: vm.isPlaying ? 0 : 1.5)
                    }
                }
                .frame(width: 28, height: 28)
            }
            .disabled(vm.isLoading || vm.hasError)

            // ── Waveform + duración ─────────────────────────────────
            VStack(alignment: .leading, spacing: 4) {
                // Waveform con punto de progreso
                let barW: CGFloat    = 2
                let barGap: CGFloat  = 1.5
                let barCount         = waveHeights.count
                let totalBarsW       = CGFloat(barCount) * barW + CGFloat(barCount - 1) * barGap

                ZStack(alignment: .leading) {
                    // Barras
                    HStack(alignment: .center, spacing: barGap) {
                        ForEach(0..<barCount, id: \.self) { i in
                            let passed = Double(i) / Double(barCount) < vm.progress
                            Capsule()
                                .fill(passed ? waveActive : waveIdle)
                                .frame(width: barW, height: waveHeights[i])
                                .animation(.easeOut(duration: 0.06), value: vm.progress)
                        }
                    }
                    // Punto: se mueve solo dentro del rango de barras
                    let dotX = min(max(totalBarsW * vm.progress, 0), totalBarsW - 11)
                    Circle()
                        .fill(dotColor)
                        .frame(width: 11, height: 11)
                        .shadow(color: dotColor.opacity(0.4), radius: 2)
                        .offset(x: dotX)
                        .animation(.easeOut(duration: 0.06), value: vm.progress)
                }
                .frame(width: totalBarsW, height: 20)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                    vm.seek(to: max(0, min(1, v.location.x / totalBarsW)))
                })

                // Duración
                Text(fmt(vm.isPlaying ? vm.progress * vm.duration : vm.duration))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(timeFg)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(bubbleBg)
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .task { vm.load(urlString: audioUrl) }
    }

    private func fmt(_ s: Double) -> String {
        guard s.isFinite, s > 0 else { return "0:00" }
        let t = Int(s); return "\(t/60):\(String(format: "%02d", t%60))"
    }
}

// MARK: – Keyboard Pre-warmer
// Activa y desactiva un TextField oculto al aparecer la vista para que
// iOS inicialice el teclado en background y no tarde la primera vez.
private struct KeyboardPrewarmer: UIViewRepresentable {
    func makeUIView(context: Context) -> UITextField {
        let tf = UITextField()
        tf.isHidden = true
        tf.alpha = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            tf.becomeFirstResponder()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                tf.resignFirstResponder()
            }
        }
        return tf
    }
    func updateUIView(_ uiView: UITextField, context: Context) {}
}

// MARK: – Close Cycle Card

struct CloseCycleCard: View {
    let buddyName: String
    /// true si el usuario actual es quien AYUDA (buddy). Cambia el tono del copy.
    var isHelper: Bool = false
    let onClose: () -> Void
    let onKeepOpen: () -> Void

    private var title: String {
        isHelper ? "¿Pudiste ayudar a \(buddyName)?"
                 : "¿pudimos cerrar tu duda?"
    }
    private var subtitle: String {
        isHelper ? "Si ya resolviste su duda, cierra el apoyo para quedar libre y acompañar a otro viajero."
                 : "Si todo está resuelto, cierra la ayuda para que \(buddyName) pueda apoyar a otro viajero."
    }
    private var closeLabel: String { isHelper ? "Sí, resuelto" : "Sí, gracias" }
    private var keepLabel:  String { isHelper ? "Seguimos en eso" : "Tengo otra pregunta" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.ink)
                Text(subtitle)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Button(action: onClose) {
                    Text(closeLabel)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(Color.ink)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                Button(action: onKeepOpen) {
                    Text(keepLabel)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.ink)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(Color.canvas)
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(Color.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(Spacing.md)
        .background(Color.sandLight.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.border, lineWidth: 1))
    }
}

// MARK: – TOAST MODIFIER

extension View {
    func toast(isPresented: Binding<Bool>, message: String) -> some View {
        self.overlay(alignment: .bottom) {
            if isPresented.wrappedValue {
                Text(message)
                    .font(BT.callout)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(Color.ink.opacity(0.9))
                    .clipShape(Capsule())
                    .padding(.bottom, 100)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                            withAnimation { isPresented.wrappedValue = false }
                        }
                    }
            }
        }
        .animation(.spring(response: 0.4), value: isPresented.wrappedValue)
    }
}

// MARK: – REPORT USER SHEET

struct ReportUserSheet: View {
    let buddyName: String
    let matchId: String
    let reportedUserId: String
    let onDone: () -> Void

    @State private var selectedReason: String? = nil
    @State private var details = ""
    @State private var isSending = false
    @Environment(\.dismiss) private var dismiss

    private let reasons: [(String, String, String)] = [
        ("harassment",            "Acoso o amenazas",             "exclamationmark.triangle"),
        ("commercial_pressure",   "Presión comercial",            "dollarsign.circle"),
        ("fake_profile",          "Perfil falso o suplantación",  "person.fill.questionmark"),
        ("inappropriate_content", "Contenido inapropiado",        "eye.slash"),
        ("safety_concern",        "Preocupación de seguridad",    "shield.slash"),
        ("spam",                  "Spam o publicidad",            "envelope.badge"),
        ("other",                 "Otro motivo",                  "ellipsis.circle"),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("¿Por qué reportas a \(buddyName)?")
                        .font(BT.title2)
                        .foregroundStyle(Color.ink)
                        .padding(.top, 8)

                    VStack(spacing: 8) {
                        ForEach(reasons, id: \.0) { key, label, icon in
                            Button {
                                selectedReason = key
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: icon)
                                        .font(.system(size: 16))
                                        .foregroundStyle(selectedReason == key ? Color.sand : Color.inkMuted)
                                        .frame(width: 24)
                                    Text(label)
                                        .font(BT.callout)
                                        .foregroundStyle(Color.ink)
                                    Spacer()
                                    if selectedReason == key {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(Color.sand)
                                    }
                                }
                                .padding(14)
                                .background(selectedReason == key ? Color.sand.opacity(0.08) : Color.surface)
                                .clipShape(RoundedRectangle(cornerRadius: Radius.md))
                                .overlay(RoundedRectangle(cornerRadius: Radius.md).stroke(
                                    selectedReason == key ? Color.sand : Color.border, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Detalles adicionales (opcional)")
                            .font(BT.caption1)
                            .foregroundStyle(Color.inkMuted)
                        TextField("Cuéntanos qué ocurrió…", text: $details, axis: .vertical)
                            .font(BT.callout)
                            .lineLimit(4, reservesSpace: true)
                            .padding(12)
                            .background(Color.surface)
                            .clipShape(RoundedRectangle(cornerRadius: Radius.md))
                            .overlay(RoundedRectangle(cornerRadius: Radius.md).stroke(Color.border, lineWidth: 1))
                    }

                    Text("Tu reporte es confidencial. El equipo de Buddy lo revisará en menos de 24 horas.")
                        .font(BT.caption1)
                        .foregroundStyle(Color.inkMuted)
                        .multilineTextAlignment(.leading)
                }
                .padding(.horizontal, Spacing.edge)
            }
            .background(Color.canvas)
            .navigationTitle("Reportar usuario")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancelar") { dismiss() }
                        .foregroundStyle(Color.inkMuted)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await sendReport() }
                    } label: {
                        if isSending {
                            ProgressView().tint(Color.sand)
                        } else {
                            Text("Enviar").fontWeight(.semibold).foregroundStyle(Color.sand)
                        }
                    }
                    .disabled(selectedReason == nil || isSending)
                }
            }
        }
    }

    private func sendReport() async {
        guard let reason = selectedReason else { return }
        isSending = true
        try? await APIClient.shared.reportUser(
            reportedUserId: reportedUserId,
            reason: reason,
            details: details.isEmpty ? nil : details,
            matchId: matchId
        )
        isSending = false
        onDone()
    }
}

// MARK: – CLOSE FEEDBACK SHEET

struct CloseFeedbackSheet: View {
    let buddyName: String
    let buddyAvatarUrl: String?
    /// true → encuesta obligatoria (el buddy cerró): sin X ni swipe.
    /// false → el viajero la inició: puede descartarla.
    var isMandatory: Bool = false
    let onClose: (_ feeling: String, _ pressure: String) -> Void
    let onDismiss: () -> Void

    private let feelings = ["cómoda", "bienvenida", "inspirada", "segura", "neutral", "incómoda"]
    private let pressures = ["nunca", "un poco", "mucha"]

    // Preseleccionados para facilitar: la mayoría cierra sin fricción.
    @State private var selectedFeeling: String? = "cómoda"
    @State private var selectedPressure: String? = "nunca"

    var body: some View {
        VStack(spacing: 0) {
            // Pull indicator
            Capsule()
                .fill(Color.secondary.opacity(0.3))
                .frame(width: 36, height: 4)
                .padding(.top, 10)
                .padding(.bottom, 20)

            // Avatar
            ZStack {
                Circle()
                    .fill(Color.sandLight)
                    .frame(width: 72, height: 72)
                    .overlay {
                        if let urlStr = buddyAvatarUrl, let url = URL(string: urlStr) {
                            AsyncImage(url: url) { img in img.resizable().scaledToFill() }
                                placeholder: { Color.sandLight }
                                .clipShape(Circle())
                        } else {
                            Image(systemName: "person.fill")
                                .font(.system(size: 28))
                                .foregroundStyle(Color.sand)
                        }
                    }
            }
            .overlay(Circle().stroke(Color.white, lineWidth: 3))
            .shadow(color: .black.opacity(0.1), radius: 8, y: 3)
            .padding(.bottom, 20)

            Group {
                Text("Tu momento con ")
                    .font(BT.title2)
                + Text(buddyName.capitalized)
                    .font(BT.title2)
                    .foregroundColor(Color.sand)
            }
            .multilineTextAlignment(.center)
            Text("Dos cosas rápidas antes de cerrar.")
                .font(BT.footnote)
                .foregroundStyle(Color.inkMuted)
                .padding(.top, 4)
                .padding(.bottom, 24)

            // Feeling question
            VStack(spacing: 14) {
                Group {
                    Text("¿cómo te ")
                    + Text("sintió").foregroundColor(Color.sand)
                    + Text(" este momento?")
                }
                .font(.system(size: 16, weight: .medium))
                .multilineTextAlignment(.center)

                let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(feelings, id: \.self) { f in
                        Button { selectedFeeling = f } label: {
                            Text(f)
                                .font(.system(size: 14, weight: selectedFeeling == f ? .semibold : .regular))
                                .foregroundStyle(selectedFeeling == f ? .white : Color.ink)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 11)
                                .background(selectedFeeling == f ? Color.sand : Color.surface)
                                .clipShape(Capsule())
                                .overlay(Capsule().stroke(Color.border, lineWidth: selectedFeeling == f ? 0 : 1))
                        }
                        .buttonStyle(.plain)
                        .animation(.spring(response: 0.25), value: selectedFeeling)
                    }
                }
            }
            .padding(.bottom, 24)

            // Pressure question
            VStack(spacing: 14) {
                Group {
                    Text("¿sentiste ")
                    + Text("presión").foregroundColor(Color.sand)
                    + Text(" comercial?")
                }
                .font(.system(size: 16, weight: .medium))
                .multilineTextAlignment(.center)

                HStack(spacing: 10) {
                    ForEach(pressures, id: \.self) { p in
                        Button { selectedPressure = p } label: {
                            Text(p)
                                .font(.system(size: 14, weight: selectedPressure == p ? .semibold : .regular))
                                .foregroundStyle(selectedPressure == p ? .white : Color.ink)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 11)
                                .background(selectedPressure == p ? Color.sand : Color.surface)
                                .clipShape(Capsule())
                                .overlay(Capsule().stroke(Color.border, lineWidth: selectedPressure == p ? 0 : 1))
                        }
                        .buttonStyle(.plain)
                        .animation(.spring(response: 0.25), value: selectedPressure)
                    }
                }

                Text("\(buddyName) nunca verá una calificación — solo cómo te sentiste.")
                    .font(BT.caption1)
                    .foregroundStyle(Color.inkMuted)
                    .multilineTextAlignment(.center)
            }
            .padding(.bottom, 28)

            // CTA
            Button(action: { onClose(selectedFeeling ?? "neutral", selectedPressure ?? "nunca") }) {
                Text("Continuar")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.ink)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(selectedFeeling == nil || selectedPressure == nil)
            .opacity(selectedFeeling == nil || selectedPressure == nil ? 0.45 : 1)
            .animation(.easeInOut(duration: 0.2), value: selectedFeeling == nil || selectedPressure == nil)

            Spacer(minLength: 20)
        }
        .padding(.horizontal, 24)
        // Sin reset: mantenemos los valores preseleccionados (cómoda / nunca).
        .presentationDetents([.large])
        .presentationDragIndicator(isMandatory ? .hidden : .visible)
        .interactiveDismissDisabled(isMandatory)
        // El viajero que inicia el cierre puede descartar con la X.
        .overlay(alignment: .topTrailing) {
            if !isMandatory {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.ink)
                        .frame(width: 32, height: 32)
                        .background(Color.canvas)
                        .clipShape(Circle())
                        .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
                }
                .padding(.top, 16)
                .padding(.trailing, 20)
            }
        }
    }
}
