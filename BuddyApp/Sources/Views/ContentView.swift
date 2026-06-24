import SwiftUI

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
    @StateObject private var chatStore = ChatStore.shared
    @State private var selectedTab: AppTab = .inicio
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack(alignment: .bottom) {
            // Tab content — keep all views alive to preserve scroll/nav state
            TabView(selection: $selectedTab) {
                InicioView().tag(AppTab.inicio)
                TripsView().tag(AppTab.trips)
                ConexionesView().environmentObject(chatStore).tag(AppTab.conexiones)
                YoView().environmentObject(authState).environmentObject(routeStore).tag(AppTab.yo)
            }
            .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 70) }

            // Custom Liquid Glass tab bar
            GlassTabBar(selection: $selectedTab, unreadChats: chatStore.totalUnread)
        }
        .ignoresSafeArea(edges: .bottom)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await chatStore.load() }
                chatStore.startOffersSSE()
            } else if phase == .background {
                chatStore.stopOffersSSE()
            }
        }
        .onChange(of: selectedTab) { _, tab in
            if tab == .conexiones { Task { await chatStore.load() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .helpOfferReceived)) { _ in
            Task { await chatStore.load() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .switchToTab)) { note in
            if let raw = note.userInfo?["tab"] as? Int, let tab = AppTab(rawValue: raw) {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.72)) {
                    selectedTab = tab
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openPlaceInMap)) { note in
            if let lat  = note.userInfo?["lat"]  as? Double,
               let lng  = note.userInfo?["lng"]  as? Double,
               let name = note.userInfo?["name"] as? String {
                PlaceDeepLink.shared.pending = .init(lat: lat, lng: lng, name: name)
                withAnimation(.spring(response: 0.35, dampingFraction: 0.72)) {
                    selectedTab = .inicio
                }
            }
        }
        .onAppear {
            // Remove native tab bar — replaced by GlassTabBar
            UITabBar.appearance().isHidden = true

            // SSE global de ofertas → badge rojo en tiempo real en cualquier tab
            chatStore.startOffersSSE()

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
            guard let coord = loc?.coordinate else { return }
            routeStore.buildRouteIfNeeded(near: coord)
            locationService.startMonitoring(places: routeStore.route.places)
        }
        .onChange(of: locationService.authorizationStatus) { _, status in
            if status == .authorizedWhenInUse || status == .authorizedAlways {
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
                                .foregroundStyle(active ? Color.teal : Color.inkMuted)
                                .scaleEffect(active ? 1.05 : 1)
                                .animation(.spring(response: 0.3, dampingFraction: 0.65), value: active)
                                .padding(.trailing, badge > 0 ? 10 : 0)

                            if badge > 0 {
                                Text("\(min(badge, 99))")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, badge > 9 ? 4 : 0)
                                    .frame(minWidth: 17, minHeight: 17)
                                    .background(Color.red)
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
