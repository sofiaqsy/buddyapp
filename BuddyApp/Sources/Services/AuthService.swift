import Foundation

// MARK: – AUTH SERVICE
// All auth calls go through buddy-core.
// Logs visible in Heroku dashboard.

final class AuthService {
    static let shared = AuthService()

    // Dependencias inyectables para las pruebas (BuddyAppTests/AuthServiceTests).
    // La app usa siempre los valores por defecto: mismo comportamiento que antes.
    private let defaults: UserDefaults
    private let store: SecureStore
    private let session: URLSession
    private let notifications: NotificationCenter
    private let travelerOverride: TravelerService?
    /// En la app es TravelerService.shared (se lee al usarlo, como antes).
    private var traveler: TravelerService { travelerOverride ?? TravelerService.shared }

    init(defaults: UserDefaults = .standard,
         store: SecureStore = .shared,
         session: URLSession = .shared,
         notifications: NotificationCenter = .default,
         traveler: TravelerService? = nil) {
        self.defaults = defaults
        self.store = store
        self.session = session
        self.notifications = notifications
        self.travelerOverride = traveler
    }

    private let coreURL = "https://buddy-core-504b393f8333.herokuapp.com/v1/auth"

    // MARK: – Send OTP
    /// Asks buddy-core to send an SMS OTP to the given phone (E.164: +51XXXXXXXXX)
    func sendOTP(phone: String) async throws {
        let url = URL(string: "\(coreURL)/send-otp")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["phone": phone])

