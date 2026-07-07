import Foundation

// MARK: – Contrato de respuesta del backend

enum AuthStatus: String, Decodable {
    case verified       = "verified"
    case needsProfile   = "needs_profile"
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AuthStatus(rawValue: raw) ?? .unknown
    }
}

struct AuthResult {
    let travelerId:    String
    let travelerToken: String
    let status:        AuthStatus
    let suggestedName: String?  // nombre que vino del proveedor (Apple/Google)
    /// Secret de refresh device-bound (nuevo en /auth/social). Permite renovar
    /// el JWT en silencio vía /travelers/refresh — la sesión no vuelve a expirar.
    var refreshSecret: String? = nil
}

// MARK: – Coordinador

/// Recibe un AuthResult de AuthService, hidrata la sesión y decide a qué pantalla ir.
/// La UI observa `destination` y reacciona — nunca decide sola.
enum AuthDestination {
    case home
    case needsProfileCompletion
}

final class AuthCoordinator {
    static let shared = AuthCoordinator()
    private init() {}

    /// Hidrata TravelerService y devuelve el destino de navegación.
    /// AuthService llama esto; la vista solo consume el resultado.
    func handle(_ result: AuthResult) -> AuthDestination {
        TravelerService.shared.hydrate(
            travelerId: result.travelerId,
            token:      result.travelerToken,
            status:     result.status.rawValue,
            secret:     result.refreshSecret
        )
        switch result.status {
        case .verified:
            UserDefaults.standard.set(true, forKey: "buddy.onboardingDone")
            return .home
        case .needsProfile, .unknown:
            return .needsProfileCompletion
        }
    }
}
