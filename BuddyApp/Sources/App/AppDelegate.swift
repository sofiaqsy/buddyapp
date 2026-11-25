import UIKit
import UserNotifications

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
        // El token entero no vuelve a aparecer en el log: identifica al
        // dispositivo y sirve para mandarle notificaciones. Con saber que
        // llegó y sus últimos cuatro caracteres alcanza para diagnosticar.
        print("[APNs] Device token registrado (…\(token.suffix(4)))")
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
    /// Se agregó o quitó una foto de un lugar. Aparte de journeyPublished
    /// porque esto NO es publicar: reusar aquella mostraría el toast de
    /// "Historia publicada" al borrar. Lo que comparten es la consecuencia —
    /// las fotos del lugar cambiaron y hay que recargar donde se muestran.
    static let placePhotosChanged = Notification.Name("placePhotosChanged")
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

// MARK: – Cerrar el teclado tocando fuera (Keyla, 24 Nov 2026)
// Regla de toda la app: con el teclado abierto, tocar cualquier otro lugar de la
// pantalla lo cierra. Un solo toque en la ventana, sin tapar nada: los botones,
// listas y mapas siguen recibiendo su toque (cancelsTouchesInView = false), y
// tocar otro campo de texto no lo cierra (pasa el foco a ese campo).
final class KeyboardDismisser: NSObject, UIGestureRecognizerDelegate {
    static let shared = KeyboardDismisser()

    /// Se instala una vez por ventana; llamar al aparecer la primera pantalla.
    static func install() {
        for scene in UIApplication.shared.connectedScenes {
            guard let ws = scene as? UIWindowScene else { continue }
            for window in ws.windows where !(window.gestureRecognizers ?? []).contains(where: { $0.name == "buddy.dismissKeyboard" }) {
                let tap = UITapGestureRecognizer(target: window, action: #selector(UIView.endEditing(_:)))
                tap.name = "buddy.dismissKeyboard"
                tap.cancelsTouchesInView = false
                tap.requiresExclusiveTouchType = false
                tap.delegate = shared
                window.addGestureRecognizer(tap)
                // Deslizar hacia abajo también lo cierra (Keyla, 24 Nov 2026).
                let swipe = UISwipeGestureRecognizer(target: window, action: #selector(UIView.endEditing(_:)))
                swipe.name = "buddy.dismissKeyboard.swipe"
                swipe.direction = .down
                swipe.cancelsTouchesInView = false
                swipe.delegate = shared
                window.addGestureRecognizer(swipe)
            }
            // En listas y pantallas que se desplazan, el teclado baja con el dedo (estándar de iOS).
            UIScrollView.appearance().keyboardDismissMode = .interactive
        }
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // Tocar un campo de texto no cierra el teclado.
        var v: UIView? = touch.view
        while let cur = v {
            if cur is UITextField || cur is UITextView || cur is UISearchBar { return false }
            v = cur.superview
        }
        return true
    }

    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}
