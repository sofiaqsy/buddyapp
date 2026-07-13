import SwiftUI
import AVFoundation
import MapKit
import PhotosUI
import os

// Root-cause investigation of the ~1s first-keyboard-focus delay (see KeyboardPrewarmer).
// Measures: raw tap → FocusState flips → keyboardWillShow → keyboardDidShow.
// Visible in Instruments (Points of Interest) and via the printed deltas below.
enum KeyboardTiming {
    static let signposter = OSSignposter(subsystem: "com.buddyapp.app", category: "Keyboard")
    static func now() -> Double { Date().timeIntervalSince1970 }
}

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

/// Backoff exponencial con tope y jitter — compartido por ContactarBuddyView y BuddyChatView.
/// Mismo patrón que ChatStore.backoff(_:).
private func sseBackoff(_ attempt: inout Int) async {
    guard !Task.isCancelled else { return }
    attempt += 1
    let capped = min(Double(attempt) * 2.0, 20.0)
    let jitter = Double.random(in: 0...1.5)
    try? await Task.sleep(nanoseconds: UInt64((capped + jitter) * 1_000_000_000))
}

struct ContactarBuddyView: View {
    /// Opcional: en el flujo de la Home aún NO existe un Trip (se crea recién
    /// cuando un buddy acepta). Cuando hay Trip se pasa; si no, basta el destino.
    var journey: APIJourney? = nil
    var destinationId: String? = nil
    var destinationName: String? = nil
    var preselectedCategory: String? = nil
    /// Si viene seteado, se crea la solicitud de inmediato (la Home ya eligió
    /// categoría/texto) → el usuario aterriza directo en "buscando", sin repetir
    /// la pantalla de categorías.
    var initialRequest: (category: String, description: String?)? = nil
    /// Llamado cuando el usuario cancela el flujo completo sin confirmar un buddy.
    /// Solo se llama en flujos initialRequest — en flujos normales el usuario vuelve
    /// al selector de categoría en lugar de cerrar la sheet.
    var onCancelled: (() -> Void)? = nil

