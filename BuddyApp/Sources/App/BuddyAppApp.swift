import SwiftUI

@main
struct BuddyAppApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var locationService = LocationService()
    @StateObject private var routeStore      = RouteStore()
    @StateObject private var authState       = AuthState()

    var body: some Scene {
        WindowGroup {
            Group {
                if authState.isValidating {
                    // Splash mientras valida sesión
                    ZStack {
                        Color.canvas.ignoresSafeArea()
                        VStack(spacing: Spacing.md) {
                            Text("buddy.")
                                .font(.system(size: 34, weight: .light, design: .serif))
                                .italic()
                                .foregroundStyle(Color.sand)
                            ProgressView()
                                .tint(Color.inkMuted)
                        }
                    }
                } else if authState.isLoggedIn {
                    RootView()
                        .environmentObject(locationService)
                        .environmentObject(routeStore)
                        .environmentObject(authState)
                        .onAppear { appDelegate.requestPushPermission() }
                } else if authState.needsOnboarding {
                    OnboardingView {
                        authState.needsOnboarding = false
                        authState.isLoggedIn = true
                    }
                    .environmentObject(authState)
                } else if AuthService.shared.hasCompletedOnboarding {
                    // Returning user — only re-verify phone number
                    // But if profile was never saved (edge case), show identity step
                    ReAuthView { profileComplete in
                        if profileComplete {
                            authState.isLoggedIn = true
                        } else {
                            // Profile missing — fall through to full onboarding
                            UserDefaults.standard.set(false, forKey: "buddy.onboardingDone")
                            authState.needsOnboarding = true
                        }
                    }
                } else {
                    OnboardingView {
                        authState.isLoggedIn = true
                    }
                    .environmentObject(authState)
                }
            }
            .animation(.easeInOut(duration: 0.3), value: authState.isLoggedIn)
            .animation(.easeInOut(duration: 0.2), value: authState.isValidating)
            .task { await authState.validate() }
            // El design system es light-only (canvas crema + tinta fija).
            // Sin esto, en dark mode los TextField escriben blanco sobre blanco.
            .preferredColorScheme(.light)
        }
    }
}

// MARK: – Auth State
// Simple observable that holds login status.

final class AuthState: ObservableObject {
    @Published var isLoggedIn: Bool   = false
    @Published var isValidating: Bool = true
    @Published var needsOnboarding: Bool = false

    private var sessionCancellable: Any?

    init() {
        // Listen for token-expired events from APIClient's auto-refresh interceptor
        sessionCancellable = NotificationCenter.default.addObserver(
            forName: .sessionExpired,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            print("🔒 session expired — redirecting to login")
            self?.isLoggedIn = false
        }
    }

    @MainActor
    func validate() async {
        isValidating = true
        isLoggedIn = await AuthService.shared.validateSession()
        isValidating = false
    }
}
