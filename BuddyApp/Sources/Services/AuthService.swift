import Foundation

// MARK: – AUTH SERVICE
// All auth calls go through buddy-core.
// Logs visible in Heroku dashboard.

final class AuthService {
    static let shared = AuthService()
    private init() {}

    private let coreURL = "https://buddy-core-504b393f8333.herokuapp.com/v1/auth"

    // MARK: – Send OTP
    /// Asks buddy-core to send an SMS OTP to the given phone (E.164: +51XXXXXXXXX)
    func sendOTP(phone: String) async throws {
        let url = URL(string: "\(coreURL)/send-otp")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["phone": phone])

        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body   = String(data: data, encoding: .utf8) ?? "empty"
        print("📱 sendOTP → status: \(status), body: \(body)")

        guard (200...299).contains(status) else {
            throw AuthError.sendFailed(body)
        }
    }

    // MARK: – Verify OTP
    /// Verifies the code with buddy-core. On success stores session locally.
    /// Returns `true` if the user already has a complete profile (skip onboarding).
    @discardableResult
    func verifyOTP(phone: String, code: String) async throws -> Bool {
        let url = URL(string: "\(coreURL)/verify-otp")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["phone": phone, "token": code])

        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body   = String(data: data, encoding: .utf8) ?? "empty"
        print("🔐 verifyOTP → status: \(status), body: \(body)")

        guard (200...299).contains(status) else {
            throw AuthError.invalidCode
        }

        var profileComplete = false
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let token  = json["access_token"]  as? String { UserDefaults.standard.set(token,  forKey: "buddy.accessToken")  }
            if let userId = json["user_id"]        as? String { UserDefaults.standard.set(userId, forKey: "buddy.userId")       }
            if let rtoken = json["refresh_token"]  as? String { UserDefaults.standard.set(rtoken, forKey: "buddy.refreshToken") }
            profileComplete = json["has_profile"] as? Bool ?? false
            if profileComplete {
                // Mark onboarding done locally so next launch uses ReAuthView
                UserDefaults.standard.set(true, forKey: "buddy.onboardingDone")
            }
        }
        return profileComplete
    }

    // MARK: – Complete profile
    /// Saves identity data to buddy-core after onboarding completes.
    func completeProfile(fullName: String, docType: String, docNumber: String, birthDate: String, nationality: String) async throws {
        guard let token = accessToken else { throw AuthError.noSession }

        let url = URL(string: "\(coreURL)/complete-profile")!
        var req = URLRequest(url: url)
        req.httpMethod = "PATCH"
        req.setValue("application/json",    forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)",     forHTTPHeaderField: "Authorization")

        var body: [String: Any] = [
            "full_name":    fullName,
            "doc_type":     docType,
            "doc_number":   docNumber,
            "nationality":  nationality
        ]
        if !birthDate.isEmpty { body["birth_date"] = birthDate }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let bodyStr = String(data: data, encoding: .utf8) ?? "empty"
        print("👤 completeProfile → status: \(status), body: \(bodyStr)")

        guard (200...299).contains(status) else {
            throw AuthError.sendFailed(bodyStr)
        }
        UserDefaults.standard.set(true, forKey: "buddy.onboardingDone")
    }

    // MARK: – Validate session against server
    /// 1. Checks /me with the stored access token.
    /// 2. If expired (401), tries to refresh silently with the refresh token.
    /// 3. Only returns false (→ login screen) if both fail.
    func validateSession() async -> Bool {
        guard let token = accessToken else { return false }

        do {
            let status = try await pingMe(token: token)
            if status == 200 { return true }
            if status == 401 { return await tryRefresh() }
            return true // other errors → assume online later
        } catch {
            return true // network offline → keep session
        }
    }

    private func pingMe(token: String) async throws -> Int {
        let url = URL(string: "\(coreURL)/me")!
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 10
        let (_, response) = try await URLSession.shared.data(for: req)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    /// Public so APIClient can call it on 401.
    /// Returns true if new tokens were obtained. Never wipes tokens on network error.
    func tryRefresh() async -> Bool {
        guard let refreshToken = UserDefaults.standard.string(forKey: "buddy.refreshToken"),
              !refreshToken.isEmpty else {
            // No refresh token at all → session truly gone
            await MainActor.run {
                NotificationCenter.default.post(name: .sessionExpired, object: nil)
            }
            return false
        }

        let url = URL(string: "\(coreURL)/refresh")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["refresh_token": refreshToken])
        req.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0

            if status == 200,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                // Si el refresh devuelve OTRO usuario (sesiones cruzadas al
                // probar varias cuentas en el mismo dispositivo), no podemos
                // seguir con la UI del usuario anterior → re-login explícito.
                let previousId = UserDefaults.standard.string(forKey: "buddy.userId")
                if let id = json["user_id"] as? String,
                   let prev = previousId, !prev.isEmpty, prev != id {
                    print("🚨 refresh devolvió otro usuario (\(prev) → \(id)) — forzando re-login")
                    await MainActor.run {
                        NotificationCenter.default.post(name: .sessionExpired, object: nil)
                    }
                    return false
                }
                if let t  = json["access_token"]  as? String { UserDefaults.standard.set(t,  forKey: "buddy.accessToken")  }
                if let rt = json["refresh_token"] as? String { UserDefaults.standard.set(rt, forKey: "buddy.refreshToken") }
                if let id = json["user_id"]       as? String { UserDefaults.standard.set(id, forKey: "buddy.userId")       }
                print("🔄 session refreshed silently")
                return true
            } else {
                // Server rejected refresh token (truly invalid) → go to login
                print("❌ refresh failed with status \(status) — redirecting to login")
                await MainActor.run {
                    NotificationCenter.default.post(name: .sessionExpired, object: nil)
                }
                return false
            }
        } catch {
            // Network error → keep existing session, retry later
            print("⚠️ refresh network error, keeping session: \(error.localizedDescription)")
            return true
        }
    }

    // MARK: – Session helpers

    var accessToken: String? {
        UserDefaults.standard.string(forKey: "buddy.accessToken")
    }

    var userId: String? {
        UserDefaults.standard.string(forKey: "buddy.userId")
    }

    var isLoggedIn: Bool {
        accessToken != nil
    }

    var hasCompletedOnboarding: Bool {
        UserDefaults.standard.bool(forKey: "buddy.onboardingDone")
    }

    // MARK: – Sign out
    func signOut() {
        UserDefaults.standard.removeObject(forKey: "buddy.accessToken")
        UserDefaults.standard.removeObject(forKey: "buddy.userId")
        UserDefaults.standard.removeObject(forKey: "buddy.refreshToken")
        UserDefaults.standard.set(false, forKey: "buddy.isLoggedIn")
    }
}

// MARK: – Errors

enum AuthError: LocalizedError {
    case sendFailed(String)
    case invalidCode
    case noSession

    var errorDescription: String? {
        switch self {
        case .sendFailed(let msg): return "No se pudo enviar el código. \(msg)"
        case .invalidCode:         return "Código incorrecto o expirado."
        case .noSession:           return "Sesión no encontrada."
        }
    }
}
