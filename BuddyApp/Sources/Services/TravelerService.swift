import Foundation
import Security
import UIKit

// MARK: – TRAVELER SERVICE
// Manages the guest/verified Traveler session.
// A Traveler is created lazily on the first meaningful action (request help,
// create trip, etc.). Never created on app launch.
//
// Storage layout:
//   Keychain:     buddy.traveler.secret   — 64-char hex, never leaves the device
//   UserDefaults: buddy.traveler.id       — UUID
//                 buddy.traveler.token    — short-lived JWT (15 min)
//                 buddy.traveler.status   — "guest" | "verified"

final class TravelerService {
    static let shared = TravelerService()
    private init() {}

    private let coreURL    = "https://buddy-core-504b393f8333.herokuapp.com/v1/travelers"
    private let deviceId   = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString

    // MARK: – Public state

    var travelerId: String? { UserDefaults.standard.string(forKey: "buddy.traveler.id") }
    var token: String?      { UserDefaults.standard.string(forKey: "buddy.traveler.token") }
    var status: String      { UserDefaults.standard.string(forKey: "buddy.traveler.status") ?? "guest" }
    var isGuest: Bool       { travelerId != nil && status == "guest" }
    var isVerified: Bool    { status == "verified" }
    var hasSession: Bool    { travelerId != nil }

    // MARK: – Lazy init (called on first meaningful action)

    /// Ensures a Traveler session exists. If none exists, creates one via /travelers/init.
    /// If one exists but the token is expired, refreshes it silently.
    /// Returns the valid JWT to use in Authorization headers.
    @discardableResult
    func ensureSession() async throws -> String {
        print("🧳 [TravelerService.ensureSession] hasSession=\(hasSession) travelerId=\(travelerId?.prefix(8) ?? "NIL")")
        // Already have a traveler — just ensure the token is fresh
        if let tid = travelerId {
            return try await refreshIfNeeded(travelerId: tid)
        }
        // First meaningful action: create a new guest traveler
        print("🧳 [TravelerService.ensureSession] → no session found, calling /travelers/init")
        return try await createGuestSession()
    }

    // MARK: – Create guest session

    private func createGuestSession() async throws -> String {
        print("🧳 [TravelerService] POST /travelers/init → device_id=\(deviceId.prefix(8))…")
        let url = URL(string: "\(coreURL)/init")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["device_id": deviceId])

        let (data, response) = try await URLSession.shared.data(for: req)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        print("🧳 [TravelerService] /travelers/init → statusCode=\(statusCode) bytes=\(data.count)")
        guard (200...299).contains(statusCode),
              let json  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tid   = json["traveler_id"] as? String,
              let token = json["token"]       as? String
        else {
            let body = String(data: data, encoding: .utf8) ?? ""
            print("❌ [TravelerService] /travelers/init FAILED status=\(statusCode) body=\(body)")
            throw TravelerError.initFailed(body)
        }

        // Persist — secret only present on first creation; on idempotent returns it's omitted
        UserDefaults.standard.set(tid,     forKey: "buddy.traveler.id")
        UserDefaults.standard.set(token,   forKey: "buddy.traveler.token")
        UserDefaults.standard.set("guest", forKey: "buddy.traveler.status")
        if let secret = json["secret"] as? String { saveSecretToKeychain(secret) }