    /// Destino efectivo: del Trip si existe, o el pasado directamente.
    private var resolvedDestinationId: String? {
        journey?.destination?.id ?? journey?.destinationId ?? destinationId
    }
    private var resolvedDestinationName: String? {
        journey?.destination?.name ?? destinationName
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var router: AppRouter
    @State private var phase: Phase = .loading

    private var effectiveUserId: String? { Session.travelerId }
    @State private var match: APIMatch?
    @State private var pollTask: Task<Void, Never>?
    @State private var sseMatchTask: Task<Void, Never>? = nil
    @State private var buddyCount: Int = 0
    @State private var activeRequestId: String? = nil   // solicitud en curso (para cancelarla)
    @State private var chosenCategory: String? = nil    // apiKey elegido, para el primer msg del chat
    /// true cuando el backend ya escaló al menos una vez — cambia el copy de la UI.
    @State private var isExpandingSearch: Bool = false
    /// Evita que el timer y el SSE disparen pollForMatch() simultáneamente.
    @State private var isPollInFlight: Bool = false

    enum Phase: Equatable {
        case loading, selectCategory, searching, matched, error(String)
    }

    var body: some View {
        let _ = print("🔶 [ContactarBuddyView] body — phase=\(phase)")
        NavigationStack {
            ZStack {
                Color.canvas.ignoresSafeArea()
                switch phase {
                case .loading:        loadingView
                case .selectCategory: CategoryPickerView(buddyCount: buddyCount, preselectedCategory: preselectedCategory, destinationName: resolvedDestinationName, onRequest: handleRequest)
                case .searching:      SearchingView(buddyCount: buddyCount, isExpandingSearch: isExpandingSearch, category: chosenCategory, onCancel: cancelSearch)
                case .matched:        chatView
                case .error(let m):   errorView(m)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if phase == .selectCategory || phase == .loading {
                        Button {
                            if initialRequest != nil { onCancelled?() }
                            dismiss()
                        } label: {
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
        .onDisappear {
            // Limpiar ambos mecanismos para evitar recursos colgados si el sheet se cierra
            // sin pasar por cancelSearch() (p.ej. swipe-dismiss del sheet).
            pollTask?.cancel()
            stopSSEMatch()
        }
        // Reconexión tras volver al primer plano: el SSE del matching cae cuando iOS
        // suspende la app. Reiniciamos el SSE y consultamos el estado de inmediato
        // (sin esperar el próximo tick del timer de 30 s).
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active, phase == .searching, let requestId = activeRequestId else { return }
            stopSSEMatch()
            startSSEMatch(requestId: requestId)
            Task { await pollForMatch() }
        }
        // Dirigido por evento: el push "¡Tienes un buddy!" llega al aceptar → consulta UNA vez.
        // El timer queda solo como red de seguridad (30 s), no como mecanismo principal.
        .onReceive(NotificationCenter.default.publisher(for: .pushReceivedForeground)) { _ in
            if phase == .searching { Task { await pollForMatch() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pushNotificationTapped)) { _ in
            if phase == .searching { Task { await pollForMatch() } }
        }
    }

    private var loadingView: some View {
        VStack(spacing: Spacing.md) {
            Spacer()
            ProgressView().tint(Color.teal)
            Text(initialRequest != nil ? "Preparando tu búsqueda…" : "Cargando…")
                .font(BT.callout)
                .foregroundStyle(Color.inkMuted)
            Spacer()
        }
    }

    private var chatView: some View {
        Group {
            if let match { BuddyChatView(match: match, journey: journey, initialCategory: chosenCategory).equatable() }
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
        let destIdOpt: String? = resolvedDestinationId
        guard let destId = destIdOpt else { return }
        if let count = try? await APIClient.shared.fetchBuddyCount(destinationId: destId) {
            buddyCount = count
        }
    }

    private func checkStatus() async {
        phase = .loading
        print("🔍 [checkStatus] Session.hasSession=\(Session.hasSession) travelerId=\(Session.travelerId?.prefix(8) ?? "NIL")")
        // Ensure a Traveler session exists before doing anything.
        // On a fresh install Session.travelerId is nil — this call hits /travelers/init
        // and persists the guest JWT so all subsequent guards and API calls succeed.
        if !Session.hasSession {
            do {
                try await TravelerService.shared.ensureSession()
                await MainActor.run {
                    NotificationCenter.default.post(name: .travelerSessionCreated, object: nil)
                }
                print("🔍 [checkStatus] guest session created → travelerId=\(Session.travelerId?.prefix(8) ?? "NIL")")
            } catch {
                phase = .error("No se pudo iniciar sesión. Verifica tu conexión.")
                return
            }
        }
        guard let userId = effectiveUserId else { phase = .error("Sin sesión."); return }
        do {
            let matches = try await APIClient.shared.fetchMatches()
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
                match = active
                let cat = initialRequest?.category
                chosenCategory = (cat == nil || cat == "general") ? nil : cat
                phase = .matched; return
            }
            print("⚠️ [checkStatus] NINGÚN match activo para userId=\(userId) (status válidos: \(activeStatuses)) → buscando solicitudes abiertas")
            // La encuesta pendiente la presenta RootView globalmente (en cualquier
            // tab y en tiempo real), así que aquí no hace falta detectarla.
            let destIdOpt: String? = resolvedDestinationId
            guard let destId = destIdOpt else { phase = .selectCategory; return }
            let requests = try await APIClient.shared.fetchOpenRequests(destinationId: destId)
            if let open = requests.first(where: { $0.travelerId == userId && $0.isActive }) {
                print("🔄 [checkStatus] solicitud abierta encontrada id=\(open.id) → searching")
                activeRequestId = open.id
                isExpandingSearch = false
                phase = .searching; startPolling(); startSSEMatch(requestId: open.id)
            } else if let seed = initialRequest {
                // La Home ya eligió → crear la solicitud directamente.
                // handleRequest() requiere phase == .selectCategory; se setea antes de llamarlo.
                print("⚡️ [checkStatus] initialRequest=\(seed.category) → solicitando directo")
                phase = .selectCategory
                await handleRequest(category: seed.category, description: seed.description)
            } else {
                print("📋 [checkStatus] sin match ni solicitud → mostrando selector de categoría")
                phase = .selectCategory
            }
        } catch { phase = .error(error.localizedDescription) }
    }

    func handleRequest(category: String, description: String?) async {
        print("📤 [handleRequest] Session.hasSession=\(Session.hasSession) travelerId=\(Session.travelerId?.prefix(8) ?? "NIL") category=\(category)")
        guard phase == .selectCategory else {
            print("⚠️ [handleRequest] ignorado — phase ya es \(phase)")
            return
        }
        guard let userId = effectiveUserId else {
            print("❌ [handleRequest] effectiveUserId=nil — session missing at request time")
            return
        }
        let destIdOpt2: String? = resolvedDestinationId
        guard let destId = destIdOpt2 else { return }
        chosenCategory = category == "general" ? nil : category
        phase = .searching
        do {
            // Activate the journey so the home hero card shows it and
            // loadData can load the associated match.
            if let j = journey, j.status == "planning" {
                try? await APIClient.shared.updateJourneyStatus(journeyId: j.id, status: "active")
            }
            let req = try await APIClient.shared.createHelpRequest(
                destinationId: destId, journeyId: journey?.id,
                category: category, description: description, arrivalAt: journey?.arrivalAt)
            activeRequestId = req.id
            isExpandingSearch = false
            startPolling(); startSSEMatch(requestId: req.id)
        } catch { phase = .error(error.localizedDescription) }
    }

    private func cancelSearch() {
        pollTask?.cancel()
        stopSSEMatch()
        if let rid = activeRequestId {
            let capturedRid = rid
            activeRequestId = nil
            Task {
                do {
                    try await APIClient.shared.cancelHelpRequest(requestId: capturedRid)
                } catch {
                    // Si el cancel falla en red, el servidor puede tener la solicitud activa.
                    // checkStatus() al re-abrir la detectará y reanudará la búsqueda.
                    print("⚠️ [cancelSearch] cancelHelpRequest falló — el servidor puede tener la solicitud activa: \(error)")
                }
            }
        }
        // Si vino de la Home (sin pasar por el selector) → cerrar y volver al
        // inicio. Si vino del selector → volver a elegir categoría.
        if initialRequest != nil {
            onCancelled?()
            dismiss()
        } else {
            phase = .selectCategory
        }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled else { return }
                await pollForMatch()
            }
        }
    }

    private func startSSEMatch(requestId: String) {
        sseMatchTask?.cancel()
        sseMatchTask = Task {
            // Bucle de reconexión con backoff exponencial — igual que ChatStore.startEventStream.
            var attempt = 0
            while !Task.isCancelled {
                guard let token = Session.token else {
                    try? await Task.sleep(nanoseconds: 3_000_000_000); continue
                }
                guard let url = URL(string: "\(APIClient.shared.baseURL)/matching/request/\(requestId)/stream") else { return }

                var req = URLRequest(url: url)
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                req.timeoutInterval = 300

                guard let (stream, _) = try? await URLSession.shared.bytes(for: req) else {
                    if Task.isCancelled { return }
                    await sseBackoff(&attempt); continue
                }

                attempt = 0   // conexión exitosa
                do {
                    for try await line in stream.lines {
                        guard !Task.isCancelled else { return }
                        if line.hasPrefix("event: matched") {
                            // El SSE es la fuente de verdad primaria: cuando confirma el match
                            // transitamos directamente, sin pasar por el guard de isPollInFlight
                            // que pertenece al camino de recuperación del timer.
                            await transitionToMatched()
                            return   // tarea completada — el match está abierto
                        } else if line.hasPrefix("data:") {
                            // Línea de datos sin event header: usamos el poll de recuperación
                            // (con guard) para no duplicar si el timer también está activo.
                            await pollForMatch()
                        }
                    }
                } catch { }

                await sseBackoff(&attempt)
            }
        }
    }


    /// Transición directa al chat, activada SOLO por el SSE cuando confirma el match.
    /// No respeta isPollInFlight porque el SSE es el mecanismo primario — su señal
    /// debe procesarse aunque el timer de recuperación esté en vuelo.
    private func transitionToMatched() async {
        let userId = effectiveUserId
        guard let matches = try? await APIClient.shared.fetchMatches() else { return }
        let activeStatuses = ["pending", "accepted", "active"]
        guard let active = matches.first(where: {
            activeStatuses.contains($0.status ?? "") && $0.travelerId == userId
        }) else { return }
        pollTask?.cancel()
        match = active
        withAnimation(.spring(response: 0.5, dampingFraction: 0.75)) { phase = .matched }
        UIAccessibility.post(notification: .announcement,
            argument: "¡Encontramos tu buddy! Conectando al chat.")
        // La tarea SSE sale por sí sola vía `return` en startSSEMatch —
        // no hace falta llamar stopSSEMatch() desde aquí.
    }

    private func stopSSEMatch() {
        sseMatchTask?.cancel()
        sseMatchTask = nil
    }

    private func pollForMatch() async {
        // Un solo poll en vuelo a la vez — evita llamadas paralelas del timer y del SSE.
        guard !isPollInFlight else { return }
        guard let requestId = activeRequestId else { return }
        isPollInFlight = true
        defer { isPollInFlight = false }

        do {
            let status = try await APIClient.shared.fetchMatchingStatus(requestId: requestId)
            switch status.status {

            case "matched":
                // Confirmado por el backend → recuperar el objeto completo del match.
                // Solo en este caso hacemos el segundo fetch (fetchMatches); durante
                // el estado "searching" basta con el endpoint de estado (barato).
                let userId = effectiveUserId
                let matches = try await APIClient.shared.fetchMatches()
                let activeStatuses = ["pending", "accepted", "active"]
                if let active = matches.first(where: {
                    activeStatuses.contains($0.status ?? "") && $0.travelerId == userId
                }) {
                    pollTask?.cancel()
                    stopSSEMatch()
                    match = active
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.75)) { phase = .matched }
                    UIAccessibility.post(notification: .announcement,
                        argument: "¡Encontramos tu buddy! Conectando al chat.")
                }

            case "searching":
                // El backend escala lazy si el candidato actual expiró.
                // position > 1 significa que ya estamos en el segundo candidato o más.
                if let pos = status.position { isExpandingSearch = pos > 1 }

            case "failed":
                // Se agotaron todos los candidatos del Top-N.
                pollTask?.cancel()
                stopSSEMatch()
                // Si es un flujo pioneer (desde home sin buddies), navegar a Tu trip
                if initialRequest != nil {
                    dismiss()
                    await MainActor.run { router.switchTo(.trips) }
                } else {
                    phase = .error("No encontramos un buddy disponible en este momento. Intenta de nuevo en unos minutos.")
                }

            case "cancelled":
                // El viajero (u operador) canceló la solicitud desde otro dispositivo.
                pollTask?.cancel()
                stopSSEMatch()
                phase = .selectCategory

            default:
                // "none" → la cola no existe (solicitud inválida o borrada).
                // Tratamos como si no hubiera solicitud activa → volver al selector.
                pollTask?.cancel()
                stopSSEMatch()
                activeRequestId = nil
                phase = .selectCategory
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
    var destinationName: String? = nil
    var onDestinationTap: (() -> Void)? = nil
    var activeBuddyName: String? = nil
    var activeBuddyAvatarUrl: String? = nil
    var communityContext: APIPlaceContext? = nil
    /// True while InicioView is still loading data. Renders this exact component
    /// redacted instead of a hand-built skeleton, so there is zero visual jump when
    /// real data arrives — same layout, padding, radius, just real content
    /// fading in where the placeholder bars were. The heading stays un-redacted: it's
    /// static copy, not data, so it can (and should) be visible from frame one.
    var isSkeleton: Bool = false
    /// Cuando true, el modo pioneer NO auto-habilita el botón — se exige selección de categoría.
    /// Pasar true desde noTripComposer cuando no hay buddies en la zona.
    var pioneerRequiresCategory: Bool = false
    var isLoading: Bool = false
    let onRequest: (String, String?) async -> Void

    @State private var selected: BuddyCategory? = nil

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

    private let subtitles: [String: String] = [
        "transport":     "Rutas y transporte",
        "food":          "Comida y restaurantes",
        "translation":   "Frases, señales y más",
        "activities":    "Tours y actividades",
        "accommodation": "Hoteles, hostales y más",
        "emergency":     "Emergencias y consejos útiles",
    ]

    // En estado pioneer (sin buddies registrados en el lugar), el botón siempre
    // está habilitado aunque no haya categoría seleccionada: la intención es
    // "necesito ayuda", el sistema resuelve el flujo internamente.
    private var canRequest: Bool {
        selected != nil || activeBuddyName != nil
            || (!pioneerRequiresCategory && communityContext != nil && communityContext!.totalBuddies == 0)
    }

    private var subtitleAttributed: AttributedString {
        if let city = destinationName {
            var prefix = AttributedString("Cuéntanos qué necesitas. Te conectaremos con un buddy de ")
            prefix.foregroundColor = UIColor(Color.inkMuted)

            var cityStr = AttributedString(city)
            cityStr.foregroundColor = UIColor(Color.brand)
            cityStr.inlinePresentationIntent = .stronglyEmphasized
            if onDestinationTap != nil {
                cityStr.underlineStyle = .single
                cityStr.link = URL(string: "buddy://destination")
            }

            var dot = AttributedString(".")
            dot.foregroundColor = UIColor(Color.inkMuted)

            return prefix + cityStr + dot
        } else {
            var str = AttributedString("Cuéntanos qué necesitas. Te conectaremos con un buddy.")
            str.foregroundColor = UIColor(Color.inkMuted)
            return str
        }
    }

    private var noBuddies: Bool {
        guard activeBuddyName == nil else { return false }
        if let ctx = communityContext { return ctx.buddies <= 0 && ctx.totalBuddies <= 0 }
        return buddyCount <= 0
    }

    /// Texto debajo del botón "Hablar con un buddy".
    /// Refleja el estado de la comunidad en lugar de hablar de errores del sistema.
    private var availabilityText: String {
        // Si hay un buddy activo asignado, siempre el mensaje de continuidad
        if activeBuddyName != nil { return "Tu buddy sigue disponible para ayudarte." }

        guard let ctx = communityContext else {
            // Sin contexto (ContactarBuddyView con journey activo): fallback numérico
            if buddyCount <= 0 { return "Te conectamos con el primer buddy disponible" }
            return buddyCount == 1
                ? "1 buddy disponible para ti ahora"
                : "\(buddyCount) buddies disponibles para ti ahora"
        }

        if ctx.buddies > 0 {
            return ctx.buddies == 1
                ? "1 buddy disponible para ti ahora"
                : "\(ctx.buddies) buddies disponibles para ti ahora"
        }
        if ctx.totalBuddies > 0 {
            return ctx.totalBuddies == 1
                ? "1 buddy ayuda en esta zona. Ahora mismo está ocupado."
                : "\(ctx.totalBuddies) buddies ayudan en esta zona. Ahora mismo están ocupados."
        }
        if ctx.stories > 0 {
            return ctx.stories == 1
                ? "1 viajero ya visitó aquí. Aún buscamos buddies locales."
                : "\(ctx.stories) viajeros visitaron aquí. Aún buscamos buddies locales."
        }
        return "Todavía no hay buddies aquí. Sé el primero en explorar."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Hero heading
            VStack(alignment: .leading, spacing: 6) {
                Group {
                    Text("Consulta con un ").foregroundColor(Color.ink)
                    + Text("buddy").foregroundColor(Color.brand)
                }
                .font(BT.displayLarge)
                .lineLimit(isSkeleton ? 1 : nil)
                .minimumScaleFactor(isSkeleton ? 0.8 : 1)
                Text(subtitleAttributed)
                    .font(BT.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .environment(\.openURL, OpenURLAction { url in
                        if url.absoluteString == "buddy://destination" {
                            onDestinationTap?()
                            return .handled
                        }
                        return .systemAction(url)
                    })
                    .redacted(reason: isSkeleton ? .placeholder : [])
            }
            .padding(.horizontal, Spacing.edge)
            .padding(.top, Spacing.md)
            .padding(.bottom, Spacing.lg)

            // 2×3 grid — icon circle + title + subtitle
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(categories) { cat in
                    let isSelected = selected?.id == cat.id
                    let subtitle   = subtitles[cat.apiKey] ?? ""
                    Button {
                        // Tocar la necesidad DISPARA la búsqueda de inmediato —
                        // sin paso intermedio de confirmar en el CTA. La celda
                        // queda marcada como feedback visual mientras arranca.
                        guard !isLoading, !isSkeleton else { return }
                        withAnimation(.easeInOut(duration: 0.2)) { selected = cat }
                        Haptic.medium()
                        let key = cat.apiKey
                        Task {
                            await onRequest(key, nil)
                            await MainActor.run { selected = nil }
                        }
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(isSelected ? Color.brand.opacity(0.12) : Color.groupedBg)
                                    .frame(width: 40, height: 40)
                                Image(systemName: cat.icon)
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundStyle(isSelected ? Color.brand : Color.accent)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(cat.label)
                                    .font(BT.footnoteBold)
                                    .foregroundStyle(isSelected ? Color.brand : Color.ink)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.85)
                                Text(subtitle)
                                    .font(BT.caption1)
                                    .foregroundStyle(Color.inkMuted)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.surface)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.md))
                        .overlay(RoundedRectangle(cornerRadius: Radius.md)
                            .stroke(isSelected ? Color.brand.opacity(0.4) : Color.border, lineWidth: isSelected ? 1.5 : 1))
                    }
                    .buttonStyle(.pressable)
                }
            }
            .redacted(reason: isSkeleton ? .placeholder : [])
            .disabled(isSkeleton)
            .padding(.horizontal, Spacing.edge)

            Spacer().frame(height: Spacing.md)

            // CTA pill — SOLO cuando hay un buddy asignado ("Sigue hablando
            // con X"). Las necesidades ya disparan la búsqueda directamente,
            // así que el botón genérico de buscar sobra; sin buddy activo se
            // muestra la línea de disponibilidad en su lugar.
            if activeBuddyName != nil {
            Button {
                guard canRequest else { return }
                Haptic.medium()
                let cat = selected?.apiKey
                selected = nil
                Task { await onRequest(cat ?? "general", nil) }
            } label: {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.white.opacity(0.15))
                            .frame(width: 44, height: 44)
                        if let avatarUrl = activeBuddyAvatarUrl {
                            CachedImage(urlString: avatarUrl) { img in
                                img.resizable().scaledToFill()
                            } placeholder: {
                                Color.white.opacity(0.3)
                            }
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        } else {
                            Image(systemName: "bubble.left.fill")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundStyle(.white)
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(activeBuddyName.map { "Sigue hablando con \($0)" } ?? (noBuddies ? "Sé el primero en explorar" : "Hablar con un buddy"))
                            .font(BT.footnoteBold)
                            .foregroundStyle(.white)
                        Text(activeBuddyName != nil ? "Tu buddy sigue disponible para ayudarte." : availabilityText)
                            .font(BT.caption1)
                            .foregroundStyle(.white.opacity(0.75))
                    }
                    Spacer()
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.white.opacity(0.15))
                            .frame(width: 36, height: 36)
                        if isLoading {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .tint(.white)
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: "arrow.right")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(canRequest ? Color.brand : Color.brandDisabled)
                .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
            }
            .disabled(isSkeleton || !canRequest)
            .redacted(reason: isSkeleton ? .placeholder : [])
            .accessibilityLabel(activeBuddyName.map { "Sigue hablando con \($0)" } ?? (noBuddies ? "Sé el primero en explorar" : "Hablar con un buddy"))
            .accessibilityHint(canRequest ? availabilityText : "Selecciona una categoría primero")
            .padding(.horizontal, Spacing.edge)
            .padding(.bottom, Spacing.sm)
            } else {
                // Sin buddy activo: línea de disponibilidad de la comunidad
                // (la señal que antes vivía dentro del botón).
                HStack(spacing: 6) {
                    Circle()
                        .fill(noBuddies ? Color.sand : Color.onlineGreen)
                        .frame(width: 6, height: 6)
                    Text(availabilityText)
                        .font(BT.caption1)
                        .foregroundStyle(Color.inkMuted)
                }
                .frame(maxWidth: .infinity)
                .redacted(reason: isSkeleton ? .placeholder : [])
                .padding(.horizontal, Spacing.edge)
                .padding(.bottom, Spacing.sm)
            }
        }
        .onAppear {
            if let key = preselectedCategory, selected == nil {
                selected = categories.first { $0.apiKey == key }
            }
        }
        .onDisappear {
            // La selección de categoría no debe persistir entre visitas al tab.
            // Si hay un buddy activo, el botón se habilita vía activeBuddyName, no vía selected.
            selected = nil
        }
    }
}

