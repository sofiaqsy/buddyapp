import SwiftUI
import CoreLocation

// MARK: – APP TAB

enum AppTab: Int, CaseIterable {
    case inicio, trips, conexiones, yo

    var icon: String {
        switch self {
        case .inicio:     return "house"
        case .trips:      return "map"
        case .conexiones: return "person.2"
        case .yo:         return "person.crop.circle"
        }
    }
    var activeIcon: String {
        switch self {
        case .inicio:     return "house.fill"
        case .trips:      return "map.fill"
        case .conexiones: return "person.2.fill"
        case .yo:         return "person.crop.circle.fill"
        }
    }
    var label: String {
        switch self {
        case .inicio:     return "Inicio"
        case .trips:      return "Tu trip"
        case .conexiones: return "Conexiones"
        case .yo:         return "Yo"
        }
    }
}

// MARK: – ROOT VIEW

struct RootView: View {
    @EnvironmentObject var locationService: LocationService
    @EnvironmentObject var routeStore: RouteStore
    @EnvironmentObject var authState: AuthState
    @EnvironmentObject var router: AppRouter
    @StateObject private var chatStore = ChatStore.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack(alignment: .bottom) {
            // Tab content — keep all views alive to preserve scroll/nav state
            TabView(selection: $router.selectedTab) {
                InicioView().tag(AppTab.inicio)
                TripsView().tag(AppTab.trips)
                ConexionesView().environmentObject(chatStore).tag(AppTab.conexiones)
                YoView().environmentObject(authState).environmentObject(routeStore).tag(AppTab.yo)
            }
            .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 70) }

            // Custom Liquid Glass tab bar
            GlassTabBar(selection: $router.selectedTab, unreadChats: chatStore.totalUnread)
        }
        .ignoresSafeArea(edges: .bottom)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                // Solo carga y stream si hay sesión activa
                if authState.isLoggedIn {
                    Task { await chatStore.load() }
                    chatStore.startEventStream()
                }
            } else if phase == .background {
                chatStore.stopEventStream()
            }
        }
        // Cuando el usuario se autentica: arrancar SSE + pedir push
        .onChange(of: authState.isLoggedIn) { _, loggedIn in
            if loggedIn {
                Task { await chatStore.load() }
                chatStore.startEventStream()
                // Pedir permiso de push la primera vez que el usuario se autentica
                UIApplication.shared.connectedScenes
                    .compactMap { $0 as? UIWindowScene }
                    .first?.windows.first.map { _ in }
                // Delegamos a appDelegate a través de BuddyAppApp — evita referencia circular
                NotificationCenter.default.post(name: .requestPushPermission, object: nil)
            } else {
                // Logout: limpiar estado de chat
                chatStore.stopEventStream()
                Task { await chatStore.clearAfterLogout() }
            }
        }
        .modifier(RootViewEvents(
            chatStore: chatStore,
            locationService: locationService,
            routeStore: routeStore,
            authState: authState,
            router: router
        ))
    }
}

// Extraído para aliviar el type-checker de SwiftUI con la cadena de modificadores.
private struct RootViewEvents: ViewModifier {
    let chatStore: ChatStore
    let locationService: LocationService
    let routeStore: RouteStore
    let authState: AuthState
    let router: AppRouter

    func body(content: Content) -> some View {
        content
            .onChange(of: router.selectedTab) { _, tab in
                if tab == .conexiones, authState.isLoggedIn {
                    Task { await chatStore.load() }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .helpOfferReceived)) { _ in
                if authState.isLoggedIn { Task { await chatStore.load() } }
            }
            .onAppear {
                if authState.isLoggedIn { chatStore.startEventStream() }
                locationService.requestPermission()
                locationService.onRegionEnter = { id in
                    guard let uuid = UUID(uuidString: id) else { return }
                    DispatchQueue.main.async {
                        routeStore.collect(placeId: uuid)
                        Haptic.success()
                    }
                }
            }
            .onChange(of: locationService.userLocation) { _, loc in
                guard let coord = loc.map({ $0.coordinate }) else { return }
                routeStore.buildRouteIfNeeded(near: coord)
                locationService.startMonitoring(places: routeStore.route.places)
            }
            .onChange(of: locationService.authorizationStatus) { _, status in
                if status == CLAuthorizationStatus.authorizedWhenInUse
                    || status == CLAuthorizationStatus.authorizedAlways {
                    locationService.startTracking()
                }
            }
            .overlay {
                if let place = routeStore.unlockedPlace {
                    StickerUnlockSheet(place: place) { routeStore.dismissUnlock() }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .animation(.spring(response: 0.45, dampingFraction: 0.8),
                                   value: routeStore.unlockedPlace?.id)
                        .zIndex(999)
                        .ignoresSafeArea()
                }
            }
            .sheet(item: Binding(
                get: { chatStore.pendingFeedbackMatch },
                set: { chatStore.pendingFeedbackMatch = $0 }
            )) { m in
                let name = m.buddy?.fullName?.components(separatedBy: " ").first?.lowercased() ?? "tu buddy"
                CloseFeedbackSheet(buddyName: name, buddyAvatarUrl: m.buddy?.avatarUrl, isMandatory: true) { feeling, pressure in
                    Task {
                        try? await APIClient.shared.submitFeedback(matchId: m.id, feeling: feeling, commercialPressure: pressure)
                        FeedbackTracker.markSubmitted(m.id)
                        await MainActor.run { chatStore.pendingFeedbackMatch = nil }
                    }
                } onDismiss: { }
            }
    }
}

// MARK: – GLASS TAB BAR
// Full-width Liquid Glass surface. Active tab: teal filled icon + label.
// Inactive: muted icon, no label — keeps the bar quiet.

struct GlassTabBar: View {
    @Binding var selection: AppTab
    var unreadChats: Int = 0

    private var bottomInset: CGFloat {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?
            .windows.first?.safeAreaInsets.bottom ?? 0
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases, id: \.rawValue) { tab in
                let active = selection == tab
                let badge  = tab == .conexiones ? unreadChats : 0

                Button {
                    if selection == tab {
                        // Re-tap del tab activo → recargar / volver arriba
                        Haptic.light()
                        NotificationCenter.default.post(name: .tabReselected, object: tab.rawValue)
                        return
                    }
                    Haptic.select()
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.72)) {
                        selection = tab
                    }
                } label: {
                    VStack(spacing: 4) {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: active ? tab.activeIcon : tab.icon)
                                .font(.system(size: 20, weight: active ? .semibold : .regular))
                                .foregroundStyle(active ? Color.brand : Color.tabBarInactive)
                                .scaleEffect(active ? 1.05 : 1)
                                .animation(.spring(response: 0.3, dampingFraction: 0.65), value: active)
                                .padding(.trailing, badge > 0 ? 10 : 0)

                            if badge > 0 {
                                Text("\(min(badge, 99))")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, badge > 9 ? 4 : 0)
                                    .frame(minWidth: 17, minHeight: 17)
                                    .background(Color.errorRed)
                                    .clipShape(Capsule())
                                    .offset(x: 8, y: -5)
                            }
                        }

                        Text(tab.label)
                            .font(BT.caption2)
                            .foregroundStyle(active ? Color.teal : Color.inkMuted)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
                    .padding(.bottom, bottomInset + 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(tab.label)
                .accessibilityValue(badge > 0 ? "\(badge) sin leer" : "")
                .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
            }
        }
        .glassTabBar()
    }
}
