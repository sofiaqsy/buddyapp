import CoreLocation

// MARK: – LocationFilter
//
// Decide qué fixes del GPS son lo bastante buenos para mostrar distancias.
// La UI no debería saber nada de precisión ni de ruido: recibe una ubicación
// estable y listo.
enum LocationFilter {
    /// Peor precisión aceptable. En los logs del 2026-09-12, con precisión de
    /// ±16-19 m el GPS "movía" al viajero 10-14 m por fix estando casi quieto.
    static let maxAccuracy: CLLocationAccuracy = 20

    /// Acepta fixes de ±20 m o mejores. Mientras no haya NINGUNO aceptado se
    /// acepta cualquier fix válido: en interiores la precisión puede no bajar
    /// de 20 m nunca, y es peor no mostrar distancias que mostrarlas algo toscas.
    static func accept(_ loc: CLLocation, hasStable: Bool) -> Bool {
        guard loc.horizontalAccuracy >= 0 else { return false }   // negativo = inválido
        return loc.horizontalAccuracy <= maxAccuracy || !hasStable
    }
}

// MARK: – DistanceResolver
//
// Convierte ubicación + lugar en lo que ve el viajero, con la estabilidad
// necesaria para que la etiqueta no parpadee. Todo son funciones puras: no
// guardan estado, así que se pueden probar sin GPS ni vistas.
enum DistanceResolver {
    /// "Estás aquí" se enciende a 30 m y solo se apaga pasados 45 m. Entre
    /// ambos se mantiene lo que había: evita 29 → aquí, 32 → no, 28 → aquí
    /// con el viajero quieto en la puerta.
    static let hereEnter: Double = 30
    static let hereExit: Double = 45

    /// Un lugar solo le quita el puesto de "más cercano" al actual si está al
    /// menos 10 m más cerca. El encanto y Cafetería Rosal están a ~40 m entre
    /// sí; sin margen, el ruido del GPS los intercambiaba cada pocos segundos.
    static let nearestMargin: Double = 10

    static func distance(from loc: CLLocation?, to place: APIPlaceCard) -> Double? {
        guard let loc, let lat = place.lat, let lng = place.lng else { return nil }
        return loc.distance(from: CLLocation(latitude: lat, longitude: lng))
    }

    /// Cambio mínimo para actualizar la etiqueta, proporcional a la distancia.
    /// Un umbral fijo de 20 m se sentía lento cerca (a 25-30 m del lugar) y era
    /// inútil lejos. 15 % con piso de 5 m y techo de 50 m: a 30 m bastan 5 m,
    /// a 100 m hacen falta 15 m, y en kilómetros la etiqueta ya redondea sola.
    static func minChange(for shown: Double) -> Double {
        min(50, max(5, shown * 0.15))
    }

    static func shouldUpdate(shown: Double?, new: Double) -> Bool {
        guard let shown else { return true }
        return abs(new - shown) >= minChange(for: shown)
    }

    static func isHere(wasHere: Bool, distance: Double?, isNearest: Bool) -> Bool {
        guard isNearest, let d = distance else { return false }
        return wasHere ? d <= hereExit : d <= hereEnter
    }

    static func nearest(current: String?, candidates: [(id: String, distance: Double)]) -> String? {
        guard let best = candidates.min(by: { $0.distance < $1.distance }) else { return nil }
        guard let current, let actual = candidates.first(where: { $0.id == current }) else { return best.id }
        return best.distance < actual.distance - nearestMargin ? best.id : current
    }

    /// "120 m", "3,1 km", "236 km". Sin "Estás aquí": eso lo decide isHere.
    static func label(_ d: Double) -> String {
        if d < 1000 { return "\(max(10, Int((d / 10).rounded()) * 10)) m" }
        if d < 10_000 {
            let km = (d / 100).rounded() / 10
            return "\(String(format: "%.1f", km).replacingOccurrences(of: ".", with: ",")) km"
        }
        return "\(Int((d / 1000).rounded())) km"
    }

    /// Orden por cercanía que no baila con el ruido: agrupa en tramos de 10 m y,
    /// dentro del mismo tramo, conserva el orden que ya había.
    static func stableOrder(_ cards: [APIPlaceCard], from loc: CLLocation) -> [APIPlaceCard] {
        cards.enumerated()
            .map { (idx, card) -> (card: APIPlaceCard, bucket: Int, idx: Int) in
                let d = distance(from: loc, to: card)
                // Sin coordenadas: al final. Int.max y no un Double infinito,
                // que al convertirse a Int abortaría el proceso.
                let bucket = d.map { Int(($0 / 10).rounded(.down)) } ?? Int.max
                return (card, bucket, idx)
            }
            .sorted { $0.bucket != $1.bucket ? $0.bucket < $1.bucket : $0.idx < $1.idx }
            .map(\.card)
    }
}
