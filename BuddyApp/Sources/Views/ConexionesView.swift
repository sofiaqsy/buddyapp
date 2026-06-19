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

        var buddyName: String {
            match.buddy?.fullName?.components(separatedBy: " ").first?.capitalized ?? "Buddy"
        }
        var buddyAvatarUrl: String? { match.buddy?.avatarUrl }

        /// El buddy respondió y el viajero aún no ha contestado
        var pendingReply: Bool {
            guard let last = lastMessage, let userId = AuthService.shared.userId else { return false }
            return last.senderId != userId
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
    @Published var totalUnread: Int = 0
    @Published var isLoading = false
    /// true tras la primera carga (con o sin resultados) — el spinner de
    /// pantalla completa solo se muestra antes de este punto
    @Published var hasLoadedOnce = false

    func load() async {
        guard let userId = AuthService.shared.userId else {
            // Sin sesión todavía: no dejar el spinner colgado para siempre
            await MainActor.run { hasLoadedOnce = true }
            return
        }
        await MainActor.run { isLoading = true }
        do {
            let matches = try await APIClient.shared.fetchMatches(userId: userId)
            var items: [ConnectionItem] = []
            await withTaskGroup(of: ConnectionItem?.self) { group in
                for match in matches {
                    group.addTask {
                        let msgs = try? await APIClient.shared.fetchMessages(matchId: match.id)
                        let last = msgs?.last
                        let unread = msgs?.filter { $0.senderId != userId && $0.readAt == nil }.count ?? 0
                        return ConnectionItem(match: match, lastMessage: last, unreadCount: unread)
                    }
                }
                for await item in group { if let item { items.append(item) } }
            }
            items.sort {
                let aActive = ["accepted","active"].contains($0.match.status)
                let bActive = ["accepted","active"].contains($1.match.status)
                if aActive != bActive { return aActive }
                let aDate = $0.lastMessage?.createdAt ?? $0.match.createdAt ?? .distantPast
                let bDate = $1.lastMessage?.createdAt ?? $1.match.createdAt ?? .distantPast
                return aDate > bDate
            }
            await MainActor.run {
                connections = items
                // Solo contar no leídos de matches activos (no de encuentros pasados)
                // Badge = conexiones activas donde el viajero espera respuesta del buddy
                totalUnread = items
                    .filter { ["accepted", "active"].contains($0.match.status) && $0.pendingReply }
                    .count
                isLoading = false
                hasLoadedOnce = true
            }
        } catch {
            await MainActor.run { isLoading = false; hasLoadedOnce = true }
            // Cancelación de SwiftUI no es un fallo real
            if (error as? URLError)?.code != .cancelled && !(error is CancellationError) {
                print("❌ ChatStore.load: \(error)")
            }
        }
    }
}

// MARK: – CONEXIONES VIEW

struct ConexionesView: View {
    @EnvironmentObject var chatStore: ChatStore
    @State private var chatTarget: ChatStore.ConnectionItem? = nil

    private var active: [ChatStore.ConnectionItem] {
        chatStore.connections.filter { ["accepted","active"].contains($0.match.status) }
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
                    // Spinner SOLO antes de la primera carga — después, vacío
                    // significa empty state y las recargas son silenciosas
                    if !chatStore.hasLoadedOnce && chatStore.connections.isEmpty {
                        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if chatStore.connections.isEmpty {
                        emptyState
                    } else {
                        connectionList
                    }
                }
            }
            .navigationBarHidden(true)
            .background(Color.canvas)
        }
        .task { await chatStore.load() }
        .sheet(item: $chatTarget, onDismiss: { Task { await chatStore.load() } }) { item in
            if let journey = SyntheticJourney.make(for: item.match) {
                BuddyChatView(match: item.match, journey: journey) {
                    chatTarget = nil
                }
            }
        }
    }

    private var connectionList: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                // VÍNCULO ABIERTO — la persona que te ayuda ahora: tarjeta cálida y viva
                if !active.isEmpty {
                    listHeader("VÍNCULO ABIERTO", count: active.count > 1 ? active.count : 0, color: Color.teal)
                        .padding(.horizontal, Spacing.edge)
                        .padding(.top, Spacing.lg).padding(.bottom, Spacing.sm)

                    VStack(spacing: Spacing.md) {
                        ForEach(active) { item in
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

                HStack(alignment: .center) {
                    Text(item.lastText)
                        .font(BT.footnote)
                        .foregroundStyle(Color.inkMuted)
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
