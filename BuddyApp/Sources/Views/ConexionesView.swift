import SwiftUI

// MARK: – CHAT STORE
// Shared observable — loads matches+messages, exposes unread count for tab badge.

final class ChatStore: ObservableObject {
    static let shared = ChatStore()

    struct ConnectionItem: Identifiable {
        let match: APIMatch
        let lastMessage: APIMessage?
        let unreadCount: Int
        var id: String { match.id }

        // When the current user is the buddy, the "other person" is the traveler.
        // match.buddyId is a traveler_id — compare against Session.travelerId, not auth_user_id.
        var isBuddyRole: Bool {
            guard let travelerId = Session.travelerId else { return false }
            return match.buddyId == travelerId
        }

        var buddyName: String {
            if isBuddyRole {
                return match.traveler?.fullName?.components(separatedBy: " ").first?.capitalized ?? "Viajero"
            }
            return match.buddy?.fullName?.components(separatedBy: " ").first?.capitalized ?? "Buddy"
        }
        var buddyAvatarUrl: String? {
            isBuddyRole ? match.traveler?.avatarUrl : match.buddy?.avatarUrl
        }

        /// El buddy respondió y el viajero aún no ha contestado
        var pendingReply: Bool {
            guard let last = lastMessage, let travelerId = Session.travelerId else { return false }
            return last.senderId != travelerId
        }

        /// El último mensaje lo envié yo (para mostrar "Tú:" estilo WhatsApp)
        var isLastFromMe: Bool {
            guard let last = lastMessage, let travelerId = Session.travelerId else { return false }
            return last.senderId == travelerId
        }

        var lastText: String {
            guard let msg = lastMessage else { return "Nueva conexión" }
            switch msg.type {
            case "audio": return "Mensaje de voz"
            default:
                let content = msg.content ?? ""
                if content.hasPrefix("location:") { return "Ubicación actual" }
                if content.hasPrefix("place:") {
                    let parts = content.dropFirst("place:".count).split(separator: "|")
                    return parts.count > 2 ? "📍 \(parts[2])" : "Lugar compartido"
                }
                return content
            }
        }

        var lastTime: String {
            guard let date = lastMessage?.createdAt else { return "" }
            let cal = Calendar.current
            if cal.isDateInToday(date) {
                let f = DateFormatter(); f.timeStyle = .short; return f.string(from: date)
            } else if cal.isDateInYesterday(date) {
                return "Ayer"
            } else {
                let f = DateFormatter(); f.dateFormat = "d/M"; return f.string(from: date)
            }
        }
    }

    @Published var connections: [ConnectionItem] = []
    @Published var offers: [APIBuddyOffer] = []
    @Published var totalUnread: Int = 0
    @Published var isLoading = false
    /// Match cerrado por el buddy cuya encuesta el viajero aún no respondió.
    /// Presentado globalmente (cualquier tab) por RootView en tiempo real.
    @Published var pendingFeedbackMatch: APIMatch? = nil
    /// true tras la primera carga (con o sin resultados) — el spinner de
    /// pantalla completa solo se muestra antes de este punto
    @Published var hasLoadedOnce = false

    /// UN solo SSE multiplexado (offer + message + match) que vive mientras el
    /// usuario está logueado, en cualquier tab. Reemplaza los dos streams previos
    /// → 1 conexión por usuario en vez de 2, y el backend usa 1 canal Realtime
    /// global compartido para todos (escala a miles de conexiones).
    private var eventStreamTask: Task<Void, Never>? = nil

