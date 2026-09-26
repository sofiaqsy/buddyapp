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
/// `refresh()` y una sola petición en vuelo. Sin sincronía en segundo plano
/// ni repositorio genérico.
///
/// Una sola persistencia: la ÚLTIMA respuesta cruda, en disco y por traveler.
/// Sirve para dibujar el Home al instante en el arranque (stale-while-
/// revalidate) mientras la red confirma; nunca reemplaza al servidor.
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
                dlog("📦 [JourneysStore] \(trigger) → reutilizo (\(String(format: "%.1f", edad))s, \(journeys.count) journey(s))")
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
            dlog("📦 [JourneysStore] \(trigger) → ya hay una carga en vuelo, me engancho")
            return try await inFlight.value
        }
        let dueno = Session.travelerId
        let task = Task {
            try await APIClient.shared.fetchTravelerJourneys(rawSink: { data in
                JourneysStore.guardarEnDisco(data, travelerId: dueno)
            })
        }
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

    // MARK: – Cache en disco (solo para el arranque)

    nonisolated private static func archivo(travelerId: String) -> URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true) else { return nil }
        return base.appendingPathComponent("journeys-\(travelerId).json")
    }

    nonisolated fileprivate static func guardarEnDisco(_ data: Data, travelerId: String?) {
        guard let travelerId, let url = archivo(travelerId: travelerId) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtection])
    }

    /// Los journeys de la última sesión de ESTE traveler, o nil. Solo los lee
    /// quien va a dibujar antes de que responda la red; el dato puede estar
    /// viejo y la red siempre lo corrige.
    func desdeDisco() -> [APIJourney]? {
        guard let tid = Session.travelerId,
              let url = Self.archivo(travelerId: tid),
              let data = try? Data(contentsOf: url),
              let lista = try? JSONDecoder.buddy.decode([APIJourney].self, from: data)
        else { return nil }
        return lista
    }

    /// Logout: el siguiente `load()` tiene que ir al servidor con la identidad
    /// nueva, no devolver los journeys del anterior.
    func clear() {
        // En el logout la sesión puede estar ya borrada: no se puede confiar en
        // Session.travelerId para saber cuál archivo tocar. Se borran todos.
        if let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false),
           let nombres = try? FileManager.default.contentsOfDirectory(atPath: base.path) {
            for n in nombres where n.hasPrefix("journeys-") && n.hasSuffix(".json") {
                try? FileManager.default.removeItem(at: base.appendingPathComponent(n))
            }
        }
        journeys = []
        lastFetchedAt = nil
        inFlight?.cancel()
        inFlight = nil
    }
}
