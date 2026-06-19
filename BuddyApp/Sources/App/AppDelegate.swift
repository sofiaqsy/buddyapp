import UIKit
import UserNotifications

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
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

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let userInfo = notification.request.content.userInfo
        NotificationCenter.default.post(name: .pushReceivedForeground, object: nil, userInfo: userInfo)
        if (userInfo["type"] as? String) == "match_completed" {
            NotificationCenter.default.post(name: .matchCompleted, object: nil, userInfo: userInfo)
        }
        // Show banner + sound even when app is in foreground
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
        if (userInfo["type"] as? String) == "match_completed" {
            NotificationCenter.default.post(name: .matchCompleted, object: nil, userInfo: userInfo)
        }
        completionHandler()
    }
}

extension Notification.Name {
    static let pushNotificationTapped = Notification.Name("pushNotificationTapped")
    static let pushReceivedForeground = Notification.Name("pushReceivedForeground") // push llegó con la app abierta
    static let stickerUnlocked = Notification.Name("stickerUnlocked")
    static let sessionExpired  = Notification.Name("sessionExpired")
    static let memoirPageSaved = Notification.Name("memoirPageSaved")
    static let switchToTab     = Notification.Name("switchToTab")
    static let journeyActivated  = Notification.Name("journeyActivated")
    static let journeyPublished  = Notification.Name("journeyPublished")
    static let journeyCancelled  = Notification.Name("journeyCancelled")
    static let tabReselected     = Notification.Name("tabReselected")   // re-tap del tab activo
    static let helpCompleted     = Notification.Name("helpCompleted")   // se cerró un apoyo → refrescar comunidad
    static let openPlaceInMap    = Notification.Name("openPlaceInMap")  // userInfo: lat, lng, name
    static let matchCompleted    = Notification.Name("matchCompleted")  // buddy cerró el match → mostrar encuesta al viajero
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