    func startEventStream() {
        stopEventStream()
        guard let url = URL(string: "\(APIClient.shared.baseURL)/stream") else { return }

        eventStreamTask = Task {
            var attempt = 0
            while !Task.isCancelled {
                // Token fresco en CADA intento — evita el bucle de 401 con un
                // token expirado en sesiones largas. Cubre guest y verified.
                guard let token = Session.token else {
                    try? await Task.sleep(nanoseconds: 3_000_000_000); continue
                }
                var request = URLRequest(url: url)
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                request.timeoutInterval = 600

                guard let (stream, response) = try? await URLSession.shared.bytes(for: request) else {
                    await backoff(&attempt)
                    continue
                }
                // 401 → token expirado: refrescar y reintentar sin contar como fallo.
                // Intenta Traveler JWT primero (cubre guests), luego Supabase.
                if let http = response as? HTTPURLResponse, http.statusCode == 401 {
                    if let tid = TravelerService.shared.travelerId {
                        _ = try? await TravelerService.shared.forceRefresh(travelerId: tid)
                    } else {
                        _ = await AuthService.shared.tryRefresh()
                    }
                    await backoff(&attempt)
                    continue
                }
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    await backoff(&attempt)
                    continue
                }

                // ── Reconexión exitosa: reconciliar estado ──
                // Cualquier evento perdido durante el gap se recupera con una
                // recarga completa (matches + inbox + ofertas).
                attempt = 0
                await load()

                var currentEvent = ""
                do {
                    for try await line in stream.lines {
                        guard !Task.isCancelled else { break }
                        if line.hasPrefix("event:") {
                            currentEvent = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                        } else if line.hasPrefix("data:") {
                            let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                            let obj = (json.data(using: .utf8)).flatMap {
                                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
                            }
                            switch currentEvent {
                            case "message":
                                // Refresca solo esa conversación (1 llamada, no N+1)
                                if let matchId = obj?["match_id"] as? String {
                                    await refreshOne(matchId: matchId)
                                }
                            case "match", "offer":
                                // Nueva conexión / cambio de oferta → recarga completa
                                await load()
                            default:
                                break
                            }
                        }
                    }
                } catch { }
                // Conexión cerrada → reintentar con backoff
                await backoff(&attempt)
            }
        }
    }

    /// Backoff exponencial con tope y jitter — evita thundering herd cuando un
    /// reinicio de dyno desconecta a todos los clientes a la vez.
    private func backoff(_ attempt: inout Int) async {
        guard !Task.isCancelled else { return }
        attempt += 1
        let capped = min(Double(attempt) * 2.0, 20.0)          // 2,4,6…20s tope
        let jitter = Double.random(in: 0...1.5)
        try? await Task.sleep(nanoseconds: UInt64((capped + jitter) * 1_000_000_000))
    }

    func stopEventStream() {
        eventStreamTask?.cancel()
        eventStreamTask = nil
    }

    /// Limpia el estado privado tras un logout. El contenido público (feed de destinos,
    /// comunidad) se gestiona en InicioView y no se ve afectado.
    @MainActor
    func clearAfterLogout() {
        connections         = []
        offers              = []
        totalUnread         = 0
        pendingFeedbackMatch = nil
        hasLoadedOnce       = false
    }

    func load() async {
        guard Session.hasSession else {
            // Sin sesión todavía: no dejar el spinner colgado para siempre
            await MainActor.run { hasLoadedOnce = true }
            return
        }
        let currentTravelerId = Session.travelerId
        await MainActor.run { isLoading = true }
        do {
            let matches = try await APIClient.shared.fetchMatches()
            var items: [ConnectionItem] = []
            await withTaskGroup(of: ConnectionItem?.self) { group in
                for match in matches {
                    group.addTask {
                        let msgs = try? await APIClient.shared.fetchMessages(matchId: match.id)
                        let last = msgs?.last
                        let unread = msgs?.filter { $0.senderId != currentTravelerId && $0.readAt == nil }.count ?? 0
                        return ConnectionItem(match: match, lastMessage: last, unreadCount: unread)
                    }
                }
                for await item in group { if let item { items.append(item) } }
            }
            items = Self.sorted(items)
            // Load buddy offers in parallel with matches
            let fetchedOffers = (try? await APIClient.shared.fetchMyOffers()) ?? []

            await MainActor.run {
                connections = items
                offers = fetchedOffers
                recomputeBadge()
                isLoading = false
                hasLoadedOnce = true
                // Encuesta pendiente: un apoyo donde YO era viajero quedó cerrado
                // y no lo he calificado. Se presenta globalmente en tiempo real.
                if pendingFeedbackMatch == nil,
                   let pending = items.first(where: {
                       $0.match.status == "completed" && !$0.isBuddyRole
                           && !($0.match.feedbackSubmitted ?? false)
                           && !FeedbackTracker.isSubmitted($0.match.id)
                   }) {
                    pendingFeedbackMatch = pending.match
                }
            }
        } catch {
            await MainActor.run { isLoading = false; hasLoadedOnce = true }
            // Cancelación de SwiftUI no es un fallo real
            if (error as? URLError)?.code != .cancelled && !(error is CancellationError) {
                print("❌ ChatStore.load: \(error)")
            }
        }
    }

    /// Refresca SOLO una conexión (1 llamada) en vez de recargar toda la lista.
    /// Es el camino caliente del chat en tiempo real — evita el storm N+1.
    func refreshOne(matchId: String) async {
        guard Session.hasSession else { return }
        let currentTravelerId = Session.travelerId
        // Si el match no está en la lista aún (conexión nueva) → carga completa
        guard connections.contains(where: { $0.match.id == matchId }) else {
            await load(); return
        }
        let msgs   = try? await APIClient.shared.fetchMessages(matchId: matchId)
        let last   = msgs?.last
        let unread = msgs?.filter { $0.senderId != currentTravelerId && $0.readAt == nil }.count ?? 0

        await MainActor.run {
            guard let idx = connections.firstIndex(where: { $0.match.id == matchId }) else { return }
            let old = connections[idx]
            connections[idx] = ConnectionItem(match: old.match, lastMessage: last, unreadCount: unread)
            connections = Self.sorted(connections)
            recomputeBadge()
        }
    }

    private static let activeStatuses = ["pending", "accepted", "active"]

    static func sorted(_ items: [ConnectionItem]) -> [ConnectionItem] {
        items.sorted {
            let aActive = activeStatuses.contains($0.match.status)
            let bActive = activeStatuses.contains($1.match.status)
            if aActive != bActive { return aActive }
            let aDate = $0.lastMessage?.createdAt ?? $0.match.createdAt ?? .distantPast
            let bDate = $1.lastMessage?.createdAt ?? $1.match.createdAt ?? .distantPast
            return aDate > bDate
        }
    }

    private func recomputeBadge() {
        totalUnread = connections
            .filter { Self.activeStatuses.contains($0.match.status) && $0.pendingReply }
            .count + offers.count
    }

    /// No leídos SOLO del rol viajero (me están ayudando). Para el botón
    /// "contactar a mi buddy" en Tu trip — no debe contar ofertas/chats donde
    /// YO soy el buddy ayudando a otros.
    var travelerUnread: Int {
        connections
            .filter { !$0.isBuddyRole && Self.activeStatuses.contains($0.match.status) && $0.pendingReply }
            .count
    }
}

