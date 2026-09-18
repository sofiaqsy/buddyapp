import Foundation

/// Dueño único de `/matching/matches`.
///
/// Cuatro pantallas pedían los matches por su cuenta: once llamadas y ocho
/// peticiones HTTP en una sola sesión. Mismo patrón que los journeys y misma
/// solución, con una diferencia importante: un match SÍ cambia mientras el
/// usuario mira. Por eso la ventana es corta y el camino de espera activa
/// nunca lee del snapshot.
///
/// LÍMITE DE RESPONSABILIDAD
/// Este store trae datos y nada más. Qué cuenta como match válido, cuándo se
/// pasa al chat, cuándo se cancela la espera — todo eso sigue viviendo en
/// ContactarBuddyView, que es de quien es el flujo. El store dice "estos son
/// los matches de ahora"; la vista decide qué significa eso.
@MainActor
final class MatchingStore: ObservableObject {
    static let shared = MatchingStore()

    @Published private(set) var matches: [APIMatch] = []
    private(set) var lastFetchedAt: Date?

    /// Tres segundos, no ocho como en journeys: esto es el emparejamiento con
    /// un buddy. Alcanza para absorber el rebote del `.task` de una pestaña y
    /// es poco para que una pantalla normal muestre algo viejo.
    private let freshness: TimeInterval = 3

    private var inFlight: Task<[APIMatch], Error>?

    private init() {}

    /// Para pantallas que MUESTRAN matches. Reutiliza el snapshot si es reciente.
    func load(trigger: String) async throws -> [APIMatch] {
        if let at = lastFetchedAt {
            let edad = Date().timeIntervalSince(at)
            if edad < freshness {
                print("🤝 [MatchingStore] \(trigger) → reutilizo (\(String(format: "%.1f", edad))s, \(matches.count) match(es))")
                return matches
            }
        }
        return try await fetch(trigger: trigger)
    }

    /// Para quien ESPERA un buddy. Siempre va al servidor: un sondeo que
    /// devuelve el snapshot no es un sondeo. Sigue protegido contra llamadas
    /// solapadas — dos refresh a la vez son una sola petición, no dos.
    func refresh(trigger: String) async throws -> [APIMatch] {
        try await fetch(trigger: "\(trigger)/force")
    }

    private func fetch(trigger: String) async throws -> [APIMatch] {
        if let inFlight {
            print("🤝 [MatchingStore] \(trigger) → ya hay una carga en vuelo, me engancho")
            return try await inFlight.value
        }
        let task = Task { try await APIClient.shared.fetchMatches() }
        inFlight = task
        do {
            let result = try await task.value
            inFlight = nil
            matches = result
            lastFetchedAt = Date()
            return result
        } catch {
            inFlight = nil
            throw error
        }
    }

    /// Logout: la cuenta siguiente no puede ver los matches de la anterior.
    func clear() {
        matches = []
        lastFetchedAt = nil
        inFlight?.cancel()
        inFlight = nil
    }
}
