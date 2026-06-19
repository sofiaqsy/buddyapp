import Foundation
import CoreLocation

struct Route: Identifiable, Codable {
    let id: UUID
    let title: String
    let subtitle: String
    let city: String
    var places: [Place]
    var radiusMeters: Int?

    var collectedCount: Int { places.filter(\.isCollected).count }
    var isCompleted: Bool { collectedCount == places.count }
    var progress: Double {
        places.isEmpty ? 0 : Double(collectedCount) / Double(places.count)
    }
}


extension Route {
    static func villaRica(near origin: CLLocationCoordinate2D) -> Route {
        Route(
            id: UUID(),
            title: "villa rica",
            subtitle: "en la nube.",
            city: "Villa Rica, Pasco",
            places: Place.nearOrigin(origin)
        )
    }
    static var placeholder: Route {
        Route(id: UUID(), title: "villa rica", subtitle: "en la nube.", city: "...", places: [])
    }
}
