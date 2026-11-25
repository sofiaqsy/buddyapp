import SwiftUI
import CoreLocation

// MARK: – APP TAB

enum AppTab: Int, CaseIterable {
    case inicio, trips, conexiones, yo

    // Iconos de la barra (19 Nov 2026): una sola familia SF Symbols que dice
    // la función de cada tab — descubrir, viajes, conversaciones, perfil.
    var icon: String {
        switch self {
        case .inicio:     return "safari"
        case .trips:      return "globe.americas"
        case .conexiones: return "bubble.left.and.bubble.right"
        case .yo:         return "person"
        }
    }
    var activeIcon: String {
        switch self {
        case .inicio:     return "safari.fill"
        case .trips:      return "globe.americas.fill"
        case .conexiones: return "bubble.left.and.bubble.right.fill"
        case .yo:         return "person.fill"
        }
    }
    var label: String {
        switch self {
        case .inicio:     return "Inicio"
        case .trips:      return "Comunidad"
        case .conexiones: return "Conexiones"
        case .yo:         return "Yo"
        }
    }
}

// MARK: – ROOT VIEW

struct RootView: View {
    /// Teclado abierto: la barra de pestañas se esconde (Keyla, 24 Nov 2026).
    @State private var keyboardVisible = false
    @EnvironmentObject var locationService: LocationService
    @EnvironmentObject var routeStore: RouteStore
    @EnvironmentObject var authState: AuthState
    @EnvironmentObject var router: AppRouter
    @StateObject private var chatStore = ChatStore.shared
    @ObservedObject private var accounts = AccountStore.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        // Barra FLOTANTE propia (aprobada por Keyla, 19 Nov 2026): cápsula
        // sobre el contenido. El TabView no pasa un safeAreaInset a sus
        // páginas, así que cada tab reserva el alto de la barra con
        // safeAreaPadding y el último elemento nunca queda tapado.
        TabView(selection: $router.selectedTab) {
            InicioView().floatingTabBarSpace().perfTabAppear("inicio").tag(AppTab.inicio)
            CommunityView().floatingTabBarSpace().perfTabAppear("comunidad").tag(AppTab.trips)
            ConexionesView().environmentObject(chatStore).floatingTabBarSpace().perfTabAppear("conexiones").tag(AppTab.conexiones)
            YoView().environmentObject(authState).environmentObject(routeStore).floatingTabBarSpace().perfTabAppear("yo").tag(AppTab.yo)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            GlassTabBar(selection: $router.selectedTab, unreadChats: chatStore.totalUnread)
                .padding(.horizontal, Spacing.edge)
                // Un poco más abajo, dentro de la zona del indicador de inicio
                // (Keyla, 19 Nov 2026); el indicador sigue visible debajo.
                .offset(y: 16)
                // Con el teclado abierto la barra se esconde: subía con el teclado
                // y quedaba cortada encima (Keyla, 24 Nov 2026).
                .opacity(keyboardVisible ? 0 : 1)
                .allowsHitTesting(!keyboardVisible)
                .animation(.easeOut(duration: 0.15), value: keyboardVisible)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardVisible = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardVisible = false }
        // Sesión de cuenta verificada expirada (p. ej. tras reinstalar): pedir
        // login con la misma cuenta en vez de seguir como guest nuevo.
        .sheet(isPresented: $authState.sessionNeedsReauth) {
            IdentitySheet(purpose: .reauth) {
                authState.sessionNeedsReauth = false
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                // Solo carga y stream si hay sesión activa
                if authState.isLoggedIn {
                    Task { await chatStore.load() }
                    chatStore.startEventStream()
                }
                // Volver al frente: reanudar el GPS si hay permiso.
                if locationService.authorizationStatus == .authorizedWhenInUse
                    || locationService.authorizationStatus == .authorizedAlways {
                    locationService.startTracking()
                }
            } else if phase == .background {
                chatStore.stopEventStream()
                // En background nadie mira el Home: sin esto el GPS seguía
                // encendido con la app minimizada.
                locationService.stopTracking()
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
// Floating capsule (Villa Rica, approved by Keyla 19 Nov 2026). Every tab
// shows icon + label. The active tab sits on a soft forest pill.
// Liquid Glass on iOS 26+, regular material before.

struct GlassTabBar: View {
    @Binding var selection: AppTab
    var unreadChats: Int = 0
    /// Modo negocio (prototipo): el 4.º tab muestra el negocio activo.
    @ObservedObject private var accounts = AccountStore.shared

    private func label(_ tab: AppTab) -> String {
        tab == .yo ? (accounts.active != nil ? "Negocio" : tab.label) : tab.label
    }
    private func icon(_ tab: AppTab, _ active: Bool) -> String {
        if tab == .yo, accounts.active != nil { return active ? "storefront.fill" : "storefront" }
        return active ? tab.activeIcon : tab.icon
    }

    var body: some View {
        HStack(spacing: 4) {
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
                    // Velocidad (Keyla, 20 Nov 2026): la pantalla cambia al
                    // instante, como las pestañas nativas. Antes el cambio iba
                    // dentro de un resorte y TODA la pantalla nueva se animaba
                    // (~1 s hasta quedar quieta). La animación queda solo en la
                    // barra (ver .animation abajo).
                    PerfLog.tabTapAt = Date()
                    selection = tab
                } label: {
                    VStack(spacing: 3) {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: icon(tab, active))
                                .font(.system(size: 19, weight: active ? .semibold : .regular))
                                .frame(height: 22)
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
                        Text(label(tab))
                            .font(.system(size: 11, weight: active ? .semibold : .regular))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(active ? Color.brand : Color.tabBarInactive)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background {
                        if active {
                            Capsule().fill(Color.sageTint)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label(tab))
                .accessibilityValue(badge > 0 ? "\(badge) sin leer" : "")
                .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(6)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: selection)
        .floatingTabBarSurface()
    }
}

private struct FloatingTabBarSurface: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.border, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.10), radius: 14, y: 6)
        }
    }
}

private extension View {
    func floatingTabBarSurface() -> some View { modifier(FloatingTabBarSurface()) }
}

extension View {
    /// Alto que ocupa la barra flotante (cápsula 62 + margen 4 + aire 10).
    func floatingTabBarSpace() -> some View { safeAreaPadding(.bottom, 76) }
    /// Tiempo real desde el toque en la barra hasta que la pestaña se dibuja.
    func perfTabAppear(_ name: String) -> some View {
        onAppear {
            guard let t = PerfLog.tabTapAt else { return }
            DispatchQueue.main.async { PerfLog.ms("pestaña-\(name)", since: t); PerfLog.tabTapAt = nil }
        }
    }
}
