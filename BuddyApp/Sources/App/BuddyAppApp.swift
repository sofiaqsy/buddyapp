import SwiftUI

@main
struct BuddyAppApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var locationService = LocationService()
    @StateObject private var routeStore      = RouteStore()
    @StateObject private var authState       = AuthState()

    var body: some Scene {
        WindowGroup {
            // RootView es siempre el punto de entrada.
            // La autenticación controla capacidades, no navegación.
            RootView()
                .environmentObject(locationService)
                .environmentObject(routeStore)
                .environmentObject(authState)
                .onAppear {
                    // Solo pedir push si hay sesión activa — los usuarios anónimos
                    // no reciben notificaciones push.
                    if authState.isLoggedIn { appDelegate.requestPushPermission() }
                }
                // Validación en background: si el token almacenado ya no es válido,
                // AuthState lo marca y la UI transiciona a estado anónimo.
                .task { await authState.validate() }
                .preferredColorScheme(.light)
                .animation(.easeInOut(duration: 0.3), value: authState.isLoggedIn)
        }
    }
}

// MARK: – Auth State

/// Observable centralizado de la sesión y las capacidades del Traveler.
/// RootView nunca se oculta — solo cambia lo que puede hacer el Traveler.
///
/// Modelo de estados:
///   isLoggedIn = false, travelerStatus = nil   → sin sesión (primera apertura)
///   isLoggedIn = false, travelerStatus = "guest"  → Guest Traveler (tiene sesión, sin identidad)
///   isLoggedIn = true,  travelerStatus = "verified" → Traveler verificado
///
/// Durante la transición al modelo Traveler-first, isLoggedIn sigue mapeando a
/// "tiene identidad verificada" para que el resto de la app no necesite cambios.
final class AuthState: ObservableObject {

    // MARK: – Estado base

    /// true = Traveler verificado (phone/Apple). false = Guest o sin sesión.
    /// Inicializado desde el token almacenado para evitar flash en returning users.
    @Published var isLoggedIn: Bool = AuthService.shared.isLoggedIn

    /// Estado del Traveler. nil = aún no se ha creado sesión de Traveler.
    /// "guest" = tiene sesión pero sin identidad verificada.
    /// "verified" = identidad confirmada.
    @Published var travelerStatus: String? = TravelerService.shared.hasSession
        ? TravelerService.shared.status
        : nil

    /// true durante validación de red en background.
    @Published var isValidating: Bool = false

    // MARK: – Capacidades

    /// Puede explorar home, destinos, feed — siempre true.
    var canBrowse:       Bool { true }
    /// Pedir ayuda, crear trips, chatear, crear momentos — todos los Travelers (guest + verified).
    var canRequestHelp:  Bool { true }
    var canChat:         Bool { true }
    var canManageTrip:   Bool { true }
    var canCreateMoment: Bool { true }
    /// Publicar momentos, compartir álbumes, sync multi-device — solo Verified.
    var canPublish:      Bool { isLoggedIn }
    var canSync:         Bool { isLoggedIn }
    /// Solicitar ser buddy — solo Verified.
    var canBecomeBuddy:  Bool { isLoggedIn }

    var isGuest: Bool { travelerStatus == "guest" }

    private var sessionCancellable:        Any?
    private var logoutCancellable:         Any?
    private var travelerCreatedCancellable: Any?

    init() {
        sessionCancellable = NotificationCenter.default.addObserver(
            forName: .sessionExpired, object: nil, queue: .main
        ) { [weak self] _ in
            print("🔒 sessionExpired — modo guest")
            self?.isLoggedIn = false
        }

        logoutCancellable = NotificationCenter.default.addObserver(
            forName: .userDidLogOut, object: nil, queue: .main
        ) { [weak self] _ in
            print("👋 userDidLogOut")
            self?.isLoggedIn = false
            // Guest Traveler session persists across logout — datos conservados
        }

        travelerCreatedCancellable = NotificationCenter.default.addObserver(
            forName: .travelerSessionCreated, object: nil, queue: .main
        ) { [weak self] _ in
            print("🧳 travelerSessionCreated — guest session activa")
            self?.travelerStatus = "guest"
        }
    }

    @MainActor
    func validate() async {
        guard AuthService.shared.isLoggedIn else {
            isLoggedIn = false
            return
        }
        isValidating = true
        let valid = await AuthService.shared.validateSession()
        isLoggedIn   = valid

        // If session is valid but TravelerService was never hydrated (first cold
        // launch after installing this version), force one refresh so the backend
        // returns traveler_id + traveler_token and we can hydrate TravelerService.
        // After this single call, travelerId is persisted and this branch is skipped.
        if valid && TravelerService.shared.travelerId == nil {
            print("⚠️ [AuthState] session valid but Traveler not hydrated — forcing refresh")
            _ = await AuthService.shared.tryRefresh()
        }

        isValidating = false
    }

    @MainActor
    func didAuthenticate() {
        isLoggedIn = true
        travelerStatus = "verified"
        TravelerService.shared.markVerified(fullName: nil, phone: nil)
    }

    /// Called when a Guest Traveler session is created (first meaningful action).
    @MainActor
    func didCreateGuestSession() {
        travelerStatus = "guest"
    }
}