// MARK: – CONEXIONES VIEW

struct ConexionesView: View {
    @EnvironmentObject var chatStore: ChatStore
    @EnvironmentObject var authState: AuthState
    @State private var chatTarget: ChatStore.ConnectionItem? = nil
    @State private var showIdentitySheet = false

    private var active: [ChatStore.ConnectionItem] {
        chatStore.connections.filter { ["pending","accepted","active"].contains($0.match.status) }
    }
    /// Activos donde YO soy el buddy (estoy ayudando) → Acompañamiento abierto
    private var activeAsBuddy: [ChatStore.ConnectionItem] {
        active.filter { $0.isBuddyRole }
    }
    /// Activos donde YO soy el viajero (me ayudan) → Vínculo abierto
    private var activeAsTraveler: [ChatStore.ConnectionItem] {
        active.filter { !$0.isBuddyRole }
    }
    private var past: [ChatStore.ConnectionItem] {
        chatStore.connections.filter { $0.match.status == "completed" }
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                // Header — misma voz que el tab Trips
                VStack(alignment: .leading, spacing: 4) {
                    Text("TU GENTE")
                        .font(BT.eyebrow)
                        .tracking(2)
                        .foregroundStyle(Color.inkMuted)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("Tus")
                            .font(BT.title1)
                            .foregroundStyle(Color.ink)
                        Text("conexiones.")
                            .font(BT.displayLarge)
                            .foregroundStyle(Color.sand)
                    }
                    Text("Las personas que estuvieron contigo cuando llegaste.")
                        .font(BT.subhead)
                        .foregroundStyle(Color.inkMuted)
                        .padding(.top, 2)
                }
                .padding(.horizontal, Spacing.edge)
                .padding(.top, Spacing.md)

