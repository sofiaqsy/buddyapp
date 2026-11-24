import Foundation
import AuthenticationServices
import GoogleSignIn
import UIKit
import CryptoKit

// MARK: – Credencial unificada que producen todos los proveedores

struct IdentityCredential {
    enum Provider: String { case apple, google }
    let provider:      Provider
    let identityToken: String          // JWT firmado por Apple / Google
    let email:         String?
    let fullName:      String?         // nil si el proveedor no lo envía
}

// MARK: – Protocolo

protocol IdentityProvider {
    func signIn() async throws -> IdentityCredential
}

// MARK: – Apple

final class AppleProvider: NSObject, IdentityProvider,
    ASAuthorizationControllerDelegate,
    ASAuthorizationControllerPresentationContextProviding
{
    private var continuation: CheckedContinuation<IdentityCredential, Error>?
    /// Nonce en claro para el inicio de sesión en Firebase (fincas). Apple
    /// recibe su SHA-256; Firebase recibe el nonce en claro y compara.
    var rawNonce: String? = nil

    func signIn() async throws -> IdentityCredential {
        try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            let provider = ASAuthorizationAppleIDProvider()
            let request  = provider.createRequest()
            request.requestedScopes = [.fullName, .email]
            if let raw = rawNonce {
                request.nonce = SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
            }
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate                    = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        UIApplication.shared
            .connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first ?? UIWindow()
    }

    func authorizationController(controller: ASAuthorizationController,
                                 didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let cred = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = cred.identityToken,
              let token = String(data: tokenData, encoding: .utf8) else {
            continuation?.resume(throwing: AuthError.sendFailed("No se pudo leer el identity token de Apple"))
            return
        }
        var name: String? = nil
        if let fn = cred.fullName {
            let joined = [fn.givenName, fn.familyName]
                .compactMap { $0 }.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !joined.isEmpty { name = joined }
        }
        continuation?.resume(returning: IdentityCredential(
            provider:      .apple,
            identityToken: token,
            email:         cred.email,
            fullName:      name
        ))
    }

    func authorizationController(controller: ASAuthorizationController,
                                 didCompleteWithError error: Error) {
        continuation?.resume(throwing: error)
    }
}

// MARK: – Google