// MARK: – SEARCHING VIEW

private struct SearchingView: View {
    let buddyCount: Int
    var isExpandingSearch: Bool = false
    /// apiKey de la necesidad elegida — se muestra como chip para que el
    /// usuario vea con qué está buscando ayuda (nil = "general", sin chip).
    var category: String? = nil
    let onCancel: () -> Void
    @State private var appear = false

    private static let categoryMeta: [String: (icon: String, label: String)] = [
        "transport":     ("map",            "Cómo llegar"),
        "food":          ("cup.and.saucer", "Comer"),
        "translation":   ("bubble.left",    "Traducir"),
        "activities":    ("sparkles",       "Qué hacer"),
        "accommodation": ("bed.double",     "Alojamiento"),
        "emergency":     ("shield",         "Seguridad"),
    ]

    private var statusDot: Color { buddyCount > 0 ? Color.onlineGreen : Color.sand }

    private var statusText: String {
        if buddyCount <= 0 { return "Avisaremos al primer buddy disponible" }
        return buddyCount == 1 ? "1 buddy disponible cerca" : "\(buddyCount) buddies disponibles cerca"
    }

    // Copy calmante que describe lo que pasa sin exponer detalles del backend.
    private var subtitleText: String {
        isExpandingSearch
            ? "Ampliando la búsqueda para encontrarte\nel mejor buddy disponible."
            : "Estamos buscando el mejor buddy cerca de ti.\nSuele tomar solo unos minutos."
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

            Text(subtitleText)
                .font(BT.callout).foregroundStyle(Color.inkMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Spacing.sm)
                .padding(.horizontal, Spacing.edge)
                .animation(.easeInOut(duration: 0.5), value: isExpandingSearch)

            // Chip de la necesidad elegida — el usuario ve con qué busca ayuda
            if let category, let meta = Self.categoryMeta[category] {
                HStack(spacing: 6) {
                    Image(systemName: meta.icon)
                        .font(.system(size: 13, weight: .medium))
                    Text(meta.label)
                        .font(BT.footnoteBold)
                }
                .foregroundStyle(Color.brand)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.brand.opacity(0.10), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.brand.opacity(0.25), lineWidth: 1))
                .padding(.top, Spacing.md)
                .accessibilityLabel("Buscando ayuda con \(meta.label)")
            }

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
            .onAppear {
                    appear = true
                    UIAccessibility.post(notification: .announcement,
                        argument: "Buscando un buddy para ti. Esto toma solo unos minutos.")
                }
                .onDisappear { appear = false }

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
    var journey: APIJourney? = nil
    var initialCategory: String? = nil

    @Environment(\.dismiss) private var dismiss

    // LocationService is read only at action time (sendLocation), not in body.
    // Using LocationService.current avoids subscribing to objectWillChange and
    // prevents the whole chat view from re-rendering on every GPS fix.

    private var effectiveUserId: String? { Session.travelerId }
    @Environment(\.scenePhase) private var scenePhase

    @State private var matchStatus:   String = ""
    @State private var messages:      [APIMessage] = []
    @State private var inputText      = ""
    @State private var isSending        = false
    @State private var sendFailed       = false
    @State private var pendingSendKey   = ""   // idempotency key para el retry
    @State private var sseTask:           Task<Void, Never>?
    @State private var markReadTask:      Task<Void, Never>?   // debounce markMessagesRead
    @StateObject private var recVM    = AudioRecorderVM()
    @Namespace private var bottomID
    @FocusState private var inputFocused: Bool
    @GestureState private var micDragX: CGFloat = .zero
    @State private var micHoldTask:              Task<Void, Never>? = nil
    @State private var keyboardWasOpenOnRecordStart = false
    /// Burbuja optimista de audio: se muestra inmediatamente con el archivo local
    @State private var pendingAudioLocalURL: URL? = nil
    /// Card de cierre de ciclo — dismissible si el usuario quiere seguir
    @State private var closeCardDismissed = false
    @State private var reportSent         = false
    @State private var showCloseConfirm = false
    @State private var isSendingLocation = false
    @State private var showPhotoPicker   = false
    @State private var locationFailed    = false

    private enum ChatSheet: Identifiable {
        case attach, camera, placePicker, closeFeedback, report
        var id: Self { self }
    }
    @State private var activeSheet: ChatSheet?
    @State private var isSendingImage    = false
    @State private var resolvedDestinationId: String? = nil
    // Pagination
    @State private var hasMoreMessages  = true
    @State private var isLoadingMore    = false
    /// Prevents loadMoreMessages() from firing before the initial scroll-to-bottom
    /// completes. Without this guard the ProgressView at the top of LazyVStack is
    /// immediately visible (before any scroll) and triggers a second batch fetch,
    /// producing up to 3 competing scrollTo(bottomID) calls on first open.
    @State private var initialScrollDone = false
    /// True while the user is at (or very close to) the bottom of the message list.
    /// Used to decide whether to re-scroll when the keyboard appears: if the user
    /// is reading history we must NOT scroll them away; if they're at the bottom we
    /// must keep the last message visible as the keyboard rises.
    @State private var isNearBottom = true
    /// ID of the message that was at the top of the visible area just BEFORE a
    /// load-more prepend. After the prepend, onChange(prependAnchorId) scrolls
    /// back to that message so the user's reading position is preserved.
    @State private var prependAnchorId: String? = nil
    /// Count of new messages that arrived via SSE while the user was scrolled up
    /// reading history. Drives the "↓ N nuevos" floating button.
    @State private var unseenCount = 0
    /// True while the other participant has an active SSE connection to this chat.
    /// Driven by `event: presence` from buddy-core — never hardcoded.
    @State private var buddyIsOnline: Bool = false

    // ── Keyboard latency investigation (temporary instrumentation) ──────────
    @State private var keyboardSignpostState: OSSignpostIntervalState? = nil
    @State private var lastTapTimestamp: Double? = nil

    /// Muestra la card si han pasado >10 min desde el inicio del match y el último msg es del buddy
    private var shouldShowCloseCard: Bool {
        guard matchStatus != "completed" else { return false }
        guard !closeCardDismissed, pendingAudioLocalURL == nil else { return false }
        guard let last = messages.last else { return false }
        let isFromBuddy = last.senderId != effectiveUserId
        let matchStart = match.matchedAt ?? match.createdAt ?? Date()
        let tenMinPassed = Date().timeIntervalSince(matchStart) > 10 * 60
        return isFromBuddy && tenMinPassed
    }

    // When the current user is the buddy, show traveler info (not their own)
    private var isCurrentUserBuddy: Bool {
        effectiveUserId == match.buddyId
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
                Button { Haptic.light(); dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.ink)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .padding(.leading, -10)   // mantiene el glifo cerca del borde pese al target 44

                // Avatar
                ZStack(alignment: .bottomTrailing) {
                    if let url = buddyAvatarUrl {
                        CachedImage(urlString: url) { img in
                            img.resizable().scaledToFill()
                        } placeholder: {
                            Circle().fill(Color.sandLight)
                                .overlay(Text(buddyInitials).font(.system(size: 14, weight: .bold)).foregroundStyle(Color.sand))
                        }
                        .frame(width: 38, height: 38)
                        .clipShape(Circle())
                    } else {
                        Circle()
                            .fill(Color.sandLight)
                            .frame(width: 38, height: 38)
                            .overlay(
                                Text(buddyInitials)
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(Color.sand)
                            )
                    }
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(buddyName)
                        .font(BT.headline)
                        .foregroundStyle(Color.ink)
                    HStack(spacing: 4) {
                        if buddyIsOnline {
                            Circle()
                                .fill(Color.onlineGreen)
                                .frame(width: 7, height: 7)
                        }
                        Text(buddyIsOnline ? "en línea" : (isCurrentUserBuddy ? "Tu viajero" : "Tu buddy"))
                            .font(BT.caption1)
                            .foregroundStyle(buddyIsOnline ? Color.onlineGreen : Color.inkMuted)
                    }
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
                        activeSheet = .report
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
                .accessibilityLabel("Opciones de conversación")
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
                                .onAppear {
                                    // Only load older messages once the initial scroll
                                    // to the bottom has completed. Before that moment the
                                    // ProgressView is technically "visible" at the top of
                                    // the unscrolled LazyVStack, and firing here causes a
                                    // duplicate fetch + multiple competing scrollTo calls.
                                    guard initialScrollDone else { return }
                                    Task { await loadMoreMessages() }
                                }
                        }
                        if messages.isEmpty {
                            welcomeMessage.padding(.top, Spacing.xl)
                        }
                        ForEach(Array(messages.enumerated()), id: \.element.id) { i, msg in
                            messageRow(msg: msg, index: i)
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
                            .accessibilityLabel("Mensaje de audio enviando…")
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
                            .onAppear   { isNearBottom = true  }
                            .onDisappear { isNearBottom = false }
                    }
                    .padding(.horizontal, Spacing.edge)
                    .padding(.vertical, Spacing.md)
                }
                // ── Keyboard: allow swipe-to-dismiss like iMessage ────────────
                // .interactively lets the user drag the keyboard down with a scroll
                // gesture, matching the WhatsApp / iMessage UX pattern.
                .scrollDismissesKeyboard(.interactively)
                // ── Input bar as safeAreaInset (the iMessage pattern) ─────────
                // Placing the input bar here instead of below the ScrollView is the
                // key fix. safeAreaInset anchors the input bar to the ScrollView's
                // safe area bottom:
                //  • When the keyboard appears, iOS updates safeAreaInsets.bottom →
                //    the input bar rises WITH the keyboard in the same animation,
                //    same curve — no double animation, no jump.
                //  • The ScrollView's contentInset.bottom auto-expands by the
                //    combined height of (input bar + keyboard), so the last message
                //    is never hidden behind either.
                //  • UIKit's UIScrollView maintains the "at-bottom" contentOffset
                //    when contentInset increases, so the user stays at the last
                //    message automatically.
                // The explicit scrollTo below is a safety net for the cases where
                // UIKit's auto-adjustment isn't quite precise enough.
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if matchStatus == "completed" {
                        closedBar
                    } else {
                        chatInputBar
                    }
                }
                .overlay(alignment: .bottom) {
                    // "↓ N nuevos" badge — shown when new SSE messages arrive while
                    // the user is reading history (isNearBottom == false).
                    // Tapping scrolls to the bottom and resets the counter.
                    if unseenCount > 0 {
                        Button {
                            unseenCount = 0
                            isNearBottom = true
                            withAnimation(.easeOut(duration: 0.25)) {
                                proxy.scrollTo(bottomID, anchor: .bottom)
                            }
                        } label: {
                            Label(
                                unseenCount == 1 ? "1 nuevo" : "\(unseenCount) nuevos",
                                systemImage: "chevron.down"
                            )
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.accentColor, in: Capsule())
                            .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
                        }
                        .padding(.bottom, 12)
                        .transition(.scale.combined(with: .opacity))
                        .animation(.spring(duration: 0.3), value: unseenCount)
                    }
                }
                .onChange(of: messages.count) { oldCount, newCount in
                    if !initialScrollDone {
                        // ── First load: jump to bottom instantly, zero animation ──
                        // withAnimation(nil) suppresses the animation context so the
                        // scroll is a hard jump, not the slide-from-top the user would
                        // otherwise see (the WhatsApp anti-pattern).
                        withAnimation(nil) { proxy.scrollTo(bottomID, anchor: .bottom) }
                        initialScrollDone = true
                        isNearBottom = true
                        print("⏱ [scroll] initial jump done — \(newCount) messages")
                    } else if !isLoadingMore && newCount > oldCount {
                        // ── New message appended (SSE / send) ────────────────────
                        if isNearBottom {
                            // User is at the bottom: scroll them to the new message
                            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(bottomID, anchor: .bottom) }
                        } else {
                            // User is reading history: show a "N nuevos" badge instead
                            unseenCount += (newCount - oldCount)
                            print("📬 [scroll] \(newCount - oldCount) new msg(s) while reading — unseenCount=\(unseenCount)")
                        }
                    }
                    // Load-more prepends older messages (isLoadingMore == true):
                    // position is restored by onChange(of: prependAnchorId) below.
                }
                .onChange(of: prependAnchorId) { _, anchorId in
                    guard let anchorId else { return }
                    // After prepend, ScrollView resets contentOffset to 0 (top of the
                    // now-larger content), showing the freshly-added older messages.
                    // Jumping to anchorId with .top anchor restores the user's visual
                    // position so load-more feels seamless, not jarring.
                    withAnimation(nil) { proxy.scrollTo(anchorId, anchor: .top) }
                    print("⏱ [scroll] position restored after prepend → anchor=\(anchorId.prefix(6))")
                    prependAnchorId = nil
                }
                .onChange(of: pendingAudioLocalURL) { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(bottomID, anchor: .bottom) }
                    isNearBottom = true
                }
                .onChange(of: inputFocused) { _, focused in
                    let t = KeyboardTiming.now()
                    print("⌨️ [focus] inputFocused → \(focused) t=\(String(format: "%.3f", t.truncatingRemainder(dividingBy: 1000)))")
                    if focused, let tap = lastTapTimestamp {
                        print("⏱ [keyboard] tap→focus delta = \(String(format: "%.1f", (t - tap) * 1000))ms")
                    }
                    print("🎙️ [mic] inputFocused changed → \(focused) (isRecording=\(recVM.isRecording))")
                    // If the keyboard was dismissed while actively recording, restore it
                    // immediately. AVAudioSession activation (.playAndRecord) can interrupt
                    // the system audio session and cause UIKit to resign first-responder,
                    // which would collapse the input bar and move the mic button down.
                    if !focused && recVM.isRecording {
                        inputFocused = true
                        print("🎙️ [mic] inputFocused restored — keeping keyboard up during recording")
                        return
                    }
                    // When the keyboard appears and the user was already at the bottom,
                    // scroll explicitly to pin the last message just above the input bar.
                    // The safeAreaInset handles the geometry automatically, but
                    // UIKit's contentOffset adjustment has ~1 frame of lag — this
                    // call eliminates that lag so the user never sees a gap.
                    // If the user is reading history (isNearBottom == false), we must
                    // NOT scroll them away from where they are.
                    guard focused && isNearBottom else { return }
                    // 1-frame delay: let the safeAreaInset height update propagate first
                    // so scrollTo targets the correct final position.
                    DispatchQueue.main.async {
                        withAnimation(.easeOut(duration: 0.25)) {
                            proxy.scrollTo(bottomID, anchor: .bottom)
                        }
                    }
                }
                .onChange(of: recVM.isRecording) { _, isRecording in
                    guard !isRecording else { return }
                    // Recording ended: the body re-render makes the TextField
                    // visible+interactive again, and UIKit may restore it as
                    // first-responder synchronously during that render pass.
                    // Deferring to the next run loop ensures we override that
                    // restoration AFTER it happens, before keyboard animation starts.
                    DispatchQueue.main.async {
                        if recVM.cancelled && keyboardWasOpenOnRecordStart {
                            // Cancel by slide: keyboard was open before recording → restore it
                            inputFocused = true
                            print("🎙️ [mic] isRecording ended (cancelled) → keyboard restored (was open before recording)")
                        } else {
                            inputFocused = false
                            print("🎙️ [mic] isRecording ended → force-cleared focus (deferred)")
                        }
                    }
                }
            }
        }
        .background(Color.canvas)
        .navigationBarHidden(true)
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .closeFeedback:
                CloseFeedbackSheet(buddyName: buddyName, buddyAvatarUrl: buddyAvatarUrl) { feeling, pressure in
                    activeSheet = nil
                    Task { await closeMatch(feeling: feeling, pressure: pressure) }
                } onDismiss: {
                    activeSheet = nil
                }
            case .report:
                ReportUserSheet(
                    buddyName: buddyName,
                    matchId: match.id,
                    reportedUserId: (isCurrentUserBuddy ? match.traveler?.id : match.buddy?.id) ?? ""
                ) {
                    activeSheet = nil
                    reportSent = true
                }
            case .attach:
                attachSheet
                    .presentationDetents([.height(220)])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(Color.canvas)
            case .camera:
                CameraPickerView { image in
                    if let data = image.jpegData(compressionQuality: 0.82) {
                        Task { await sendImage(data: data) }
                    }
                }
                .ignoresSafeArea()
            case .placePicker:
                PlacePickerSheet(destinationId: resolvedDestinationId) { name, lat, lng in
                    activeSheet = nil
                    Task {
                        let content = "place:\(lat)|\(lng)|\(name)|"
                        if let msg = try? await APIClient.shared.sendMessage(matchId: match.id, content: content) {
                            await MainActor.run { messages.append(msg) }
                        }
                    }
                }
            }
        }
        .toast(isPresented: $reportSent, message: "Reporte enviado. Lo revisaremos pronto.")
        .task {
            matchStatus = match.status
            ChatPresenceTracker.shared.activeChatMatchId = match.id

            // ── Synchronous: instant ──────────────────────────────────────────
            resolvedDestinationId = journey?.destination?.id ?? journey?.destinationId

            // ── 1. Show cached history immediately (0ms) ─────────────────────
            // ChatStore.messageCache holds the last N messages fetched or received
            // via SSE for this match. Reading it here makes re-opening an already-
            // visited chat feel instant: the conversation appears before the network
            // response arrives.
            // initialScrollDone starts false → onChange(messages.count) will fire
            // and trigger the instant no-animation scroll-to-bottom.
            let cached = ChatStore.shared.cachedHistory(for: match.id)
            if let cached, !cached.isEmpty {
                messages = cached
                print("⏱ [chat] cache hit — \(cached.count) msgs shown instantly")
            }

            // ── 2. Background fetch (network) ────────────────────────────────
            // loadMessages() now merges new arrivals into the array instead of
            // replacing it, so a cache hit above doesn't lose its scroll state.
            // fetchHelpRequestInfo runs concurrently (only needed when no journey).
            if resolvedDestinationId == nil {
                async let destFetch = APIClient.shared.fetchHelpRequestInfo(requestId: match.requestId)
                await loadMessages()
                resolvedDestinationId = (try? await destFetch)?.destinationId
            } else {
                await loadMessages()
            }

            // ── category_card send ───────────────────────────────────────────
            // Kept sequential (before startSSE) to avoid a timing race:
            // if SSE starts first and the server echoes the category_card message
            // back on the stream before sendMessage() returns, the SSE path
            // (which has a dedup guard) appends it; then sendMessage() returns the
            // same message and the direct append would create a duplicate.
            // Keeping this before startSSE() eliminates that window entirely.
            if let cat = initialCategory {
                if let msg = try? await APIClient.shared.sendMessage(matchId: match.id, content: "category_card:\(cat)") {
                    if !messages.contains(where: { $0.id == msg.id }) {
                        messages.append(msg)
                    }
                }
            }

            // ── SSE starts AFTER loadMessages() ─────────────────────────────
            // Race condition avoided: if SSE started before loadMessages(),
            // a message arriving on the stream before loadMessages() completes
            // would be appended to `messages`; then the merge in loadMessages()
            // would already include it (dedup by id), so the SSE append would
            // be a no-op. Keeping SSE after loadMessages() costs ~0ms with
            // zero correctness risk.
            startSSE()

            // ── Fire-and-forget: don't block the UI ─────────────────────────
            // markMessagesRead is housekeeping that doesn't affect visible state.
            // ChatStore.load is intentionally NOT called here: the SSE connection
            // already delivers real-time updates, and calling load() would trigger
            // parallel /messages fetches + a full parent re-render cascade.
            // ChatStore.load() is only called when leaving the chat (closeMatch /
            // closeAsHelper / SSE match-completed event) so the chat list badge
            // and last-message preview update at the right moment.
            Task { await APIClient.shared.markMessagesRead(matchId: match.id) }
        }
        .onDisappear {
            print("🔌 [presence] chat onDisappear — cancelling SSE (leaves 'online')")
            sseTask?.cancel()
            if ChatPresenceTracker.shared.activeChatMatchId == match.id {
                ChatPresenceTracker.shared.activeChatMatchId = nil
            }
        }
        // "En línea" debe significar "dentro del app/chat, listo para responder" — no solo
        // "el socket SSE aún no murió". Sin esto, al mandar la app a segundo plano el stream
        // sigue vivo hasta que iOS lo suspende (puede tardar), y el otro participante seguiría
        // viendo el punto verde aunque el usuario ya no esté mirando la pantalla.
        .onChange(of: scenePhase) { oldPhase, newPhase in
            print("📲 [presence] scenePhase \(oldPhase) → \(newPhase) (match=\(match.id.prefix(6)))")
            if newPhase == .background {
                print("🔌 [presence] app backgrounded — cancelling SSE so the other side sees 'offline'")
                sseTask?.cancel()
                buddyIsOnline = false
            } else if newPhase == .active, oldPhase == .background {
                print("🔌 [presence] app foregrounded — reconnecting SSE so the other side sees 'online' again")
                startSSE()
            }
        }
        // Notificación tapeada mientras el chat ya estaba en pantalla → recargar mensajes.
        // No llamar startSSE() si ya hay una conexión activa (evita dos SSE simultáneos
        // cuando foreground + push llegan al mismo tiempo).
        .onReceive(NotificationCenter.default.publisher(for: .openChatForMatch)) { note in
            guard note.userInfo?["match_id"] as? String == match.id else { return }
            Task {
                await loadMessages()
                if sseTask == nil || sseTask!.isCancelled { startSSE() }
            }
        }
        // Re-evalúa la card cada 60s (por si el tiempo supera los 10 min mientras el chat está abierto)
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
            guard !closeCardDismissed, matchStatus != "completed" else { return }
            if shouldShowCloseCard { closeCardDismissed = false }
        }
        // Keyboard timing instrumentation — measures gap between FocusState change and actual keyboard animation
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { n in
            let t = KeyboardTiming.now()
            let duration = (n.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0
            print("⌨️ [keyboard] willShow t=\(String(format: "%.3f", t.truncatingRemainder(dividingBy: 1000))) animDuration=\(String(format: "%.2f", duration))s")
            if let tap = lastTapTimestamp {
                print("⏱ [keyboard] tap→willShow delta = \(String(format: "%.1f", (t - tap) * 1000))ms")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
            let t = KeyboardTiming.now()
            print("⌨️ [keyboard] didShow t=\(String(format: "%.3f", t.truncatingRemainder(dividingBy: 1000)))")
            if let tap = lastTapTimestamp {
                print("⏱ [keyboard] tap→didShow TOTAL = \(String(format: "%.1f", (t - tap) * 1000))ms  ← this is what the user actually perceives")
            }
            if let state = keyboardSignpostState {
                KeyboardTiming.signposter.endInterval("TapToKeyboard", state)
                keyboardSignpostState = nil
            }
            lastTapTimestamp = nil
        }
        .alert("No se pudo enviar", isPresented: $sendFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("El mensaje no se envió. Inténtalo de nuevo.")
        }
        .alert("Sin acceso a tu ubicación", isPresented: $locationFailed) {
            Button("Abrir ajustes") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Permite el acceso a tu ubicación en Ajustes para compartirla.")
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
        // Keyboard pre-warmer: pays the iOS keyboard subsystem init cost (~400–800ms on
        // real device) during the chat's appear transition — the right moment because:
        //   1. The user already tapped "Hablar con un buddy" / opened the chat — there is
        //      clear intent to write; the Home screen remains completely unaware of this.
        //   2. The user is reading messages for several seconds before typing — the init
        //      runs in the background with zero visual artifact (inputView = UIView() means
        //      UIKit shows no keyboard UI, only initialises the text-input service).
        //   3. Only runs once per process lifetime (KeyboardPrewarmer.hasWarmed guard).
        .background(KeyboardPrewarmer())
    }

    /// Enruta el cierre según el rol: el buddy confirma; el viajero responde la
    /// encuesta de cierre.
    private func requestClose() {
        if isCurrentUserBuddy { showCloseConfirm = true }
        else                  { activeSheet = .closeFeedback }
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
    // KEY INVARIANT: TextField stays in the view tree at all times (opacity 0 when
    // recording). This prevents the keyboard from dismissing on recording start,
    // which is what causes the mic button to "jump" when the keyboard slides away.
    // The + button is also always in the tree (opacity 0 when recording) so the
    // HStack never redistributes its widths.
    private var chatInputBar: some View {
        let hasText   = !inputText.trimmingCharacters(in: .whitespaces).isEmpty
        let recording = recVM.isRecording
        let cancelled = micDragX < -80

        return VStack(spacing: 0) {
            if isSendingImage {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.75)
                    Text("Enviando imagen…")
                        .font(BT.caption1)
                        .foregroundStyle(Color.inkMuted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Spacing.edge)
                .padding(.vertical, 6)
            }
            Divider()
            HStack(spacing: 8) {

                // ── Left: + button — always in layout, invisible while recording ──
                Button {
                    Haptic.light()
                    inputFocused = false
                    activeSheet = .attach
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.inkMuted)
                        .frame(width: 38, height: 38)
                        .background(Color.canvas)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(Color.border, lineWidth: 1))
                }
                .opacity(recording ? 0 : 1)
                .allowsHitTesting(!recording)
                .accessibilityLabel("Adjuntar archivo")

                // ── Center: TextField always in tree; recording UI overlaid ──
                ZStack(alignment: .leading) {
                    // TextField always present — keeps keyboard anchored.
                    // allowsHitTesting is intentionally NOT disabled during recording:
                    // disabling it on a first-responder UITextField causes UIKit to
                    // resign first responder, which collapses the keyboard and moves
                    // the mic button. The recording overlay above absorbs gestures.
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
                        .opacity(recording ? 0 : 1)
                        // Raw tap timestamp — fires on touch-down, before FocusState even
                        // updates. simultaneousGesture so it never steals the tap from
                        // the TextField's own first-responder handling.
                        .simultaneousGesture(
                            TapGesture().onEnded {
                                let t = KeyboardTiming.now()
                                lastTapTimestamp = t
                                keyboardSignpostState = KeyboardTiming.signposter.beginInterval("TapToKeyboard")
                                print("👆 [keyboard] raw tap t=\(String(format: "%.3f", t.truncatingRemainder(dividingBy: 1000)))")
                            }
                        )

                    // Recording UI fades in over the TextField, same frame
                    if recording {
                        HStack(spacing: 0) {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(Color.errorRed)
                                    .frame(width: 8, height: 8)
                                    .opacity(recVM.seconds % 2 == 0 ? 1 : 0.3)
                                    .animation(
                                        .easeInOut(duration: 0.5).repeatForever(autoreverses: true),
                                        value: recVM.seconds
                                    )
                                Text(fmtSecs(recVM.seconds))
                                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(Color.ink)
                            }
                            Spacer()
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.left")
                                    .font(.system(size: 12, weight: .medium))
                                Text("Desliza para cancelar")
                                    .font(BT.callout)
                            }
                            .foregroundStyle(cancelled ? Color.errorRed : Color.inkMuted)
                            .offset(x: max(micDragX * 0.6, -110))
                            .animation(.interactiveSpring(), value: micDragX)
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.15), value: recording)

                // ── Right: send (text mode) OR mic (no text / recording) ──
                if hasText && !recording {
                    Button {
                        guard !isSending else { return }
                        isSending = true
                        Task {
                            defer { isSending = false }
                            await sendMessage()
                        }
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 42, height: 42)
                            .background(isSending ? Color.teal.opacity(0.4) : Color.teal)
                            .clipShape(Circle())
                    }
                    .disabled(isSending)
                    .accessibilityLabel("Enviar mensaje")
                    .transition(.scale.combined(with: .opacity))
                } else if !hasText {
                    // Mic button — single persistent gesture; never removed from tree
                    ZStack {
                        // Pulsing halo while recording
                        Circle()
                            .fill(cancelled ? Color.errorRed.opacity(0.15) : Color.teal.opacity(0.15))
                            .frame(width: 54, height: 54)
                            .scaleEffect(recording ? 1.12 : 0.01)
                            .animation(
                                recording
                                    ? .easeInOut(duration: 0.6).repeatForever(autoreverses: true)
                                    : .easeOut(duration: 0.15),
                                value: recording
                            )

                        Image(systemName: "mic.fill")
                            .font(.system(size: recording ? 22 : 18, weight: .medium))
                            .foregroundStyle(
                                recording ? (cancelled ? Color.errorRed : Color.teal) : Color.inkMuted
                            )
                            .frame(width: 42, height: 42)
                            .background(
                                recording
                                    ? (cancelled ? Color.errorRed.opacity(0.1) : Color.teal.opacity(0.1))
                                    : Color.canvas
                            )
                            .clipShape(Circle())
                            .overlay(!recording ? Circle().stroke(Color.border, lineWidth: 1) : nil)
                            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: recording)
                    }
                    .accessibilityLabel(recVM.isRecording ? "Grabando. Desliza para cancelar." : "Grabar mensaje de voz")
                    .accessibilityHint(recVM.isRecording ? "" : "Mantén presionado para grabar")
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .updating($micDragX) { val, state, _ in
                                state = min(0, val.translation.width)
                            }
                            .onChanged { _ in
                                guard micHoldTask == nil, !recVM.isRecording else { return }
                                let wasKeyboardOpen = inputFocused
                                keyboardWasOpenOnRecordStart = wasKeyboardOpen
                                print("🎙️ [mic] onChanged — inputFocused=\(wasKeyboardOpen) isRecording=\(recVM.isRecording)")
                                // Do NOT dismiss keyboard here — it would move the input bar
                                // (and the mic button with it) while the user is pressing.
                                // Keyboard is dismissed in stopAndSendAudio / cancel instead.
                                micHoldTask = Task {
                                    // 150ms: tap releases before this → nothing happens
                                    print("🎙️ [mic] sleeping 150ms — keyboardWasOpen=\(wasKeyboardOpen)")
                                    try? await Task.sleep(nanoseconds: 150_000_000)
                                    if Task.isCancelled {
                                        print("🎙️ [mic] task cancelled during 150ms sleep — gesture ended too early")
                                        return
                                    }
                                    print("🎙️ [mic] calling recVM.start()")
                                    let ok = await recVM.start()
                                    print("🎙️ [mic] recVM.start() → \(ok)")
                                    if ok { Haptic.medium() }
                                    await MainActor.run { micHoldTask = nil }
                                }
                            }
                            .onEnded { val in
                                let tx = val.translation.width
                                let wasRecording = recVM.isRecording
                                let hadTask = micHoldTask != nil
                                print("🎙️ [mic] onEnded — tx=\(Int(tx)) isRecording=\(wasRecording) hadTask=\(hadTask)")
                                micHoldTask?.cancel()
                                micHoldTask = nil
                                guard recVM.isRecording else {
                                    print("🎙️ [mic] onEnded — not recording (tap too short or start failed)")
                                    return
                                }
                                if tx < -80 {
                                    print("🎙️ [mic] onEnded — cancelled by slide (tx=\(Int(tx))) keyboardWasOpen=\(keyboardWasOpenOnRecordStart)")
                                    // Only close keyboard if it wasn't open before recording started.
                                    // If the user had the keyboard up, we restore it after cancel.
                                    if !keyboardWasOpenOnRecordStart { inputFocused = false }
                                    recVM.cancel()
                                    Haptic.light()
                                } else {
                                    print("🎙️ [mic] onEnded — sending audio")
                                    Task { await stopAndSendAudio() }
                                }
                            }
                    )
                }
            }
            .padding(.horizontal, Spacing.edge)
            .padding(.vertical, 10)
            .background(Color.surface)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: hasText)
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: Binding(
            get: { [] },
            set: { items in
                if let item = items.first {
                    Task { await sendPickedPhoto(item) }
                }
            }
        ), maxSelectionCount: 1, matching: .images)
    }

    private var attachSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Compartir")
                .font(BT.footnoteBold)
                .foregroundStyle(Color.inkMuted)
                .padding(.horizontal, Spacing.edge)
                .padding(.top, Spacing.lg)
                .padding(.bottom, Spacing.md)

            HStack(spacing: 0) {
                attachOption(icon: "photo.fill", label: "Fotos", color: .purple) {
                    activeSheet = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { showPhotoPicker = true }
                }
                attachOption(icon: "camera.fill", label: "Cámara", color: .brand) {
                    activeSheet = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { activeSheet = .camera }
                }
                attachOption(icon: "location.fill", label: "Ubicación", color: .teal) {
                    activeSheet = nil
                    Task { await sendLocation() }
                }
                attachOption(icon: "map.fill", label: "Locaciones", color: .orange) {
                    activeSheet = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { activeSheet = .placePicker }
                }
            }
            .padding(.horizontal, Spacing.edge)
            .padding(.bottom, Spacing.xl)
        }
    }

    private func attachOption(icon: String, label: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(color.opacity(0.15))
                        .frame(width: 58, height: 58)
                    Image(systemName: icon)
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(color)
                }
                Text(label)
                    .font(BT.caption1)
                    .foregroundStyle(Color.ink)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    private func sendPickedPhoto(_ item: PhotosPickerItem) async {
        print("📷 [chat] sendPickedPhoto — loading transferable…")
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            print("❌ [chat] sendPickedPhoto — loadTransferable falló (nil)")
            return
        }
        print("📷 [chat] sendPickedPhoto — data cargada: \(data.count / 1024) KB")
        await sendImage(data: data)
    }

    private func sendImage(data: Data) async {
        print("📤 [chat] sendImage — \(data.count / 1024) KB → matchId=\(match.id)")
        await MainActor.run { isSendingImage = true }
        let clientId = UUID().uuidString
        do {
            let msg = try await APIClient.shared.uploadChatImage(matchId: match.id, imageData: data, clientMessageId: clientId)
            print("✅ [chat] sendImage — mensaje recibido id=\(msg.id) imageUrl=\(msg.imageUrl ?? "nil")")
            await MainActor.run { messages.append(msg) }
        } catch {
            print("❌ [chat] sendImage — error: \(error)")
            await MainActor.run { sendFailed = true }
        }
        await MainActor.run { isSendingImage = false }
    }

    private var welcomeMessage: some View {
        VStack(spacing: Spacing.sm) {
            Circle()
                .fill(Color.sandLight)
                .frame(width: 64, height: 64)
                .overlay {
                    if let urlStr = buddyAvatarUrl {
                        CachedImage(urlString: urlStr) { img in img.resizable().scaledToFill() }
                            placeholder: { Color.sandLight }
                            .clipShape(Circle())
                    } else {
                        Text(buddyInitials)
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(Color.sand)
                    }
                }
            Text(isCurrentUserBuddy ? "Acompañando a \(buddyName)" : "Conectado con \(buddyName)")
                .font(BT.title3).foregroundStyle(Color.ink)
            Text(isCurrentUserBuddy
                 ? "Puedes ayudar a \(buddyName) con lo que necesite al llegar."
                 : "Tu buddy te ayudará con todo en \(journey?.destination?.name ?? "tu destino").")
                .font(BT.callout).foregroundStyle(Color.inkMuted).multilineTextAlignment(.center)
        }
        .padding(Spacing.edge)
    }

    private func dateSeparator(_ date: Date?) -> some View {
        let label = date.map { BuddyMessageBubble.dateSepFormatter.string(from: $0) } ?? ""
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

    /// Extracted from ForEach to keep BuddyChatView.body small enough for the
    /// Swift type-checker. Complex ViewBuilder expressions with nested conditions,
    /// local lets, and chained modifiers can exceed the type-check budget when
    /// inlined directly inside a large body.
    @ViewBuilder
    private func messageRow(msg: APIMessage, index i: Int) -> some View {
        if i == 0 || !sameDay(messages[i-1].createdAt, msg.createdAt) {
            dateSeparator(msg.createdAt)
        }
        let isMe = msg.senderId != nil && msg.senderId == effectiveUserId
        let prevSame = i > 0 && messages[i-1].senderId == msg.senderId
        BuddyMessageBubble(message: msg, isMe: isMe, onDismissSheet: { dismiss() })
            .equatable()  // skips body re-eval when message.id + isMe are unchanged
            .padding(.bottom, prevSame ? 2 : 6)
            .onAppear {
                #if DEBUG
                BuddyMessageBubble._appears += 1
                print("👁 [virtual] onAppear #\(BuddyMessageBubble._appears) idx=\(i) id=\(msg.id.prefix(6))")
                #endif
            }
    }

    private func loadMessages() async {
        let t0 = Date()
        do {
            let fetched = try await APIClient.shared.fetchMessages(matchId: match.id, limit: 30)
            let networkMs = Int(Date().timeIntervalSince(t0) * 1000)
            if messages.isEmpty {
                // Cold open (no cache) — simple assign
                messages = fetched
            } else {
                // Cache was pre-loaded — merge: keep any SSE messages that arrived
                // while the fetch was in flight, append fetched that aren't present
                let existingIds = Set(messages.map(\.id))
                let newOnes = fetched.filter { !existingIds.contains($0.id) }
                if !newOnes.isEmpty {
                    // Insert fetched (older) before the SSE-only tail
                    // fetched is sorted newest-last from the API
                    messages = fetched + messages.filter { msg in
                        !fetched.contains(where: { $0.id == msg.id })
                    }
                }
                print("⏱ [chat] loadMessages merge: \(fetched.count) fetched, \(newOnes.count) new, total=\(messages.count)")
            }
            hasMoreMessages = fetched.count == 30
            // Write to cache so next open is instant
            ChatStore.shared.updateCache(messages, for: match.id)
            print("⏱ [chat] loadMessages: \(fetched.count) msgs, network=\(networkMs)ms, cache written")
        } catch {
            print("❌ loadMessages error → \(error)")
        }
    }

    private func loadMoreMessages() async {
        guard hasMoreMessages, !isLoadingMore, let oldest = messages.first?.createdAt else { return }
        isLoadingMore = true
        isNearBottom = false  // user scrolled up to load history → don't auto-scroll on keyboard
        prependAnchorId = messages.first?.id  // capture before prepend for position restore
        defer { isLoadingMore = false }
        do {
            let fetched = try await APIClient.shared.fetchMessages(matchId: match.id, limit: 30, before: oldest)
            if fetched.isEmpty {
                hasMoreMessages = false
                prependAnchorId = nil
            } else {
                messages = fetched + messages
                hasMoreMessages = fetched.count == 30
                // Cache updated with full history
                ChatStore.shared.updateCache(messages, for: match.id)
            }
        } catch {
            print("❌ loadMoreMessages error → \(error)")
            prependAnchorId = nil
        }
    }

    // Debounce: 10 mensajes en ráfaga = 1 PATCH, no 10.
    private func scheduleMarkRead() {
        markReadTask?.cancel()
        markReadTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)   // 300 ms
            guard !Task.isCancelled else { return }
            await APIClient.shared.markMessagesRead(matchId: match.id)
        }
    }

    private func sendMessage() async {
        let text = inputText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, let _ = effectiveUserId else { return }
        Haptic.light()
        inputText = ""
        // Genera clave sólo si es un envío nuevo (no un retry).
        // El retry reutiliza pendingSendKey para que el servidor devuelva
        // el mensaje ya creado en vez de duplicarlo.
        if pendingSendKey.isEmpty { pendingSendKey = UUID().uuidString }
        let key = pendingSendKey
        do {
            let msg = try await APIClient.shared.sendMessage(matchId: match.id, content: text, idempotencyKey: key)
            pendingSendKey = ""   // éxito — siguiente envío usa clave nueva
            messages.append(msg)
        } catch {
            // Restore text so the user can retry; pendingSendKey se mantiene para el retry
            inputText = text
            sendFailed = true
            print("❌ [chat] sendMessage failed: \(error)")
        }
        // ChatStore.load() omitted: SSE handles the delivered message bubble;
        // load() would fire 11 parallel network fetches for no visible benefit.
    }

    private func sendLocation() async {
        guard let loc = LocationService.current?.userLocation else {
            Haptic.light()
            await MainActor.run { locationFailed = true }
            return
        }
        guard effectiveUserId != nil else { return }
        isSendingLocation = true
        let lat = loc.coordinate.latitude
        let lng = loc.coordinate.longitude
        let content = "location:\(lat),\(lng)"
        if let msg = try? await APIClient.shared.sendMessage(matchId: match.id, content: content) {
            messages.append(msg)
        }
        isSendingLocation = false
    }

    private func stopAndSendAudio() async {
        print("🎙️ [mic] stopAndSendAudio() called — stopping recorder")
        // Set inputFocused = false BEFORE recVM.stop() publishes isRecording = false.
        // When isRecording goes false, SwiftUI re-renders and UIKit tries to restore
        // first responder to the TextField. Pre-emptively clearing focus blocks that.
        inputFocused = false
        guard let fileURL = recVM.stop() else {
            print("🎙️ [mic] stopAndSendAudio() — recVM.stop() returned nil (was cancelled)")
            return
        }
        print("🎙️ [mic] stopAndSendAudio() — uploading \(fileURL.lastPathComponent)")
        withAnimation(.spring(response: 0.3)) { pendingAudioLocalURL = fileURL }
        Haptic.light()
        let audioClientId = UUID().uuidString
        do {
            let msg = try await recVM.upload(fileURL: fileURL, matchId: match.id, clientMessageId: audioClientId)
            print("🎙️ [mic] stopAndSendAudio() — upload OK msgId=\(msg.id.prefix(8))")
            if !messages.contains(where: { $0.id == msg.id }) {
                messages.append(msg)
            }
            withAnimation(.easeOut(duration: 0.2)) { pendingAudioLocalURL = nil }
            try? FileManager.default.removeItem(at: fileURL)
        } catch {
            print("❌ [mic] audio send error: \(error)")
            withAnimation { pendingAudioLocalURL = nil }
            sendFailed = true // reuse same "No se pudo enviar" alert
        }
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
        dismiss()
    }

    /// Cierre del buddy (quien ayuda): sin encuesta, solo marca completado.
    private func closeAsHelper() async {
        try? await APIClient.shared.updateMatchStatus(matchId: match.id, status: "completed")
        Haptic.success()
        Task { await ChatStore.shared.load() }
        NotificationCenter.default.post(name: .helpCompleted, object: nil)
        dismiss()
    }

    private func fmtSecs(_ s: Int) -> String {
        "\(s / 60):\(String(format: "%02d", s % 60))"
    }

    private func startSSE() {
        print("📡 [presence] startSSE — opening chat stream (this device → 'online')")
        sseTask?.cancel()
        sseTask = Task {
            await connectSSE()
        }
    }

    private func connectSSE() async {
        guard let url = URL(string: "\(APIClient.shared.baseURL)/messages/\(match.id)/stream") else { return }
        var attempt = 0

        while !Task.isCancelled {
            // Reset presence on every (re)connect — corrected state arrives immediately via
            // the `presence` event the backend emits for already-online participants.
            await MainActor.run { buddyIsOnline = false }
            print("📡 [presence] connectSSE — connecting to \(url.path)")
            var request = URLRequest(url: url)
            if let token = Session.token {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            request.timeoutInterval = 300 // 5 min — se reconecta si cae

            do {
                let (bytes, _) = try await URLSession.shared.bytes(for: request)
                attempt = 0   // conexión exitosa
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
                                    if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                                       let newStatus = obj["status"] as? String,
                                       let matchId   = obj["id"] as? String,
                                       matchId == match.id,
                                       ["completed", "cancelled"].contains(newStatus) {
                                        await MainActor.run {
                                            // Actualiza el estado visible: cambia el input bar a "Conexión cerrada"
                                            matchStatus = newStatus
                                            // Solo el viajero recibe la encuesta; el buddy solo ve el chat cerrarse.
                                            if newStatus == "completed" && !isCurrentUserBuddy {
                                                NotificationCenter.default.post(name: .matchCompleted, object: nil)
                                            }
                                        }
                                        await ChatStore.shared.load()
                                    }
                                } else if eventType == "presence",
                                          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                                          let presenceUserId = obj["userId"] as? String,
                                          let status          = obj["status"]  as? String,
                                          presenceUserId != effectiveUserId {
                                    print("🟢 [presence] other user \(presenceUserId) → \(status)")
                                    await MainActor.run { buddyIsOnline = status == "online" }
                                } else if let msg = try? JSONDecoder.buddy.decode(APIMessage.self, from: data) {
                                    await MainActor.run {
                                        if !messages.contains(where: { $0.id == msg.id }) {
                                            messages.append(msg)
                                        }
                                        // Keep the cache in sync so a future re-open is instant
                                        ChatStore.shared.appendToCache(msg, for: match.id)
                                    }
                                    scheduleMarkRead()
                                }
                            }
                        }
                    }
                }
            } catch {
                print("📡 [presence] SSE dropped (\(error.localizedDescription)) cancelled=\(Task.isCancelled)")
            }

            await sseBackoff(&attempt)
        }
    }
}