                Group {
                    // ── Estado anónimo: el tab muestra una invitación, no está vacío ──
                    if !authState.isLoggedIn {
                        anonymousConnectionState
                    // Spinner SOLO antes de la primera carga — después, vacío
                    // significa empty state y las recargas son silenciosas
                    } else if !chatStore.hasLoadedOnce && chatStore.connections.isEmpty {
                        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if chatStore.connections.isEmpty && chatStore.offers.isEmpty {
                        emptyState
                    } else {
                        connectionList
                    }
                }
            }
            .navigationBarHidden(true)
            .background(Color.canvas)
        }
        .task { if authState.isLoggedIn { await chatStore.load() } }
        .onChange(of: authState.isLoggedIn) { _, loggedIn in
            if !loggedIn {
                chatTarget = nil
            } else {
                Task { await chatStore.load() }
            }
        }
        // Recarga ofertas en tiempo real cuando el matching elige a este buddy
        .onReceive(NotificationCenter.default.publisher(for: .helpOfferReceived)) { _ in
            Task {
                let fresh = (try? await APIClient.shared.fetchMyOffers()) ?? []
                await MainActor.run {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        chatStore.offers = fresh
                        chatStore.totalUnread = chatStore.connections
                            .filter { ["pending", "accepted", "active"].contains($0.match.status) && $0.pendingReply }
                            .count + fresh.count
                    }
                }
            }
        }
        .sheet(item: $chatTarget, onDismiss: { Task { await chatStore.load() } }) { item in
            if let journey = SyntheticJourney.make(for: item.match) {
                BuddyChatView(match: item.match, journey: journey) {
                    chatTarget = nil
                }
            }
        }
        .sheet(isPresented: $showIdentitySheet) {
            IdentitySheet(contextMessage: "Identifícate para ver tus conversaciones con buddies.") {
                Task { await chatStore.load() }
                chatStore.startEventStream()
            }
            .environmentObject(authState)
        }
    }

    // MARK: – Estado anónimo del tab Conexiones

    private var anonymousConnectionState: some View {
        VStack(spacing: Spacing.lg) {
            Spacer()
            Image(systemName: "person.2")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(Color.inkMuted.opacity(0.4))
            VStack(spacing: Spacing.sm) {
                Text("Tus conexiones te esperan")
                    .font(BT.title3)
                    .foregroundStyle(Color.ink)
                Text("Cuando hables con un buddy o alguien te pida ayuda,\naparecerá aquí.")
                    .font(BT.callout)
                    .foregroundStyle(Color.inkMuted)
                    .multilineTextAlignment(.center)
            }
            Button {
                Haptic.medium()
                showIdentitySheet = true
            } label: {
                Text("Identificarme")
                    .font(BT.footnoteBold)
                    .padding(.horizontal, Spacing.xl)
                    .padding(.vertical, 15)
                    .background(Color.ink)
                    .foregroundStyle(Color.inkInverse)
                    .clipShape(Capsule())
            }
            .buttonStyle(.pressable)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var connectionList: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                // ALGUIEN LLEGA — ofertas pendientes para buddies
                if !chatStore.offers.isEmpty {
                    listHeader("ALGUIEN LLEGA", count: chatStore.offers.count, color: Color(hex: "#B45309"))
                        .padding(.horizontal, Spacing.edge)
                        .padding(.top, Spacing.lg).padding(.bottom, Spacing.sm)

                    VStack(spacing: Spacing.sm) {
                        ForEach(chatStore.offers) { offer in
                            OfferCard(offer: offer, onAccepted: { match in
                                // Al aceptar → abrir el chat con el viajero
                                let item = ChatStore.ConnectionItem(match: match, lastMessage: nil, unreadCount: 0)
                                chatTarget = item
                            }) {
                                Task { await chatStore.load() }
                            }
                            .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                    .padding(.horizontal, Spacing.edge)
                }

                // ACOMPAÑAMIENTO ABIERTO — viajeros a los que YO ayudo ahora
                if !activeAsBuddy.isEmpty {
                    activeSection("ACOMPAÑAMIENTO ABIERTO", items: activeAsBuddy, color: Color(hex: "#2B8A7A"))
                }

                // VÍNCULO ABIERTO — la persona que ME ayuda ahora
                if !activeAsTraveler.isEmpty {
                    activeSection("VÍNCULO ABIERTO", items: activeAsTraveler, color: Color.teal)
                }

                // ENCUENTROS ANTERIORES — recuerdos: filas planas, quietas, sin cajas
                if !past.isEmpty {
                    listHeader("ENCUENTROS ANTERIORES", count: past.count, color: Color.inkMuted)
                        .padding(.horizontal, Spacing.edge)
                        .padding(.top, active.isEmpty ? Spacing.lg : Spacing.xl)
                        .padding(.bottom, Spacing.sm)

                    VStack(spacing: 0) {
                        ForEach(Array(past.enumerated()), id: \.element.id) { i, item in
                            if i > 0 {
                                Divider().padding(.leading, 76).padding(.trailing, Spacing.edge)
                            }
                            Button { chatTarget = item } label: {
                                ConnectionRow(item: item, isActive: false)
                                    .padding(.horizontal, Spacing.edge)
                                    .padding(.vertical, 12)
                            }
                            .buttonStyle(.pressable)
                        }
                    }
                }
            }
            .padding(.bottom, 100)
        }
        .background(Color.canvas)
        .refreshable { await chatStore.load() }
    }

    @ViewBuilder
    private func activeSection(_ title: String, items: [ChatStore.ConnectionItem], color: Color) -> some View {
        listHeader(title, count: items.count > 1 ? items.count : 0, color: color)
            .padding(.horizontal, Spacing.edge)
            .padding(.top, Spacing.lg).padding(.bottom, Spacing.sm)

        VStack(spacing: Spacing.md) {
            ForEach(items) { item in
                Button { chatTarget = item } label: {
                    ConnectionRow(item: item, isActive: true)
                        .padding(Spacing.md)
                        .background(Color.surface)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
                        .cardShadow()
                }
                .buttonStyle(.pressable)
            }
        }
        .padding(.horizontal, Spacing.edge)
    }

    @ViewBuilder
    private func listHeader(_ title: String, count: Int, color: Color) -> some View {
        HStack(spacing: 6) {
            Text(title).font(BT.eyebrow).tracking(1.5).foregroundStyle(color)
            if count > 0 {
                Text("· \(count)").font(BT.eyebrow).foregroundStyle(Color.inkMuted.opacity(0.7))
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "person.2")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Color.inkMuted.opacity(0.4))
            VStack(spacing: 4) {
                Text("Las conexiones nacen de un trip")
                    .font(BT.callout)
                    .foregroundStyle(Color.ink)
                Text("Cuando llegues a tu destino, un buddy te estará esperando.")
                    .font(BT.footnote)
                    .foregroundStyle(Color.inkMuted)
                    .multilineTextAlignment(.center)
            }
            Button {
                NotificationCenter.default.post(name: .switchToTab, object: nil,
                                                userInfo: ["tab": AppTab.trips.rawValue])
            } label: {
                Text("Crear mi trip")
                    .font(BT.footnoteBold)
                    .padding(.horizontal, Spacing.lg)
                    .padding(.vertical, 12)
                    .background(Color.ink)
                    .foregroundStyle(Color.inkInverse)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, Spacing.sm)
        }
        .padding(.horizontal, Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: – Offer Card (buddy recibe solicitud de un viajero)

struct OfferCard: View {
    let offer: APIBuddyOffer
    var onAccepted: (APIMatch) -> Void = { _ in }
    let onHandled: () -> Void

    @State private var isAccepting = false
    @State private var isDeclining = false

    private static let categoryLabels: [String: String] = [
        "transport": "Cómo llegar", "food": "Comer", "translation": "Traducir",
        "activities": "Qué hacer", "accommodation": "Alojamiento",
        "emergency": "Seguridad", "general": "Ayuda",
    ]

    private var travelerName: String {
        offer.helpRequest?.users?.fullName?.components(separatedBy: " ").first?.capitalized ?? "Viajero"
    }
    private var categoryLabel: String {
        let key = offer.helpRequest?.category ?? ""
        return Self.categoryLabels[key] ?? key.capitalized
    }
    private var destinationName: String { offer.helpRequest?.destination?.name ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header — traveler + context
            HStack(spacing: 10) {
                Circle()
                    .fill(Color(hex: "#FFF3E0"))
                    .frame(width: 44, height: 44)
                    .overlay(
                        Text(String(travelerName.prefix(1)))
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(Color(hex: "#B45309"))
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(travelerName)
                        .font(BT.headline).foregroundStyle(Color.ink)
                    HStack(spacing: 4) {
                        if !destinationName.isEmpty {
                            Text(destinationName)
                                .font(BT.caption1).foregroundStyle(Color.inkMuted)
                            Text("·")
                                .font(BT.caption1).foregroundStyle(Color.inkMuted)
                        }
                        Text(categoryLabel)
                            .font(BT.caption1).foregroundStyle(Color(hex: "#B45309"))
                    }
                }

                Spacer()

                if let arrival = offer.helpRequest?.arrivalAt {
                    Text(relativeArrival(arrival))
                        .font(BT.caption1).foregroundStyle(Color.inkMuted)
                }
            }
            .padding(Spacing.md)

            // Message if present
            if let desc = offer.helpRequest?.description, !desc.isEmpty {
                Text("\"\(desc)\"")
                    .font(BT.callout).foregroundStyle(Color.ink)
                    .lineLimit(2)
                    .padding(.horizontal, Spacing.md)
                    .padding(.bottom, Spacing.md)
            }

            Divider().padding(.horizontal, Spacing.md)

            // CTAs
            HStack(spacing: 8) {
                Button {
                    Task { await accept() }
                } label: {
                    Group {
                        if isAccepting {
                            ProgressView().tint(.white).controlSize(.small)
                        } else {
                            Text("Acompañar")
                                .font(BT.footnoteBold).foregroundStyle(.white)
                        }
                    }
                    .frame(maxWidth: .infinity).frame(height: 40)
                    .background(Color(hex: "#2B8A7A"))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .disabled(isAccepting || isDeclining)

                Button {
                    Task { await decline() }
                } label: {
                    Group {
                        if isDeclining {
                            ProgressView().tint(Color.inkMuted).controlSize(.small)
                        } else {
                            Text("Ahora no")
                                .font(BT.footnote).foregroundStyle(Color.inkMuted)
                        }
                    }
                    .frame(maxWidth: .infinity).frame(height: 40)
                    .background(Color.canvas)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(isAccepting || isDeclining)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, 12)
        }
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.lg)
                .stroke(Color(hex: "#B45309").opacity(0.35), lineWidth: 1)
        )
        .cardShadow()
    }

    private func accept() async {
        guard let requestId = offer.helpRequest?.id else { return }
        isAccepting = true
        do {
            let match = try await APIClient.shared.acceptRequest(requestId: requestId)
            Haptic.success()
            onAccepted(match)
            onHandled()
        } catch {
            Haptic.error()
        }
        isAccepting = false
    }

    private func decline() async {
        isDeclining = true
        do {
            try await APIClient.shared.declineBuddyOffer(requestId: offer.requestId)
            Haptic.light()
            onHandled()
        } catch {
            Haptic.error()
        }
        isDeclining = false
    }

    private func relativeArrival(_ date: Date) -> String {
        let days = Calendar.current.dateComponents([.day], from: Date(), to: date).day ?? 0
        switch days {
        case 0:  return "Llega hoy"
        case 1:  return "Llega mañana"
        default: return "En \(days) días"
        }
    }
}

// MARK: – Connection Row (WhatsApp style)

struct ConnectionRow: View {
    let item: ChatStore.ConnectionItem
    let isActive: Bool

    var body: some View {
        HStack(spacing: 12) {
            // Avatar con punto online
            ZStack(alignment: .bottomTrailing) {
                Circle()
                    .fill(Color.sandLight)
                    .frame(width: isActive ? 50 : 44, height: isActive ? 50 : 44)
                    .overlay {
                        if let urlStr = item.buddyAvatarUrl, let url = URL(string: urlStr) {
                            AsyncImage(url: url) { img in img.resizable().scaledToFill() }
                                placeholder: { Color.sandLight }
                                .clipShape(Circle())
                        } else {
                            Image(systemName: "person.fill")
                                .font(.system(size: isActive ? 20 : 17))
                                .foregroundStyle(Color.sand)
                        }
                    }
                if isActive {
                    Circle().fill(Color.onlineGreen)
                        .frame(width: 13, height: 13)
                        .overlay(Circle().stroke(Color.canvas, lineWidth: 2))
                        .offset(x: 1, y: 1)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.buddyName)
                        .font(isActive ? BT.headline : BT.callout)
                        .foregroundStyle(Color.ink)
                    Spacer()
                    Text(item.lastTime)
                        .font(BT.caption1)
                        .foregroundStyle(Color.inkMuted)
                }

                HStack(alignment: .center, spacing: 4) {
                    if item.lastMessage != nil && item.isLastFromMe {
                        // Mensaje propio → "Tú:" estilo WhatsApp
                        Text("Tú:")
                            .font(BT.footnote)
                            .foregroundStyle(Color.inkMuted.opacity(0.8))
                    }
                    Text(item.lastText)
                        .font(BT.footnote)
                        // Mensaje entrante sin leer → más oscuro y con peso
                        .foregroundStyle(item.unreadCount > 0 ? Color.ink : Color.inkMuted)
                        .fontWeight(item.unreadCount > 0 ? .medium : .regular)
                        .lineLimit(1)
                    Spacer()
                    if item.unreadCount > 0 {
                        Text("\(item.unreadCount)")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, item.unreadCount > 9 ? 6 : 0)
                            .frame(minWidth: 20, minHeight: 20)
                            .background(Color.red)
                            .clipShape(Capsule())
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.inkMuted.opacity(0.35))
                    }
                }
            }
        }
    }
}

// MARK: – Synthetic Journey
// BuddyChatView requiere APIJourney — construimos uno mínimo desde JSON.

enum SyntheticJourney {
    static func make(for match: APIMatch) -> APIJourney? {
        let json: [String: Any] = [
            "id": UUID().uuidString,
            "user_id": match.travelerId,
            "status": match.status
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let journey = try? JSONDecoder.buddy.decode(APIJourney.self, from: data)
        else { return nil }
        return journey
    }
}
