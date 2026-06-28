import Foundation

/// Handles registering / unregistering the APNs device token with buddy-core.
final class PushService {
    static let shared = PushService()
    private init() {}

    func registerToken(_ token: String) async {
        guard Session.hasSession else { return }
        #if DEBUG
        let environment = "sandbox"
        #else
        let environment = "production"
        #endif
        do {
            _ = try await APIClient.shared.post(
                path: "/notifications/token",
                body: ["token": token, "platform": "ios", "environment": environment]
            )
            print("[PushService] Token registered ✓")
        } catch {
            print("[PushService] Failed to register token: \(error)")
        }
    }

    func unregisterToken() async {
        guard let token = UserDefaults.standard.string(forKey: "apns_device_token") else { return }
        do {
            _ = try await APIClient.shared.delete(path: "/notifications/token", body: ["token": token])
            UserDefaults.standard.removeObject(forKey: "apns_device_token")
            print("[PushService] Token unregistered ✓")
        } catch {
            print("[PushService] Failed to unregister token: \(error)")
        }
    }
}