// Two BuddyChatView instances are "equal" for SwiftUI's optimization purposes
// when they represent the same match conversation. This lets .equatable() block
// body re-evaluation when ContactarBuddyView re-renders due to parent state
// changes (e.g. InicioView refreshTripState), avoiding 14-bubble cascade waves.
extension BuddyChatView: Equatable {
    static func == (lhs: BuddyChatView, rhs: BuddyChatView) -> Bool {
        lhs.match.id == rhs.match.id &&
        lhs.journey?.id == rhs.journey?.id &&
        lhs.initialCategory == rhs.initialCategory
    }
}

// MARK: – MESSAGE BUBBLE

struct BuddyMessageBubble: View {
    let message: APIMessage
    let isMe: Bool
    // Closure replaces @Environment(\.dismiss): DismissAction is non-Equatable,
    // so @Environment(\.dismiss) causes SwiftUI to bypass .equatable() and call
    // body on every parent re-render (inputFocused, GPS refresh, etc.).
    // Stored as a closure so == ignores it → equatable check uses only message.id+isMe.
    let onDismissSheet: (() -> Void)?

    // Phase 4: static formatters — DateFormatter and NSRegularExpression are
    // expensive to initialise (~0.5 ms each). Previously created per-bubble per
    // render; with 30 messages and frequent parent re-renders (every keystroke,
    // every SSE tick) this added up noticeably.
    // fileprivate (not private) so BuddyChatView.dateSeparator() — which lives in
    // the same file — can access dateSepFormatter without duplication.
    fileprivate static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.timeStyle = .short; return f
    }()
    fileprivate static let dateSepFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_PE")
        f.dateFormat = "EEEE · H:mm"
        return f
    }()
    private static let urlRegex: NSRegularExpression? =
        try? NSRegularExpression(pattern: #"https?://[^\s]+"#, options: .caseInsensitive)

    // ── Rendering audit (DEBUG only) ──────────────────────────────────────────
    // Tracks how many times each bubble's body is recomputed and when it first
    // appears (onAppear = virtualization check).
    // Check the console after opening a chat to see:
    //   🔵 [render] body eval — tells you which state change caused the re-render
    //   👁 [virtual] onAppear — tells you how many cells LazyVStack actually mounted
    // If onAppear fires for all N messages at once, LazyVStack is NOT virtualizing.
    // If it fires only for ~10–15 (the visible viewport), virtualization is correct.
    #if DEBUG
    fileprivate static var _bodyEvals = 0
    fileprivate static var _appears   = 0
    #endif

    var body: some View {
        #if DEBUG
        let _ = {
            BuddyMessageBubble._bodyEvals += 1
            // If you see this firing on every inputFocused/GPS update after the fix,
            // uncomment _printChanges() to see exactly which property changed:
            // Self._printChanges()
            print("🔵 [render] bubble body eval #\(BuddyMessageBubble._bodyEvals) id=\(message.id.prefix(6))")
        }()
        #endif

        let isAudio    = message.type == "audio" || message.type == "audio_message"
        let isImage    = message.type == "image" && message.imageUrl != nil
        let isLocation = message.content?.hasPrefix("location:") == true
        let isPlace    = message.content?.hasPrefix("place:") == true
        let isCategory = message.content?.hasPrefix("category_card:") == true

        let timeStr = message.createdAt.map { shortTime($0) }

        return HStack(spacing: 0) {
            if isMe { Spacer(minLength: 56) }

            VStack(alignment: isMe ? .trailing : .leading, spacing: 2) {
                if isAudio, let url = message.audioUrl {
                    AudioPlayerBubble(audioUrl: url, isMe: isMe, timeStr: timeStr)
                } else if isImage, let url = message.imageUrl {
                    // Image: time overlaid bottom-right inside image
                    ZStack(alignment: .bottomTrailing) {
                        imageBubble(url: url)
                        if let t = timeStr {
                            Text(t)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Color.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Color.black.opacity(0.35))
                                .clipShape(Capsule())
                                .padding(6)
                        }
                    }
                } else if isCategory, let content = message.content {
                    categoryCard(content: content, isMe: isMe)
                    // Cards keep time below (compact)
                    if let t = timeStr {
                        Text(t).font(.system(size: 10)).foregroundStyle(Color.inkMuted).padding(.horizontal, 2)
                    }
                } else if isPlace, let content = message.content {
                    placeCard(content: content)
                    if let t = timeStr {
                        Text(t).font(.system(size: 10)).foregroundStyle(Color.inkMuted).padding(.horizontal, 2)
                    }
                } else if isLocation, let content = message.content {
                    locationCard(content: content)
                    if let t = timeStr {
                        Text(t).font(.system(size: 10)).foregroundStyle(Color.inkMuted).padding(.horizontal, 2)
                    }
                } else {
                    // Text bubble: time embedded inside, bottom-right
                    textBubble(timeStr: timeStr)
                }
            }

            if !isMe { Spacer(minLength: 56) }
        }
    }

    private func textBubble(timeStr: String?) -> some View {
        // Time is injected as a trailing zero-width spacer trick:
        // append invisible spacer = width of time label so the last text line
        // never overlaps the time.
        // +6 extra chars = ~4pt gap between last word and time label
        let timeSpacer = timeStr.map { String(repeating: " ", count: $0.count + 6) } ?? ""
        return ZStack(alignment: .bottomTrailing) {
            (Text(linkedText(message.content ?? ""))
                .font(BT.body)
                .foregroundStyle(isMe ? Color.white : Color.ink)
             + Text(timeSpacer).font(BT.body))
                .tint(isMe ? Color.white.opacity(0.85) : Color.teal)
                .environment(\.openURL, OpenURLAction { url in
                    UIApplication.shared.open(url)
                    return .handled
                })
                .fixedSize(horizontal: false, vertical: true)

            if let t = timeStr {
                Text(t)
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(isMe ? Color.white.opacity(0.65) : Color.inkMuted)
                    .padding(.bottom, 1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(isMe ? Color.teal : Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(isMe ? Color.clear : Color.border, lineWidth: 1)
        )
    }

    private func imageBubble(url: String) -> some View {
        CachedImage(urlString: url) { img in
            img.resizable().scaledToFill()
        } placeholder: {
            ZStack {
                RoundedRectangle(cornerRadius: 16).fill(Color.groupedBg)
                ProgressView().tint(Color.inkMuted)
            }
        }
        .frame(width: 220, height: 220)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func categoryCard(content: String, isMe: Bool = false) -> some View {
        let key = String(content.dropFirst("category_card:".count))
        let info: (icon: String, label: String, subtitle: String) = {
            switch key {
            case "transport":     return ("map.fill",            "Cómo llegar",   "Rutas y transporte")
            case "food":          return ("cup.and.saucer.fill", "Comer",          "Comida y restaurantes")
            case "translation":   return ("bubble.left.fill",    "Traducir",       "Frases, señales y más")
            case "activities":    return ("sparkles",            "Qué hacer",      "Tours y actividades")
            case "accommodation": return ("bed.double.fill",     "Alojamiento",    "Hoteles, hostales y más")
            case "emergency":     return ("shield.fill",         "Seguridad",      "Emergencias y consejos")
            default:              return ("questionmark",        key,              "Solicitud de ayuda")
            }
        }()
        return HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.brand.opacity(0.12))
                    .frame(width: 42, height: 42)
                Image(systemName: info.icon)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Color.brand)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(isMe ? "Necesito ayuda con" : "Necesita ayuda con")
                    .font(BT.caption1)
                    .foregroundStyle(Color.inkMuted)
                Text(info.label)
                    .font(BT.footnoteBold)
                    .foregroundStyle(Color.ink)
                Text(info.subtitle)
                    .font(BT.caption1)
                    .foregroundStyle(Color.inkMuted)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.border, lineWidth: 1))
        .frame(maxWidth: 260, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(isMe ? "Pedí ayuda con" : "Pide ayuda con") \(info.label): \(info.subtitle)")
    }

    private func placeCard(content: String) -> some View {
        let raw   = content.dropFirst("place:".count)
        let parts = raw.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false)
        let lat   = Double(parts.count > 0 ? parts[0] : "") ?? 0
        let lng   = Double(parts.count > 1 ? parts[1] : "") ?? 0
        let name  = parts.count > 2 ? String(parts[2]) : "Lugar"
        let addr  = parts.count > 3 ? String(parts[3]) : ""

        return Button {
            AppRouter.shared.openPlace(lat: lat, lng: lng, name: name)
            onDismissSheet?()
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.teal.opacity(0.12))
                        .frame(width: 42, height: 42)
                    Image(systemName: "mappin.circle.fill")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(Color.teal)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Locación sugerida")
                        .font(BT.caption1)
                        .foregroundStyle(Color.inkMuted)
                    Text(name)
                        .font(BT.footnoteBold)
                        .foregroundStyle(Color.ink)
                        .lineLimit(2)
                    Text("Ver en el mapa")
                        .font(BT.caption1)
                        .foregroundStyle(Color.teal)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.inkMuted)
            }
            .padding(14)
            .background(Color.surface)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.border, lineWidth: 1))
            .frame(maxWidth: 260, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Locación sugerida: \(name)")
        .accessibilityHint("Abre en Maps")
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
        .accessibilityLabel("Ubicación compartida")
        .accessibilityHint("Abre en Maps")
    }

    private func linkedText(_ raw: String) -> AttributedString {
        var attr = AttributedString(raw)
        let nsRaw = raw as NSString
        BuddyMessageBubble.urlRegex?.enumerateMatches(
            in: raw, range: NSRange(location: 0, length: nsRaw.length)
        ) { match, _, _ in
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
        BuddyMessageBubble.timeFormatter.string(from: d)
    }
}

