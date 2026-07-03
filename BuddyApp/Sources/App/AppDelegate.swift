import UIKit
import UserNotifications
import GoogleSignIn

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        // RootView solicita el permiso de push cuando el usuario se autentica
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRequestPush),
            name: .requestPushPermission,
            object: nil
        )
        return true
    }

    @objc private func handleRequestPush() {
        requestPushPermission()
    }

    // Tocar fuera de un campo de texto cierra el teclado en cualquier pantalla.
    // Google Sign In: manejar el URL de callback OAuth
    func application(_ app: UIApplication, open url: URL,
                     options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        GIDSignIn.sharedInstance.handle(url)
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        let window = application.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        KeyboardDismisser.shared.install(on: window)
    }

    // MARK: – Request permission & register for remote notifications

    func requestPushPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            DispatchQueue.main.async {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
    }

    // MARK: – Token received from APNs

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        print("[APNs] Device token: \(token)")
        // Save locally and send to server
        UserDefaults.standard.set(token, forKey: "apns_device_token")
        Task { await PushService.shared.registerToken(token) }
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("[APNs] Failed to register: \(error)")
    }

    // MARK: – Foreground notification display

    // MARK: – Foreground display

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let userInfo = notification.request.content.userInfo
        NotificationCenter.default.post(name: .pushReceivedForeground, object: nil, userInfo: userInfo)

        // Legacy: match_completed uses its own notification name
        if (userInfo["type"] as? String) == "match_completed" {
            NotificationCenter.default.post(name: .matchCompleted, object: nil, userInfo: userInfo)
        }

        if NotificationRouter.shouldSuppress(userInfo) {
            completionHandler([])
            return
        }

        completionHandler([.banner, .sound, .badge])
    }

    // MARK: – Notification tapped

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        NotificationCenter.default.post(name: .pushNotificationTapped, object: nil, userInfo: userInfo)

        // Legacy: match_completed
        if (userInfo["type"] as? String) == "match_completed" {
            NotificationCenter.default.post(name: .matchCompleted, object: nil, userInfo: userInfo)
        }

        NotificationRouter.route(userInfo)
        completionHandler()
    }
}

// MARK: – Cierre global del teclado
// Instala un gesto de tap a nivel de ventana para que tocar fuera de un campo
// de texto cierre el teclado en CUALQUIER pantalla. `cancelsTouchesInView = false`
// y el delegate permiten que botones, listas y demás gestos sigan funcionando.
final class KeyboardDismisser: NSObject, UIGestureRecognizerDelegate {
    static let shared = KeyboardDismisser()
    private weak var installedWindow: UIWindow?

    func install(on window: UIWindow?) {
        guard let window, installedWindow !== window else { return }
        installedWindow = window
        let tap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        window.addGestureRecognizer(tap)
    }

    @objc private func dismissKeyboard() {
        installedWindow?.endEditing(true)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}

extension Notification.Name {
    static let pushNotificationTapped = Notification.Name("pushNotificationTapped")
    static let pushReceivedForeground = Notification.Name("pushReceivedForeground") // push llegó con la app abierta
    static let stickerUnlocked = Notification.Name("stickerUnlocked")
    /// Token inválido o refresh fallido — sesión perdida sin acción del usuario.
    static let sessionExpired  = Notification.Name("sessionExpired")
    /// El usuario eligió cerrar sesión deliberadamente.
    static let userDidLogOut   = Notification.Name("userDidLogOut")
    static let memoirPageSaved = Notification.Name("memoirPageSaved")
    static let switchToTab     = Notification.Name("switchToTab")
    static let journeyActivated  = Notification.Name("journeyActivated")
    static let journeyPublished  = Notification.Name("journeyPublished")
    static let journeyCancelled  = Notification.Name("journeyCancelled")
    static let tabReselected     = Notification.Name("tabReselected")   // re-tap del tab activo
    static let helpCompleted     = Notification.Name("helpCompleted")   // se cerró un apoyo → refrescar comunidad
    static let openPlaceInMap    = Notification.Name("openPlaceInMap")  // userInfo: lat, lng, name
    static let matchCompleted    = Notification.Name("matchCompleted")  // buddy cerró el match → mostrar encuesta al viajero
    static let helpOfferReceived = Notification.Name("helpOfferReceived") // matching eligió a este buddy → recargar ofertas
    /// RootView lo emite cuando el usuario se autentica por primera vez en esta sesión.
    static let requestPushPermission  = Notification.Name("requestPushPermission")
    /// Se creó una sesión de Traveler guest por primera vez (primera acción significativa).
    static let travelerSessionCreated = Notification.Name("travelerSessionCreated")
    /// Push de nuevo mensaje tapeado — abre el chat. userInfo: match_id
    static let openChatForMatch  = Notification.Name("openChatForMatch")
    /// Push "buddy aprobado" tapeado — abre el tab Yo.
    static let openBuddyProfile  = Notification.Name("openBuddyProfile")
}

// MARK: – Chat presence (used to suppress push banner when chat is open)

final class ChatPresenceTracker {
    static let shared = ChatPresenceTracker()
    private init() {}
    /// match_id currently visible on screen, or nil if no chat is open.
    var activeChatMatchId: String? = nil
}

// MARK: – Place deep-link

final class PlaceDeepLink: ObservableObject {
    static let shared = PlaceDeepLink()
    private init() {}

    @Published var pending: PendingPlace? = nil

    struct PendingPlace {
        let lat: Double
        let lng: Double
        let name: String
    }

    func consume() -> PendingPlace? {
        let p = pending; pending = nil; return p
    }
}
