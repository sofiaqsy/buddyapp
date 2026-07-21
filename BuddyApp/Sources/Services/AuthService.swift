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
        var payload: [String: Any] = ["phone": phone, "token": code]
        if let currentId = TravelerService.shared.travelerId {
            payload["guest_traveler_id"] = currentId
            print("🔐 verifyOTP → incluyendo guest_traveler_id=\(currentId.prefix(8)) (status=\(TravelerService.shared.status ?? "nil"))")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

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
                UserDefaults.standard.set(true, forKey: "buddy.onboardingDone")
            }
            // Hydrate TravelerService with the Traveler identity resolved at auth time.
            if let tid   = json["traveler_id"]     as? String,
               let ttok  = json["traveler_token"]  as? String {
                let tstatus = json["traveler_status"] as? String ?? "verified"
                TravelerService.shared.hydrate(travelerId: tid, token: ttok, status: tstatus)
            }
        }
        return profileComplete
    }

    // MARK: – Complete profile (minimal — progressive registration)
    /// Crea el perfil mínimo con solo el nombre: usado en el flujo de registro
    /// progresivo donde el usuario se identifica en el momento de pedir ayuda.
    /// doc/DOB/nationality quedan en null y pueden completarse más tarde en el perfil.
    func completeProfileMinimal(fullName: String) async throws {
        guard let token = accessToken else { throw AuthError.noSession }

        let url = URL(string: "\(coreURL)/complete-profile")!
        var req = URLRequest(url: url)
        req.httpMethod = "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)",  forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["full_name": fullName])

        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let bodyStr = String(data: data, encoding: .utf8) ?? "empty"
        print("👤 completeProfileMinimal → status: \(status), body: \(bodyStr)")

        guard (200...299).contains(status) else { throw AuthError.sendFailed(bodyStr) }
        UserDefaults.standard.set(true, forKey: "buddy.onboardingDone")
    }

    // MARK: – Complete profile (full — onboarding clásico)
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
        // OTP / Supabase path
        if let token = accessToken {
            do {
                let status = try await pingMe(token: token)
                if status == 200 { return true }
                if status == 401 { return await tryRefresh() }
                return true
            } catch {
                return true // red offline → mantener sesión
            }
        }

        // Apple / Google path: si el traveler JWT sigue vivo, listo.
        if socialSessionValid() { return true }

        // JWT vencido (vive 15 min) pero la identidad persiste: renovar en
        // silencio con el secret device-bound del Keychain — la sesión social
        // debe sobrevivir indefinidamente, igual que un guest.
        if TravelerService.shared.isVerified, let tid = TravelerService.shared.travelerId {
            do {
                _ = try await TravelerService.shared.forceRefresh(travelerId: tid)
                print("🔄 [validateSession] social JWT renovado en silencio")
                return true
            } catch {
                // Red caída ≠ sesión inválida: solo cerrar sesión si el servidor
                // la rechazó explícitamente (sessionExpired limpia el estado).
                if case TravelerError.sessionExpired = error {
                    print("🔒 [validateSession] refresh social rechazado — sesión expirada")
                    return false
                }
                print("⚠️ [validateSession] refresh social falló por red — mantener sesión")
                return true
            }
        }
        return false
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
                // Refresh response now includes Traveler identity — hydrate so
                // TravelerService.travelerId is always set after any auth lifecycle event.
                if let tid  = json["traveler_id"]    as? String,
                   let ttok = json["traveler_token"] as? String {
                    let tstatus = json["traveler_status"] as? String ?? "verified"
                    TravelerService.shared.hydrate(travelerId: tid, token: ttok, status: tstatus)
                } else {
                    // Server returned no traveler identity — clear any stale traveler token
                    // so APIClient falls back to the Supabase token and doesn't loop.
                    print("⚠️ refresh returned no traveler_id — clearing stale traveler token")
                    UserDefaults.standard.removeObject(forKey: "buddy.traveler.token")
                    UserDefaults.standard.removeObject(forKey: "buddy.traveler.id")
                }
                print("🔄 session refreshed silently")
                return true
            } else {
                // Server rejected refresh token (truly invalid) → clear stale tokens
                // so APIClient falls back to anonKey instead of looping with a dead token.
                print("❌ refresh failed with status \(status) — clearing stale tokens")
                UserDefaults.standard.removeObject(forKey: "buddy.accessToken")
                UserDefaults.standard.removeObject(forKey: "buddy.refreshToken")
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

    // MARK: – Social Sign In

    /// Obtiene la credencial del proveedor y la envía al backend.
    /// Devuelve AuthResult — la decisión de navegación es del coordinador, no aquí.
    func signIn(with provider: IdentityProvider) async throws -> AuthResult {
        let credential = try await provider.signIn()
        return try await _postToBackend(credential)
    }

    func _postToBackend(_ credential: IdentityCredential) async throws -> AuthResult {
        var payload: [String: Any] = [
            "provider":       credential.provider.rawValue,
            "identity_token": credential.identityToken,
        ]
        if let name = credential.fullName { payload["full_name"] = name }
        // device_id permite al backend crear la sesión de refresh device-bound
        payload["device_id"] = TravelerService.shared.currentDeviceId

        let url = URL(string: "\(coreURL)/social")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = TravelerService.shared.token {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: req)
        let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
        let bodyStr    = String(data: data, encoding: .utf8) ?? "empty"
        print("[social/\(credential.provider.rawValue)] → \(httpStatus): \(bodyStr)")

        guard (200...299).contains(httpStatus) else { throw AuthError.sendFailed(bodyStr) }

        guard let json   = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tid    = json["traveler_id"]    as? String,
              let ttok   = json["traveler_token"] as? String,
              let rawSt  = json["status"]         as? String else {
            throw AuthError.sendFailed("Respuesta inesperada del servidor")
        }

        return AuthResult(
            travelerId:    tid,
            travelerToken: ttok,
            status:        AuthStatus(rawValue: rawSt) ?? .unknown,
            suggestedName: credential.fullName,
            refreshSecret: json["secret"] as? String
        )
    }

    // MARK: – Complete profile para usuarios de Apple/Google (sin sesión Supabase)
    /// Usa el traveler JWT directamente — no requiere access_token de Supabase.
    func completeProfileForSocialLogin(fullName: String) async throws {
        guard let token = TravelerService.shared.token else { throw AuthError.noSession }

        let url = URL(string: "\(coreURL)/profile")!
        var req = URLRequest(url: url)
        req.httpMethod = "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)",  forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["full_name": fullName])

        let (data, response) = try await URLSession.shared.data(for: req)
        let status  = (response as? HTTPURLResponse)?.statusCode ?? 0
        let bodyStr = String(data: data, encoding: .utf8) ?? "empty"
        print("👤 completeProfileSocial → status: \(status), body: \(bodyStr)")

        guard (200...299).contains(status) else { throw AuthError.sendFailed(bodyStr) }
        UserDefaults.standard.set(true, forKey: "buddy.onboardingDone")
    }

    // MARK: – Session helpers

    var accessToken: String? {
        UserDefaults.standard.string(forKey: "buddy.accessToken")
    }

    var userId: String? {
        UserDefaults.standard.string(forKey: "buddy.userId")
    }

    /// True si hay sesión Supabase activa (OTP) O identidad social verificada persistida.
    /// OJO: NO depende de la expiración del traveler JWT (vive 15 min) — la validez
    /// real la decide validateSession(), que renueva en silencio con el secret
    /// device-bound. Si dependiera del JWT, cualquier relanzamiento >15 min después
    /// del último uso mandaría al usuario al login (el bug de "la sesión murió").
    var isLoggedIn: Bool {
        if accessToken != nil { return true }
        return TravelerService.shared.isVerified && TravelerService.shared.travelerId != nil
    }

    // Decodifica el traveler JWT localmente y verifica que no haya expirado.
    // Para usuarios Apple/Google que no tienen access_token de Supabase.
    private func socialSessionValid() -> Bool {
        guard let token = TravelerService.shared.token,
              TravelerService.shared.status == "verified" else { return false }
        return !jwtExpired(token)
    }

    private func jwtExpired(_ token: String) -> Bool {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return true }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data    = Data(base64Encoded: b64),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp     = payload["exp"] as? TimeInterval else { return true }
        return Date().timeIntervalSince1970 >= exp
    }

    var hasCompletedOnboarding: Bool {
        UserDefaults.standard.bool(forKey: "buddy.onboardingDone")
    }

    // MARK: – Sign out
    /// Cierra la sesión intencionalmente: elimina tokens y notifica a la app.
    /// Distinto de `.sessionExpired` (que es un error de token, no una acción del usuario).
    func signOut() {
        print("🚪 [AuthService.signOut] limpiando sesión OTP…")
        UserDefaults.standard.removeObject(forKey: "buddy.accessToken")
        UserDefaults.standard.removeObject(forKey: "buddy.userId")
        UserDefaults.standard.removeObject(forKey: "buddy.refreshToken")
        UserDefaults.standard.set(false, forKey: "buddy.isLoggedIn")
        UserDefaults.standard.removeObject(forKey: "buddy.onboardingDone")
        UserDefaults.standard.removeObject(forKey: "buddy.device.id")
        print("🚪 [AuthService.signOut] limpiando sesión Traveler (UserDefaults + Keychain)…")
        TravelerService.shared.clearSession()
        print("🚪 [AuthService.signOut] ✅ todo limpio — emitiendo userDidLogOut")
        NotificationCenter.default.post(name: .userDidLogOut, object: nil)
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