// Equatable conformance for .equatable() — SwiftUI skips body re-evaluation
// when the parent re-renders but the bubble's message content hasn't changed.
// Messages are immutable once sent: same id → same content, same isMe → same layout.
// onDismissSheet is intentionally excluded: it's a new closure each parent render
// but DismissAction (its source) is stable for the sheet lifetime. Excluding it
// keeps == returning true so body stays blocked on every parent re-render.
extension BuddyMessageBubble: Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.message.id == rhs.message.id && lhs.isMe == rhs.isMe
    }
}

// MARK: – MessageBubble alias (for legacy use)
typealias MessageBubble = BuddyMessageBubble

// MARK: – Audio Recorder Service

@MainActor
final class AudioRecorderVM: NSObject, ObservableObject, AVAudioRecorderDelegate {
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
        let permOk = await requestPermission()
        print("🎙️ [recVM] start() — permission=\(permOk)")
        guard permOk else { return false }
        let session = AVAudioSession.sharedInstance()
        let currentCategory = session.category
        let currentMode = session.mode
        print("🎙️ [recVM] AVAudioSession before setCategory — category=\(currentCategory.rawValue) mode=\(currentMode.rawValue)")
        do {
            // .mixWithOthers prevents the session from interrupting the system audio
            // (keyboard click sounds etc.) which would otherwise resign the TextField's
            // first-responder and collapse the input bar mid-gesture.
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .mixWithOthers])
            try session.setActive(true)
            print("🎙️ [recVM] AVAudioSession activated ✓")
        } catch {
            print("🎙️ [recVM] AVAudioSession error: \(error)")
        }

        // Listen for interruptions (phone call, etc.)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleInterruption),
            name: AVAudioSession.interruptionNotification, object: session
        )

        let dir = FileManager.default.temporaryDirectory
        fileURL = dir.appendingPathComponent("audio_\(Date().timeIntervalSince1970).m4a")

        let settings: [String: Any] = [
            AVFormatIDKey:             Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey:           44100,
            AVNumberOfChannelsKey:     1,
            AVEncoderAudioQualityKey:  AVAudioQuality.high.rawValue
        ]
        guard let url = fileURL,
              let rec = try? AVAudioRecorder(url: url, settings: settings) else {
            print("🎙️ [recVM] AVAudioRecorder init failed — url=\(fileURL?.lastPathComponent ?? "nil")")
            return false
        }
        recorder = rec
        recorder?.delegate = self
        let started = rec.record()
        print("🎙️ [recVM] rec.record() → \(started)")
        isRecording = true; seconds = 0; cancelled = false

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.seconds += 1 }
        }
        return true
    }

    func stop() -> URL? {
        print("🎙️ [recVM] stop() — isRecording=\(isRecording) cancelled=\(cancelled) secs=\(seconds)")
        NotificationCenter.default.removeObserver(self, name: AVAudioSession.interruptionNotification, object: nil)
        timer?.invalidate(); timer = nil
        recorder?.stop(); recorder = nil
        isRecording = false
        let result = cancelled ? nil : fileURL
        print("🎙️ [recVM] stop() → returning \(result?.lastPathComponent ?? "nil (cancelled)")")
        return result
    }

    func cancel() {
        print("🎙️ [recVM] cancel() — isRecording=\(isRecording) secs=\(seconds)")
        guard isRecording || recorder != nil else {
            print("🎙️ [recVM] cancel() — already stopped, ignoring")
            return
        }
        NotificationCenter.default.removeObserver(self, name: AVAudioSession.interruptionNotification, object: nil)
        cancelled = true
        timer?.invalidate(); timer = nil
        recorder?.stop(); recorder = nil
        if let url = fileURL { try? FileManager.default.removeItem(at: url) }
        fileURL = nil
        isRecording = false
    }

    // Interruption (phone call, siri, background) → cancel cleanly
    @objc private func handleInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        print("🎙️ [recVM] AVAudioSession interruption — type=\(type == .began ? "began" : "ended") isRecording=\(isRecording)")
        guard type == .began else { return }
        Task { @MainActor in self.cancel() }
    }

    // AVAudioRecorderDelegate: recording stopped externally
    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        print("🎙️ [recVM] audioRecorderDidFinishRecording — success=\(flag) isRecording=\(isRecording)")
        if !flag { Task { @MainActor in self.cancel() } }
    }

    // Upload to buddy-core storage proxy (multipart)
    // El endpoint /audio ya crea el registro en DB y devuelve el APIMessage completo
    func upload(fileURL: URL, matchId: String, clientMessageId: String) async throws -> APIMessage {
        isUploading = true
        defer { isUploading = false }

        let endpoint = "\(APIClient.shared.baseURL)/messages/\(matchId)/audio"
        guard let url = URL(string: endpoint) else { throw URLError(.badURL) }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        let boundary = "Boundary-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let token = Session.token {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let audioData = try Data(contentsOf: fileURL)
        var body = Data()
        // client_message_id enables deterministic storage path on the backend.
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"client_message_id\"\r\n\r\n".data(using: .utf8)!)
        body.append(clientMessageId.data(using: .utf8)!)
        body.append("\r\n".data(using: .utf8)!)
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
    @Published var isPlaying  = false
    @Published var progress   = 0.0
    @Published var duration   = 0.0
    /// true only while the AVAsset duration is being resolved after the first tap.
    /// Starts false so the bubble renders immediately without a spinner on appear.
    @Published var isLoading  = false
    @Published var hasError   = false

    // Nil until the user first taps play. This is the lazy-load sentinel —
    // no AVPlayer, AVAudioSession, or time observers exist before that point.
    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?

    // MARK: – Public API

    /// Call this from the play button. On first call it loads the AVPlayer and
    /// starts playback automatically. On subsequent calls it toggles play/pause.
    func play(urlString: String) {
        if player == nil {
            loadAndPlay(urlString: urlString)
        } else {
            togglePlay()
        }
    }

    func seek(to ratio: Double) {
        guard let player, duration > 0 else { return }
        player.seek(to: CMTime(seconds: ratio * duration, preferredTimescale: 600))
        progress = ratio
    }

    // MARK: – Private

    private func loadAndPlay(urlString: String) {
        guard !isLoading else { return }
        guard let url = URL(string: urlString) else { hasError = true; return }

        isLoading = true
        let item = AVPlayerItem(url: url)
        let p    = AVPlayer(playerItem: item)
        player   = p

        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)

        // Resolve duration, then start playback
        Task {
            do {
                let dur = try await item.asset.load(.duration)
                if dur.isValid && !dur.isIndefinite { duration = CMTimeGetSeconds(dur) }
                isLoading = false
                p.play()
                isPlaying = true
            } catch {
                isLoading = false
                hasError  = true
            }
        }

        // Time observer — 50 ms interval, only active while this instance is alive
        let interval = CMTime(seconds: 0.05, preferredTimescale: 600)
        timeObserver = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self, let dur = self.player?.currentItem?.duration,
                  dur.isValid, !dur.isIndefinite else { return }
            let total = CMTimeGetSeconds(dur)
            if self.duration == 0 { self.duration = total }
            self.progress = total > 0 ? CMTimeGetSeconds(time) / total : 0
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            self?.isPlaying = false
            self?.progress  = 0
            self?.player?.seek(to: .zero)
        }
    }

    private func togglePlay() {
        guard let player else { return }
        isPlaying ? player.pause() : player.play()
        isPlaying.toggle()
    }

    deinit {
        if let obs = timeObserver { player?.removeTimeObserver(obs) }
        if let obs = endObserver  { NotificationCenter.default.removeObserver(obs) }
    }
}

