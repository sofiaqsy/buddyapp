import Foundation

/// Dueño único de `/travelers/me/journeys`.
///
/// Inicio y Trips pedían los journeys por su cuenta: nueve peticiones en una
/// sesión, todas con la misma respuesta. El `.task` de Trips corre ocho veces
/// porque un TabView destruye y recrea la pestaña que no se ve — eso es
/// comportamiento normal de SwiftUI, no un bug de la vista. Lo que estaba mal
/// era que cada pantalla tratara el mismo estado del servidor como suyo.
///
/// Dos capas distintas, las dos necesarias:
/// - `APIClient` deduplica peticiones que se solapan EN EL TIEMPO.
/// - Este store evita volver a preguntar por algo que se acaba de traer.
///
/// Alcance deliberadamente mínimo: los datos, cuándo se trajeron, `load()`,
/// `refresh()` y una sola petición en vuelo. Sin persistencia, sin sincronía
/// en segundo plano, sin repositorio genérico.
@MainActor
final class JourneysStore: ObservableObject {
    static let shared = JourneysStore()

    @Published private(set) var journeys: [APIJourney] = []
    private(set) var lastFetchedAt: Date?

    /// Corta el rebote del `.task`, no el frescor real de un viaje. Ocho
    /// segundos: lo bastante para absorber una ráfaga de reapariciones, lo
    /// bastante poco para que un trip que cambia no se quede viejo en pantalla.
    private let freshness: TimeInterval = 8

    private var inFlight: Task<[APIJourney], Error>?

    private init() {}

    /// Respeta el frescor. Es lo que debe usar un `.task`: aparecer en pantalla
    /// no es motivo suficiente para ir al servidor.
    func load(trigger: String) async throws -> [APIJourney] {
        if let at = lastFetchedAt {
            let edad = Date().timeIntervalSince(at)
            if edad < freshness {
                print("📦 [JourneysStore] \(trigger) → reutilizo (\(String(format: "%.1f", edad))s, \(journeys.count) journey(s))")
                return journeys
            }
        }
        return try await fetch(trigger: trigger)
    }

    /// Salta el frescor a propósito. Es lo que debe usar un pull-to-refresh:
    /// ahí el usuario SÍ está pidiendo datos nuevos.
    func refresh(trigger: String) async throws -> [APIJourney] {
        try await fetch(trigger: "\(trigger)/force")
    }

    private func fetch(trigger: String) async throws -> [APIJourney] {
        if let inFlight {
            print("📦 [JourneysStore] \(trigger) → ya hay una carga en vuelo, me engancho")
            return try await inFlight.value
        }
        let task = Task { try await APIClient.shared.fetchTravelerJourneys() }
        inFlight = task
        do {
            let result = try await task.value
            inFlight = nil
            journeys = result
            lastFetchedAt = Date()
            return result
        } catch {
            // Se limpia pase lo que pase: una entrada viva tras un error dejaría
            // a todos enganchados para siempre a una tarea muerta.
            inFlight = nil
            throw error
        }
    }

    /// Logout: el siguiente `load()` tiene que ir al servidor con la identidad
    /// nueva, no devolver los journeys del anterior.
    func clear() {
        journeys = []
        lastFetchedAt = nil
        inFlight?.cancel()
        inFlight = nil
    }
}