        let (data, response) = try await session.data(for: req)
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
        if let currentId = traveler.travelerId {
            payload["guest_traveler_id"] = currentId
            print("🔐 verifyOTP → incluyendo guest_traveler_id=\(currentId.prefix(8)) (status=\(traveler.status ?? "nil"))")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body   = String(data: data, encoding: .utf8) ?? "empty"
        print("🔐 verifyOTP → status: \(status), body: \(body)")

        guard (200...299).contains(status) else {
            throw AuthError.invalidCode
        }

        var profileComplete = false
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let token  = json["access_token"]  as? String { store.set(token, .accessToken)  }
            if let userId = json["user_id"]        as? String { defaults.set(userId, forKey: "buddy.userId")       }
            if let rtoken = json["refresh_token"]  as? String { store.set(rtoken, .refreshToken) }
            profileComplete = json["has_profile"] as? Bool ?? false
            if profileComplete {
                defaults.set(true, forKey: "buddy.onboardingDone")
            }
            // Hydrate TravelerService with the Traveler identity resolved at auth time.
            if let tid   = json["traveler_id"]     as? String,
               let ttok  = json["traveler_token"]  as? String {
                let tstatus = json["traveler_status"] as? String ?? "verified"
                traveler.hydrate(travelerId: tid, token: ttok, status: tstatus)
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

        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let bodyStr = String(data: data, encoding: .utf8) ?? "empty"
        dlog("👤 completeProfileMinimal → status: \(status), body: \(bodyStr)")

        guard (200...299).contains(status) else { throw AuthError.sendFailed(bodyStr) }
        defaults.set(true, forKey: "buddy.onboardingDone")
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

        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let bodyStr = String(data: data, encoding: .utf8) ?? "empty"
        dlog("👤 completeProfile → status: \(status), body: \(bodyStr)")

        guard (200...299).contains(status) else {
            throw AuthError.sendFailed(bodyStr)
        }
        defaults.set(true, forKey: "buddy.onboardingDone")
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
        if traveler.isVerified, let tid = traveler.travelerId {
            do {
                _ = try await traveler.forceRefresh(travelerId: tid)
                dlog("🔄 [validateSession] social JWT renovado en silencio")
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
        let (_, response) = try await session.data(for: req)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    /// Public so APIClient can call it on 401.
    /// Returns true if new tokens were obtained. Never wipes tokens on network error.
    ///
    /// Coalescer propio: este es el camino Supabase/OTP, distinto del secret
    /// device-bound de TravelerService. Son dos endpoints distintos, así que
    /// cada uno une sus propias llamadas concurrentes. No se llaman en ciclo
    /// (tryRefresh nunca invoca forceRefresh), así que no hay bloqueo mutuo.
    private let coalescer = RefreshCoalescer()

    func tryRefresh() async -> Bool {
        // RefreshCoalescer habla en String porque TravelerService devuelve el
        // token; aquí solo importa si hubo éxito, de ahí el mapeo a Bool.
        let result = try? await coalescer.run { [self] in
            let ok = await performTryRefresh()
            return ok ? "ok" : ""
        }
        return result == "ok"
    }

    private func performTryRefresh() async -> Bool {
        guard let refreshToken = store.string(.refreshToken),
              !refreshToken.isEmpty else {
            // No refresh token at all → session truly gone
            await MainActor.run {
                notifications.post(name: .sessionExpired, object: nil)
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
            let (data, response) = try await session.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0

            if status == 200,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                // Si el refresh devuelve OTRO usuario (sesiones cruzadas al
                // probar varias cuentas en el mismo dispositivo), no podemos
                // seguir con la UI del usuario anterior → re-login explícito.
                let previousId = defaults.string(forKey: "buddy.userId")
                if let id = json["user_id"] as? String,
                   let prev = previousId, !prev.isEmpty, prev != id {
                    print("🚨 refresh devolvió otro usuario (\(prev) → \(id)) — forzando re-login")
                    await MainActor.run {
                        notifications.post(name: .sessionExpired, object: nil)
                    }
                    return false
                }
                if let t  = json["access_token"]  as? String { store.set(t, .accessToken)  }
                if let rt = json["refresh_token"] as? String { store.set(rt, .refreshToken) }
                if let id = json["user_id"]       as? String { defaults.set(id, forKey: "buddy.userId")       }
                // Refresh response now includes Traveler identity — hydrate so
                // TravelerService.travelerId is always set after any auth lifecycle event.
                if let tid  = json["traveler_id"]    as? String,
                   let ttok = json["traveler_token"] as? String {
                    let tstatus = json["traveler_status"] as? String ?? "verified"
                    traveler.hydrate(travelerId: tid, token: ttok, status: tstatus)
                } else {
                    // Server returned no traveler identity — clear any stale traveler token
                    // so APIClient falls back to the Supabase token and doesn't loop.
                    print("⚠️ refresh returned no traveler_id — clearing stale traveler token")
                    store.remove(.travelerToken)
                    defaults.removeObject(forKey: "buddy.traveler.id")
                }
                dlog("🔄 session refreshed silently")
                return true
            } else {
                // Server rejected refresh token (truly invalid) → clear stale tokens
                // so APIClient falls back to anonKey instead of looping with a dead token.
                print("❌ refresh failed with status \(status) — clearing stale tokens")
                store.remove(.accessToken)
                store.remove(.refreshToken)
                await MainActor.run {
                    notifications.post(name: .sessionExpired, object: nil)
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
        payload["device_id"] = traveler.currentDeviceId

        let url = URL(string: "\(coreURL)/social")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = traveler.token {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: req)
        let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
        let bodyStr    = String(data: data, encoding: .utf8) ?? "empty"
        // Nunca loguear el cuerpo: trae traveler_token y secret de refresh.
        guard (200...299).contains(httpStatus) else {
            let errMsg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            print("[social/\(credential.provider.rawValue)] → \(httpStatus) error=\(errMsg ?? "sin detalle")")
            throw AuthError.sendFailed(bodyStr)
        }

        guard let json   = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tid    = json["traveler_id"]    as? String,
              let ttok   = json["traveler_token"] as? String,
              let rawSt  = json["status"]         as? String else {
            throw AuthError.sendFailed("Respuesta inesperada del servidor")
        }
        print("[social/\(credential.provider.rawValue)] → \(httpStatus) traveler_id=\(tid.prefix(8))… status=\(rawSt) secret=\(json["secret"] != nil ? "recibido" : "no")")

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
        guard let token = traveler.token else { throw AuthError.noSession }

        let url = URL(string: "\(coreURL)/profile")!
        var req = URLRequest(url: url)
        req.httpMethod = "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)",  forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["full_name": fullName])

        let (data, response) = try await session.data(for: req)
        let status  = (response as? HTTPURLResponse)?.statusCode ?? 0
        let bodyStr = String(data: data, encoding: .utf8) ?? "empty"
        dlog("👤 completeProfileSocial → status: \(status), body: \(bodyStr)")

        guard (200...299).contains(status) else { throw AuthError.sendFailed(bodyStr) }
        defaults.set(true, forKey: "buddy.onboardingDone")
    }

    // MARK: – Session helpers

    var accessToken: String? {
        store.string(.accessToken)
    }

    var userId: String? {
        defaults.string(forKey: "buddy.userId")
    }

    /// True si hay sesión Supabase activa (OTP) O identidad social verificada persistida.
    /// OJO: NO depende de la expiración del traveler JWT (vive 15 min) — la validez
    /// real la decide validateSession(), que renueva en silencio con el secret
    /// device-bound. Si dependiera del JWT, cualquier relanzamiento >15 min después
    /// del último uso mandaría al usuario al login (el bug de "la sesión murió").
    var isLoggedIn: Bool {
        if accessToken != nil { return true }
        return traveler.isVerified && traveler.travelerId != nil
    }

    // Decodifica el traveler JWT localmente y verifica que no haya expirado.
    // Para usuarios Apple/Google que no tienen access_token de Supabase.
    private func socialSessionValid() -> Bool {
        guard let token = traveler.token,
              traveler.status == "verified" else { return false }
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
        defaults.bool(forKey: "buddy.onboardingDone")
    }

    // MARK: – Sign out
    /// Cierra la sesión intencionalmente: elimina tokens y notifica a la app.
    /// Distinto de `.sessionExpired` (que es un error de token, no una acción del usuario).
    func signOut() {
        // Primero avisamos al servidor —y capturamos las credenciales antes de
        // borrarlas—: si no, la cuenta queda con is_available = true y el
        // waterfall la sigue eligiendo como buddy sin nadie dentro de la app.
        // Va en un Task aparte para que la limpieza local sea inmediata aunque
        // no haya red.
        if let travelerToken = traveler.token {
            let deviceId  = traveler.currentDeviceId
            let pushToken = defaults.string(forKey: "apns_device_token")
            let t = traveler
            Task.detached {
                await t.logoutRemote(
                    token: travelerToken, deviceId: deviceId, pushToken: pushToken
                )
            }
        }

        print("🚪 [AuthService.signOut] limpiando sesión OTP…")
        defaults.removeObject(forKey: "apns_device_token")
        store.remove(.accessToken)
        defaults.removeObject(forKey: "buddy.userId")
        store.remove(.refreshToken)
        defaults.set(false, forKey: "buddy.isLoggedIn")
        defaults.removeObject(forKey: "buddy.onboardingDone")
        defaults.removeObject(forKey: "buddy.device.id")
        print("🚪 [AuthService.signOut] limpiando sesión Traveler (UserDefaults + Keychain)…")
        traveler.clearSession()
        print("🚪 [AuthService.signOut] ✅ todo limpio — emitiendo userDidLogOut")
        notifications.post(name: .userDidLogOut, object: nil)
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
