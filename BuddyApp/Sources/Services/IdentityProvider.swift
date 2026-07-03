import Foundation
import AuthenticationServices
import GoogleSignIn
import UIKit

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

    func signIn() async throws -> IdentityCredential {
        try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            let provider = ASAuthorizationAppleIDProvider()
            let request  = provider.createRequest()
            request.requestedScopes = [.fullName, .email]
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
        guard let rootVC = await MainActor.run(body: {
            UIApplication.shared
                .connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first?.windows.first?.rootViewController
        }) else {
            throw AuthError.sendFailed("No hay ventana activa para presentar Google Sign In")
        }

        let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: rootVC)
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