        print("✅ [TravelerService] guest created → \(tid) (persisted)")
        print("✅ [TravelerService] Session.hasSession is now: \(travelerId != nil)")
        return token
    }

    // MARK: – Refresh token

    private func refreshIfNeeded(travelerId: String) async throws -> String {
        if let t = token, !t.isEmpty, !jwtExpiresSoon(t) { return t }
        return try await forceRefresh(travelerId: travelerId)
    }

    // Returns true if the JWT is missing, malformed, or expires within 5 minutes.
    private func jwtExpiresSoon(_ token: String) -> Bool {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return true }
        var b64 = String(parts[1])
        let rem = b64.count % 4
        if rem != 0 { b64 += String(repeating: "=", count: 4 - rem) }
        guard let data = Data(base64Encoded: b64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp  = json["exp"] as? TimeInterval
        else { return true }
        return Date(timeIntervalSince1970: exp).timeIntervalSinceNow < 300 // 5 min buffer
    }

    func forceRefresh(travelerId: String) async throws -> String {
        // Verified users (OTP/Apple) have no secret — they refresh via the
        // Supabase token path, which now returns a fresh traveler_token.
        guard let secret = loadSecretFromKeychain() else {
            let ok = await AuthService.shared.tryRefresh()
            guard ok, let t = TravelerService.shared.token, !t.isEmpty else {
                // Both refresh paths exhausted — wipe stored session so
                // Session.hasSession becomes false and the retry loop stops.
                print("🧹 [TravelerService] verified refresh failed — clearing stale session")
                clearSession()
                throw TravelerError.sessionExpired
            }
            return t
        }

        let url = URL(string: "\(coreURL)/refresh")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "traveler_id": travelerId,
            "secret":      secret,
            "device_id":   deviceId
        ])

        let (data, response) = try await URLSession.shared.data(for: req)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        guard (200...299).contains(statusCode),
              let json  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["token"] as? String
        else {
            if statusCode == 401 {
                // Guest secret rejected — session permanently expired.
                print("🧹 [TravelerService] guest refresh 401 — clearing stale session")
                clearSession()
                throw TravelerError.sessionExpired
            }
            throw TravelerError.refreshFailed(String(data: data, encoding: .utf8) ?? "")
        }

        if let newStatus = json["status"] as? String {
            UserDefaults.standard.set(newStatus, forKey: "buddy.traveler.status")
        }
        UserDefaults.standard.set(token, forKey: "buddy.traveler.token")
        print("🔄 [TravelerService] token refreshed → \(travelerId)")
        return token
    }

    // MARK: – Hydrate (called by AuthService after OTP/Apple authentication)
    // Persists the Traveler identity resolved by the backend at auth time.
    // No secret involved — verified users refresh via the Supabase token path.

    func hydrate(travelerId: String, token: String, status: String = "verified") {
        UserDefaults.standard.set(travelerId, forKey: "buddy.traveler.id")
        UserDefaults.standard.set(token,      forKey: "buddy.traveler.token")
        UserDefaults.standard.set(status,     forKey: "buddy.traveler.status")
        print("✅ [TravelerService] hydrated → \(travelerId) status=\(status)")
    }

    // MARK: – Upgrade: Guest → Verified (legacy — kept for Apple Sign In path)

    func markVerified(fullName: String?, phone: String?) {
        UserDefaults.standard.set("verified", forKey: "buddy.traveler.status")
        print("✅ [TravelerService] traveler upgraded to verified")
    }

    // MARK: – Clear (logout / reset)

    func clearSession() {
        UserDefaults.standard.removeObject(forKey: "buddy.traveler.id")
        UserDefaults.standard.removeObject(forKey: "buddy.traveler.token")
        UserDefaults.standard.removeObject(forKey: "buddy.traveler.status")
        deleteSecretFromKeychain()
        print("🧹 [TravelerService] session cleared")
    }

    // MARK: – Keychain helpers

    private let keychainKey = "com.buddyapp.traveler.secret"

    private func saveSecretToKeychain(_ secret: String) {
        guard let data = secret.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: keychainKey,
            kSecValueData as String:   data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    private func loadSecretFromKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: keychainKey,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let secret = String(data: data, encoding: .utf8) else { return nil }
        return secret
    }

    private func deleteSecretFromKeychain() {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: keychainKey
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: – Session
// Single access point for Traveler-first identity.
// When the legacy Supabase path is removed, only this block changes.

enum Session {
    static var travelerId: String? {
        TravelerService.shared.travelerId
        // No fallback to AuthService.shared.userId — auth UUID ≠ traveler UUID.
        // If nil here, TravelerService was never hydrated; hydration happens at
        // authentication time (verifyOTP/tryRefresh) so this should never be nil
        // while the app is in an authenticated state.
    }
    static var token: String? {
        TravelerService.shared.token ?? AuthService.shared.accessToken
    }
    static var hasSession: Bool {
        TravelerService.shared.hasSession || AuthService.shared.isLoggedIn
    }
    static var isVerified: Bool {
        TravelerService.shared.isVerified || AuthService.shared.isLoggedIn
    }
}

// MARK: – Errors

enum TravelerError: LocalizedError {
    case initFailed(String)
    case refreshFailed(String)
    case sessionExpired
    case noSecret

    var errorDescription: String? {
        switch self {
        case .initFailed(let m):   return "No se pudo crear la sesión. \(m)"
        case .refreshFailed(let m): return "No se pudo renovar la sesión. \(m)"
        case .sessionExpired:      return "Sesión expirada. Recupérala con tu teléfono."
        case .noSecret:            return "Secret no encontrado en Keychain."
        }
    }
}
