import Foundation
import CoreLocation

struct Destination: Identifiable, Codable {
    let id: UUID
    let name: String
    let country: String
    let region: String
    let tagline: String
    let latitude: Double
    let longitude: Double
    var places: [Place]

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
    var fullName: String { "\(name), \(country)" }
}

struct DestinationVisit: Identifiable, Codable {
    let id: UUID
    var destination: Destination
    var arrivalDate: Date?
    var departureDate: Date?
    var status: VisitStatus
    var collectedPlaceIDs: [UUID]
    var hostID: UUID?

    enum VisitStatus: String, Codable {
        case upcoming, active, completed
    }

    var collectedCount: Int { collectedPlaceIDs.count }
    var totalPlaces: Int { destination.places.count }
    var progress: Double {
        guard totalPlaces > 0 else { return 0 }
        return Double(collectedCount) / Double(totalPlaces)
    }

    var isCollected: (Place) -> Bool {{ place in
        self.collectedPlaceIDs.contains(place.id)
    }}
}

extension Destination {
    static let villaRica = Destination(
        id: UUID(),
        name: "Villa Rica",
        country: "Perú",
        region: "Pasco",
        tagline: "en la nube.",
        latitude: -10.600,
        longitude: -75.348,
        places: Place.villaRicaSamples
    )
}
