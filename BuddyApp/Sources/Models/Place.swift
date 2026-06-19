import Foundation
import CoreLocation

struct Place: Identifiable, Codable {
    let id: UUID
    let name: String
    let description: String
    let stickerSymbol: String   // SF Symbol name
    let stickerEmoji: String
    var stickerImageUrl: String? = nil
    var stickerId: String? = nil     // sticker_catalog.id, used to match QR unlocks
    var isCollected: Bool = false    // true after QR scan or geofence unlock
    var isFavorite: Bool = false     // marcado por el usuario (sincroniza con backend)
    let category: Category
    let latitude: Double
    let longitude: Double
    let radiusMeters: Double
    var coverUrl: String?
    var featured: Bool = false   // top community pick → featured marker tier

    enum Category: String, Codable, CaseIterable {
        case cafe, nature, culture, market, viewpoint, hidden

        var label: String {
            switch self {
            case .cafe:      return "Café"
            case .nature:    return "Naturaleza"
            case .culture:   return "Cultura"
            case .market:    return "Mercado"
            case .viewpoint: return "Mirador"
            case .hidden:    return "Lugar secreto"
            }
        }
        var symbol: String {
            switch self {
            case .cafe:      return "cup.and.saucer"
            case .nature:    return "leaf"
            case .culture:   return "building.columns"
            case .market:    return "basket"
            case .viewpoint: return "mountain.2"
            case .hidden:    return "sparkles"
            }
        }
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
    var clLocation: CLLocation {
        CLLocation(latitude: latitude, longitude: longitude)
    }
}

extension Place {
    static func nearOrigin(_ origin: CLLocationCoordinate2D) -> [Place] {
        let data: [(String, String, String, Category, Double, Double)] = [
            ("Plaza Central",   "El corazón del pueblo, donde todo empieza.",
             "🏛️", .culture,    0.000, 0.000),
            ("Café Tunki",      "El mejor café de altura. Tostado a 1800 msnm.",
             "☕", .cafe,       0.002, 0.003),
            ("Mirador del Valle","Vista al volcán en días despejados.",
             "🌋", .viewpoint,  0.004, 0.005),
            ("La Catarata",     "Una cascada secreta a 40 minutos a pie.",
             "💧", .nature,     0.006, 0.007),
        ]
        return data.map { (name, desc, emoji, cat, dlat, dlon) in
            Place(
                id: UUID(),
                name: name,
                description: desc,
                stickerSymbol: cat.symbol,
                stickerEmoji: emoji,
                category: cat,
                latitude:  origin.latitude  + dlat,
                longitude: origin.longitude + dlon,
                radiusMeters: 80
            )
        }
    }

    static let villaRicaSamples: [Place] = nearOrigin(
        CLLocationCoordinate2D(latitude: -10.600, longitude: -75.348)
    )
}
