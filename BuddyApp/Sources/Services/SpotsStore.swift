import SwiftUI
import CoreLocation

// MARK: – SpotsStore
//
// Dueño único de la lista de spots del Home. Existe por tres problemas vistos
// en los logs del 2026-09-12:
//
// 1. Dos peticiones idénticas al arrancar (loadData y el primer fix del GPS)
//    en el mismo segundo. Aquí se unen en una.
// 2. Un timeout vaciaba el carrusel: loadData hacía `(try? await …) ?? []` y
//    ese [] reemplazaba la lista buena. Aquí un fallo conserva lo que había.
// 3. Al abrir la app no había nada hasta que respondía el backend. Aquí se
//    pinta la última lista guardada al instante y se refresca detrás.
@MainActor
final class SpotsStore: ObservableObject {
    static let shared = SpotsStore()

    @Published private(set) var spots: [APIPlaceCard] = []
    /// Lugar más cercano con margen (DistanceResolver.nearest), para que solo
    /// una card diga "Estás aquí" y no cambie con cada rebote del GPS.
    @Published private(set) var nearestId: String?

    private var inFlight: Task<Void, Never>?
    private var inFlightCoords: CLLocation?
    /// Cada petición nueva sube la generación; una respuesta de una generación
    /// anterior se descarta para no pisar datos más frescos.
    private var generation = 0
    /// Dos peticiones dentro de este radio se consideran la misma.
    private static let coalesceMeters: CLLocationDistance = 150

    private init() {
        spots = Self.loadCache()
        print("🗂️ [spots] cache al arrancar → \(spots.count) spot(s)")
    }

    func refresh(lat: Double?, lng: Double?, reason: String) async {
        let coords = lat.flatMap { la in lng.map { CLLocation(latitude: la, longitude: $0) } }

        if let inFlight, Self.equivalent(inFlightCoords, coords) {
            print("🗂️ [spots] \(reason): ya hay una petición equivalente en vuelo — me engancho")
            await inFlight.value
            return
        }

        generation += 1
        let gen = generation
        inFlightCoords = coords
        let task = Task { [weak self] in
            do {
                let cards = try await APIClient.shared.fetchPlaceCards(lat: lat, lng: lng)
                guard let self else { return }
                guard gen == self.generation else {
                    print("🗂️ [spots] \(reason): respuesta superada por una petición más nueva — descartada")
                    return
                }
                withAnimation(.easeInOut(duration: 0.25)) { self.spots = cards }
                Self.saveCache(cards)
                print("🗂️ [spots] \(reason): \(cards.count) spot(s) — guardados en cache")
            } catch {
                guard let self else { return }
                print("🗂️ [spots] \(reason): falló (\(error.localizedDescription)) — conservo \(self.spots.count) spot(s)")
            }
        }
        inFlight = task
        await task.value
        if gen == generation {
            inFlight = nil
            inFlightCoords = nil
        }
    }

    /// Reordena y recalcula el más cercano con una ubicación YA filtrada.
    func reorder(from loc: CLLocation) {
        let ordenados = DistanceResolver.stableOrder(spots, from: loc)
        if ordenados.map(\.id) != spots.map(\.id) {
            print("🗂️ [spots] nuevo orden: \(ordenados.prefix(3).map(\.name).joined(separator: " · "))")
            withAnimation(.easeInOut(duration: 0.25)) { spots = ordenados }
        }
        let candidatos = spots.compactMap { card -> (id: String, distance: Double)? in
            DistanceResolver.distance(from: loc, to: card).map { (card.id, $0) }
        }
        let nuevo = DistanceResolver.nearest(current: nearestId, candidates: candidatos)
        if nuevo != nearestId {
            print("🗂️ [spots] más cercano: \(spots.first { $0.id == nuevo }?.name ?? "ninguno")")
            nearestId = nuevo
        }
    }

    // MARK: – Cache en disco

    private static var cacheURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("spots-cache.json")
    }

    /// JSONEncoder/Decoder planos (sin snake_case): el cache se lee con las
    /// mismas claves con las que se escribe.
    private static func saveCache(_ cards: [APIPlaceCard]) {
        guard let url = cacheURL, let data = try? JSONEncoder().encode(cards) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func loadCache() -> [APIPlaceCard] {
        guard let url = cacheURL, let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([APIPlaceCard].self, from: data)) ?? []
    }

    private static func equivalent(_ a: CLLocation?, _ b: CLLocation?) -> Bool {
        switch (a, b) {
        case (nil, nil):          return true
        case let (a?, b?):        return a.distance(from: b) < coalesceMeters
        default:                  return false
        }
    }
}