// Waveform pattern — 26 bars, reduced from 30 for a cleaner look
private let waveHeights: [CGFloat] = [4,7,12,6,14,9,17,11,6,13,9,16,5,11,8,13,6,14,8,11,5,9,15,7,11,6]

struct AudioPlayerBubble: View {
    let audioUrl: String
    let isMe: Bool
    var timeStr: String? = nil

    @StateObject private var vm = AudioPlayerVM()

    // Color aliases
    private var bubbleBg:   Color { isMe ? Color.teal  : Color.surface }
    private var playFg:     Color { isMe ? Color.teal  : Color.white }
    private var playBg:     Color { isMe ? Color.white : Color.ink }
    private var waveActive: Color { isMe ? Color.white : Color.teal }
    private var waveIdle:   Color { isMe ? Color.white.opacity(0.3) : Color.inkMuted.opacity(0.25) }
    private var metaFg:     Color { isMe ? Color.white.opacity(0.6) : Color.inkMuted }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {

            // ── Play / Pause / Loading / Error — circular button ────
            // vm.play() loads the AVPlayer lazily on first tap (Phase 3):
            // no AVPlayer/AVAudioSession/timer is created until the user taps here.
            Button { vm.play(urlString: audioUrl) } label: {
                ZStack {
                    Circle().fill(playBg).frame(width: 36, height: 36)
                    if vm.isLoading {
                        ProgressView()
                            .tint(playFg)
                            .scaleEffect(0.65)
                    } else if vm.hasError {
                        Image(systemName: "exclamationmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(playFg)
                    } else {
                        Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(playFg)
                            .offset(x: vm.isPlaying ? 0 : 1)
                    }
                }
            }
            .disabled(vm.hasError)
            .animation(.easeInOut(duration: 0.15), value: vm.isPlaying)
            .animation(.easeInOut(duration: 0.15), value: vm.isLoading)

            // ── Waveform + meta row ─────────────────────────────────
            VStack(alignment: .leading, spacing: 5) {

                // Waveform — fills available width via GeometryReader
                GeometryReader { geo in
                    let barCount   = waveHeights.count
                    let barGap: CGFloat = 2
                    let barW = (geo.size.width - CGFloat(barCount - 1) * barGap) / CGFloat(barCount)
                    let totalW = geo.size.width

                    ZStack(alignment: .leading) {
                        HStack(alignment: .center, spacing: barGap) {
                            ForEach(0..<barCount, id: \.self) { i in
                                let passed = Double(i) / Double(barCount) < vm.progress
                                Capsule()
                                    .fill(passed ? waveActive : waveIdle)
                                    .frame(width: max(barW, 1.5), height: waveHeights[i])
                                    .animation(.easeOut(duration: 0.08), value: vm.progress)
                            }
                        }
                        // Scrub dot
                        Circle()
                            .fill(waveActive)
                            .frame(width: 10, height: 10)
                            .shadow(color: waveActive.opacity(0.35), radius: 2)
                            .offset(x: max(0, min(totalW * vm.progress - 5, totalW - 10)))
                            .animation(.easeOut(duration: 0.08), value: vm.progress)
                    }
                    .frame(width: totalW, height: 20)
                    .contentShape(Rectangle())
                    // simultaneousGesture lets the parent ScrollView receive the touch in
                    // parallel — it does NOT block vertical scroll. The directional guard
                    // ignores gestures that are more vertical than horizontal so the user
                    // can scroll the chat even when starting the drag over the waveform.
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .local)
                            .onChanged { v in
                                guard abs(v.translation.width) > abs(v.translation.height) else { return }
                                vm.seek(to: max(0, min(1, v.location.x / totalW)))
                            }
                    )
                }
                .frame(height: 20)

                // Duration (left) · message time (right)
                HStack(spacing: 0) {
                    Text(vm.isLoading ? "—:——" : fmt(vm.isPlaying ? vm.progress * vm.duration : vm.duration))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(metaFg)
                    if let t = timeStr {
                        Spacer(minLength: 8)
                        Text(t)
                            .font(.system(size: 10, weight: .regular))
                            .foregroundStyle(metaFg)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(bubbleBg)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .frame(minWidth: 180, maxWidth: 260)
        // Phase 3: no .task here — AVPlayer is created lazily on first tap.
    }

    private func fmt(_ s: Double) -> String {
        guard s.isFinite, s > 0 else { return "0:00" }
        let t = Int(s); return "\(t/60):\(String(format: "%02d", t%60))"
    }
}

// MARK: – Keyboard Pre-warmer
// Pays the iOS keyboard subsystem lazy-init cost (300–800ms on first becomeFirstResponder
// in a process lifetime) during the chat's own appear transition — when the user is
// already reading messages and has not yet tapped the text field.
//
// Design rationale (measured 2026-06-30):
//   tap→willShow on cold process (simulator) ≈ 116ms → scales to ~400–800ms on device.
//   Prewarming here hides that cost inside the ~1s chat-open transition, so the first
//   tap feels instant without affecting any other screen.
//
// Why inputView = UIView() instead of alpha = 0:
//   alpha = 0 hides the UITextField but NOT the system keyboard window (a separate
//   UIWindow managed by UIKit). inputView = UIView() replaces the keyboard UI with a
//   zero-size empty view — UIKit still initialises the text input service (paying the
//   init cost) but shows nothing to the user.
//
// Why here, not InicioView:
//   InicioView has no knowledge of whether the user will open a chat. Putting keyboard
//   init in the Home screen breaks architectural separation of concerns. BuddyChatView
//   knows a text field is imminent — it is the right owner of this responsibility.
struct KeyboardPrewarmer: UIViewRepresentable {
    // Once per process is enough — subsequent calls cost < 1ms (keyboard already ready).
    private static var hasWarmed = false

    func makeUIView(context: Context) -> UITextField {
        let tf = UITextField()
        tf.inputView = UIView()   // replaces keyboard window with empty UIView (0 px, invisible)
        guard !KeyboardPrewarmer.hasWarmed else {
            print("⌨️ [prewarmer] already warmed — skipping")
            return tf
        }
        KeyboardPrewarmer.hasWarmed = true
        // Delay 0: BuddyChatView just appeared — user is reading messages, not yet typing.
        // No need to defer further; the text-input service init runs in the background.
        DispatchQueue.main.async {
            let ok = tf.becomeFirstResponder()
            print("⌨️ [prewarmer] becomeFirstResponder → \(ok) (inputView=UIView, zero visual artifact)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                tf.resignFirstResponder()
                print("⌨️ [prewarmer] done — keyboard subsystem ready for first tap")
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
                ToolbarItem(placement: .cancellationAction) {
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

// MARK: – PLACE PICKER SHEET

struct PlacePickerSheet: View {
    var destinationId: String? = nil
    let onSelect: (String, Double, Double) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var places: [APIPlace] = []
    @State private var filtered: [APIPlace] = []
    @State private var query = ""
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Search bar
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(Color.inkMuted)
                    TextField("Filtrar lugares...", text: $query)
                        .autocorrectionDisabled()
                }
                .padding(12)
                .background(Color.groupedBg)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, Spacing.edge)
                .padding(.vertical, Spacing.md)

                if isLoading {
                    Spacer()
                    ProgressView()
                    Spacer()
                } else if filtered.isEmpty {
                    Spacer()
                    Text(query.isEmpty ? "Sin lugares para este destino" : "Sin resultados")
                        .font(BT.callout)
                        .foregroundStyle(Color.inkMuted)
                    Spacer()
                } else {
                    List(filtered) { place in
                        Button {
                            onSelect(place.name, place.lat, place.lng)
                        } label: {
                            HStack(spacing: 12) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color.teal.opacity(0.10))
                                        .frame(width: 36, height: 36)
                                    Image(systemName: place.placeCategory?.icon ?? "mappin.fill")
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundStyle(Color.teal)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(place.name)
                                        .font(BT.footnoteBold)
                                        .foregroundStyle(Color.ink)
                                    if let type = place.placeCategory?.name ?? place.placeType {
                                        Text(type)
                                            .font(BT.caption1)
                                            .foregroundStyle(Color.inkMuted)
                                    }
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Color.border)
                            }
                            .padding(.vertical, 4)
                        }
                        .listRowBackground(Color.surface)
                    }
                    .listStyle(.plain)
                }
            }
            .background(Color.canvas)
            .navigationTitle("Locaciones del trip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancelar") { dismiss() }
                        .foregroundStyle(Color.inkMuted)
                }
            }
            .task { await load() }
            .onChange(of: query) { _, val in
                let q = val.trimmingCharacters(in: .whitespaces).lowercased()
                filtered = q.isEmpty ? places : places.filter { $0.name.lowercased().contains(q) }
            }
        }
    }

    private func load() async {
        guard let destId = destinationId else { isLoading = false; return }
        let fetched = (try? await APIClient.shared.fetchPlaces(destinationId: destId)) ?? []
        places = fetched
        filtered = fetched
        isLoading = false
    }
}