final class GoogleProvider: IdentityProvider {
    func signIn() async throws -> IdentityCredential {
        // GIDSignIn must run on the main thread (UIKit requirement)
        let result: GIDSignInResult = try await withCheckedThrowingContinuation { cont in
            Task { @MainActor in
                guard let rootVC = UIApplication.shared
                    .connectedScenes
                    .compactMap({ $0 as? UIWindowScene })
                    .first?.windows.first?.rootViewController
                else {
                    cont.resume(throwing: AuthError.sendFailed("No hay ventana activa para presentar Google Sign In"))
                    return
                }
                do {
                    let r = try await GIDSignIn.sharedInstance.signIn(withPresenting: rootVC)
                    cont.resume(returning: r)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
        guard let idToken = result.user.idToken?.tokenString else {
            throw AuthError.sendFailed("Google no devolvió un id_token")
        }
        let profile  = result.user.profile
        let fullName = [profile?.givenName, profile?.familyName]
            .compactMap { $0 }.joined(separator: " ").trimmingCharacters(in: .whitespaces)

        return IdentityCredential(
            provider:      .google,
            identityToken: idToken,
            email:         profile?.email,
            fullName:      fullName.isEmpty ? nil : fullName
        )
    }
}


// MARK: – Google URL callback (AppDelegate delegate)

extension AppDelegate {
    func application(_ app: UIApplication, open url: URL,
                     options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        GIDSignIn.sharedInstance.handle(url)
    }
}


// MARK: – Login de fincas (Firebase apartalo-10146), ADR-001
//
// Solo para dueños de negocio: Buddy sigue con su propio login de viajero.
// Se usa la API REST de Firebase Auth (signInWithIdp) con la misma cuenta de
// Apple o Google, sin el SDK de Firebase. La API key es la del app iOS de
// Buddy registrado en apartalo-10146 (GoogleService-Info.plist, 20 Nov 2026);
// es una clave de cliente, pública por diseño, limitada al bundle de Buddy.

enum FincasAuth {
    static let apiKey   = "AIzaSyB56rWRNjX2OfMg9P6OFtAaynBazX8N3tc"
    static let bundleId = "com.vrcoffe.buddyapp"
    static let fincasBase = "https://apartalo-core-9d633cdb9e1a.herokuapp.com"

    struct Session { let idToken: String; let refreshToken: String; let uid: String }

    struct Business: Decodable, Identifiable, Hashable {
        let businessId: String?
        let farmId: String?
        let name: String
        let role: String?
        var id: String { farmId ?? businessId ?? name }
    }
    struct SessionAnswer: Decodable {
        let status: String
        let businesses: [Business]?
        let businessName: String?
    }

    enum FincasError: LocalizedError {
        case signIn(String), server(String)
        var errorDescription: String? {
            switch self { case .signIn(let m), .server(let m): return m }
        }
    }

    /// Inicia sesión en Firebase de fincas con Apple o Google.
    static func signIn(with provider: IdentityCredential.Provider) async throws -> Session {
        var postBody: String
        switch provider {
        case .apple:
            let raw = UUID().uuidString + UUID().uuidString
            let apple = AppleProvider()
            apple.rawNonce = raw
            let cred = try await apple.signIn()
            postBody = "id_token=\(cred.identityToken)&providerId=apple.com&nonce=\(raw)"
        case .google:
            let cred = try await GoogleProvider().signIn()
            postBody = "id_token=\(cred.identityToken)&providerId=google.com"
        }
        var req = URLRequest(url: URL(string: "https://identitytoolkit.googleapis.com/v1/accounts:signInWithIdp?key=\(apiKey)")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(bundleId, forHTTPHeaderField: "X-Ios-Bundle-Identifier")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "postBody": postBody, "requestUri": "http://localhost",
            "returnSecureToken": true, "returnIdpCredential": true,
        ])
        let (data, resp) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let idToken = json["idToken"] as? String,
              let refresh = json["refreshToken"] as? String,
              let uid = json["localId"] as? String else {
            let msg = ((json["error"] as? [String: Any])?["message"] as? String) ?? "sin detalle"
            dlog("🏪 [FincasAuth] signInWithIdp falló: \(msg)")
            throw FincasError.signIn("No pudimos iniciar sesión (\(msg)).")
        }
        return Session(idToken: idToken, refreshToken: refresh, uid: uid)
    }

    /// Pide crear un negocio (queda "pendiente" hasta que un admin lo apruebe).
    /// Una persona solo puede tener una solicitud pendiente a la vez.
    static func requestBusiness(idToken: String, name: String, city: String, phone: String?) async throws {
        var req = URLRequest(url: URL(string: fincasBase + "/api/auth/business-requests")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: String] = ["name": name, "city": city]
        if let phone, !phone.isEmpty { body["phone"] = phone }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let msg = (json?["error"] as? String) ?? "No pudimos enviar la solicitud (\(code)). Intenta de nuevo."
            if code == 401 { throw FincasError.signIn("Tu sesión venció. Vuelve a entrar con tu cuenta.") }
            throw FincasError.server(msg)
        }
    }

    /// Pregunta a fincas qué negocios tiene esta persona (no crea nada).
    static func session(idToken: String) async throws -> SessionAnswer {
        var req = URLRequest(url: URL(string: fincasBase + "/api/auth/session")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 30   // el servidor de fincas puede estar dormido
        req.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("{}".utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw FincasError.server("El servidor respondió \(code). Intenta de nuevo.") }
        return try JSONDecoder().decode(SessionAnswer.self, from: data)
    }
}


// MARK: – Sesión de fincas guardada (token que se renueva solo)
// El refresh token va en el Llavero; el ID token (1 h) solo en memoria.
extension FincasAuth {
    private static let keychainAccount = "fincas.refreshToken"
    private static var cachedIdToken: String? = nil
    private static var cachedExpiry: Date = .distantPast

    static func save(_ session: Session) {
        cachedIdToken = session.idToken
        cachedExpiry = Date().addingTimeInterval(55 * 60)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrAccount as String: keychainAccount]
        SecItemDelete(q as CFDictionary)
        var add = q
        add[kSecValueData as String] = Data(session.refreshToken.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func clear() {
        cachedIdToken = nil
        cachedExpiry = .distantPast
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrAccount as String: keychainAccount] as CFDictionary)
    }

    /// Hay una sesión de Apartalo guardada en este teléfono.
    static var hasSavedSession: Bool { storedRefreshToken() != nil }

    private static func storedRefreshToken() -> String? {
        var out: AnyObject?
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrAccount as String: keychainAccount,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    /// ID token válido; lo renueva con el refresh token si hace falta.
    static func validIdToken() async throws -> String {
        if let t = cachedIdToken, cachedExpiry > Date() { return t }
        guard let refresh = storedRefreshToken() else {
            throw FincasError.signIn("Vuelve a entrar con tu cuenta.")
        }
        var req = URLRequest(url: URL(string: "https://securetoken.googleapis.com/v1/token?key=\(apiKey)")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue(bundleId, forHTTPHeaderField: "X-Ios-Bundle-Identifier")
        req.httpBody = Data("grant_type=refresh_token&refresh_token=\(refresh)".utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let id = json["id_token"] as? String,
              let newRefresh = json["refresh_token"] as? String else {
            throw FincasError.signIn("Tu sesión venció. Vuelve a entrar.")
        }
        save(Session(idToken: id, refreshToken: newRefresh, uid: (json["user_id"] as? String) ?? ""))
        return id
    }
}

// MARK: – Products API de fincas (dueños y staff), ver buddy-architect/fincas-products-api.md
struct FincasProduct: Decodable, Identifiable, Hashable {
    struct Photo: Decodable, Hashable { let id: String; let url: String }
    struct Presentation: Decodable, Identifiable, Hashable {
        let id: String
        let packSize: Double?
        let unit: String?
        let price: Double?
        let stock: Int?
        let visible: Bool?
        let photos: [Photo]?
        /// Lectura pública: una foto por presentación.
        var photoUrl: String? = nil
        var label: String {
            let size = packSize.map { $0.truncatingRemainder(dividingBy: 1) == 0 ? String(Int($0)) : String($0) } ?? ""
            return [size, unit ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
        }
    }
    let id: String
    let name: String
    let description: String?
    let status: String?
    let imageUrl: String?
    /// Lectura pública de Apartalo (R5) manda la foto como photoUrl.
    var photoUrl: String? = nil
    let presentations: [Presentation]?

    /// Foto para mostrar: la del producto, o la primera que tenga cualquiera
    /// de sus presentaciones (Keyla, 20 Nov 2026).
    var coverUrl: String? {
        if let u = imageUrl ?? photoUrl, !u.isEmpty { return u }
        for pr in presentations ?? [] {
            if let u = pr.photos?.first?.url ?? pr.photoUrl, !u.isEmpty { return u }
        }
        return nil
    }
}
struct FincasProductPage: Decodable {
    let items: [FincasProduct]
    let total: Int?
    let hasMore: Bool?
}

extension FincasAuth {
    static func products(farmId: String, offset: Int = 0, limit: Int = 20) async throws -> FincasProductPage {
        let token = try await validIdToken()
        var req = URLRequest(url: URL(string: "\(fincasBase)/api/v1/farms/\(farmId)/products?offset=\(offset)&limit=\(limit)")!)
        req.timeoutInterval = 30
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            dlog("🏪 [FincasProducts] \(code) \(String(data: data, encoding: .utf8)?.prefix(200) ?? "")")
            switch code {
            case 401: throw FincasError.signIn("Tu sesión venció. Vuelve a entrar.")
            case 403: throw FincasError.server("No eres miembro de este negocio.")
            case 429: throw FincasError.server("Demasiadas consultas. Espera un minuto.")
            default:  throw FincasError.server("El servidor respondió \(code). Intenta de nuevo.")
            }
        }
        return try JSONDecoder().decode(FincasProductPage.self, from: data)
    }
}


// MARK: – Escritura de productos en fincas (dueños y staff)
extension Notification.Name {
    static let fincasProductsChanged = Notification.Name("fincasProductsChanged")
}

extension FincasAuth {
    /// Llamada autenticada con Idempotency-Key (obligatoria en POST; se manda en todas las escrituras).
    @discardableResult
    /// Arma la petición de escritura (separada para poder probarla).
    static func writeRequest(_ method: String, _ path: String, body: [String: Any], key: String, token: String) throws -> URLRequest {
        var req = URLRequest(url: URL(string: fincasBase + path)!)
        req.httpMethod = method
        req.timeoutInterval = 30
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "Idempotency-Key")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    static func write(_ method: String, _ path: String, body: [String: Any], key: String = UUID().uuidString) async throws -> [String: Any] {
        let token = try await validIdToken()
        let req = try writeRequest(method, path, body: body, key: key, token: token)
        // Un reintento con la MISMA llave si el servidor estaba dormido o falló la red.
        for intento in 0..<2 {
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
                if code == 503, intento == 0 { continue }
                guard (200...299).contains(code) else {
                    let field = json["field"] as? String
                    let msg = (json["error"] as? String) ?? "El servidor respondió \(code)."
                    dlog("🏪 [FincasWrite] \(method) \(path) → \(code) \(msg)")
                    switch code {
                    case 401: throw FincasError.signIn("Tu sesión venció. Vuelve a entrar.")
                    case 403: throw FincasError.server("No eres miembro de este negocio.")
                    case 429: throw FincasError.server("Demasiados cambios seguidos. Espera un minuto.")
                    case 400: throw FincasError.server(field.map { "Revisa el campo \($0): \(msg)" } ?? msg)
                    default:  throw FincasError.server(msg)
                    }
                }
                return json
            } catch let e as URLError where intento == 0 && e.code != .cancelled {
                continue
            }
        }
        throw FincasError.server("No pudimos conectar. Intenta de nuevo.")
    }

    static func updateProduct(farmId: String, productId: String, fields: [String: Any]) async throws {
        try await write("PATCH", "/api/v1/farms/\(farmId)/products/\(productId)", body: fields)
    }
    static func updatePresentation(farmId: String, productId: String, presentationId: String, fields: [String: Any]) async throws {
        try await write("PATCH", "/api/v1/farms/\(farmId)/products/\(productId)/presentations/\(presentationId)", body: fields)
    }
    static func createProduct(farmId: String, name: String, description: String, key: String) async throws -> String {
        let json = try await write("POST", "/api/v1/farms/\(farmId)/products", body: ["name": name, "description": description], key: key)
        guard let id = json["id"] as? String else { throw FincasError.server("No recibimos el producto creado. Revisa la lista.") }
        return id
    }
    /// Lectura pública (sin sesión): trae la foto de cada presentación aunque la
    /// lista del dueño no la incluya (pasa con fotos subidas desde otra app).
    static func publicProducts(farmId: String) async throws -> [FincasProduct] {
        var req = URLRequest(url: URL(string: "\(fincasBase)/api/public/farms/\(farmId)/products?offset=0&limit=50")!)
        req.timeoutInterval = 30
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        return (try? JSONDecoder().decode(FincasProductPage.self, from: data).items) ?? []
    }

    /// Foto de una presentación (máx. 3): pedir URL firmada, subir los bytes, registrar.
    static func uploadPresentationPhoto(farmId: String, productId: String, presentationId: String,
                                        jpeg: Data, key: String) async throws -> (id: String?, url: String) {
        let base = "/api/v1/farms/\(farmId)/products/\(productId)/presentations/\(presentationId)/photos"
        let signed = try await write("POST", base + "/sign", body: ["mimeType": "image/jpeg"])
        guard let urlString = signed["signedUrl"] as? String, let url = URL(string: urlString),
              let path = signed["path"] as? String else {
            throw FincasError.server("No pudimos preparar la subida de la foto.")
        }
        var put = URLRequest(url: url)
        put.httpMethod = "PUT"
        put.timeoutInterval = 60
        put.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        let (_, resp) = try await URLSession.shared.upload(for: put, from: jpeg)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(code) else { throw FincasError.server("No pudimos subir la foto (\(code)).") }
        let reg = try await write("POST", base, body: ["path": path, "mimeType": "image/jpeg"], key: key)
        return (reg["id"] as? String, (reg["url"] as? String) ?? "")
    }

    /// Quita una foto equivocada de una presentación (fincas, 23 Nov 2026).
    static func deletePresentationPhoto(farmId: String, productId: String, presentationId: String, photoId: String) async throws {
        try await write("DELETE", "/api/v1/farms/\(farmId)/products/\(productId)/presentations/\(presentationId)/photos/\(photoId)", body: [:])
    }
    /// "Quitar producto": se archiva (nada se borra) y queda como "Oculto" para poder volver.
    static func archiveProduct(farmId: String, productId: String) async throws {
        try await updateProduct(farmId: farmId, productId: productId, fields: ["status": "archived"])
    }

    @discardableResult
    static func createPresentation(farmId: String, productId: String, fields: [String: Any], key: String) async throws -> String? {
        let json = try await write("POST", "/api/v1/farms/\(farmId)/products/\(productId)/presentations", body: fields, key: key)
        return json["id"] as? String
    }
}
