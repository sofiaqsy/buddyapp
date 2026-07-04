import Foundation

// MARK: – API Response Models
// These map 1:1 to buddy-core JSON responses (snake_case → camelCase via decoder)

// MARK: Location Resolution — POST /location/resolve
struct APILocationResolution: Decodable {
    let destinationId: String
    let destinationName: String
    let distanceMeters: Int
    let matchedBy: String  // "polygon" | "radius"
    let confidence: Double
}

// MARK: Buddy Coverage — sent to PATCH /buddy/me to declare where the buddy can help.
// The backend (DestinationService) is responsible for resolving coordinates and
// creating the destination if it doesn't exist yet. The client never manages
// destination_ids or active_zone_ids directly.

struct BuddyCoverageInput: Codable {
    let destinationId: String?   // non-nil when user picked an existing catalog destination
    let city: String
    let countryCode: String
    let latitude: Double?        // provided for new cities not yet in the catalog
    let longitude: Double?

    init(destinationId: String? = nil, city: String, countryCode: String,
         latitude: Double? = nil, longitude: Double? = nil) {
        self.destinationId = destinationId
        self.city          = city
        self.countryCode   = countryCode
        self.latitude      = latitude
        self.longitude     = longitude
    }

    init(from destination: APIDestination) {
        self.init(destinationId: destination.id,
                  city: destination.city,
                  countryCode: destination.country,
                  latitude: destination.lat,
                  longitude: destination.lng)
    }
}

// MARK: Place Search — resultado unificado de GET /search/places
// El cliente solo conoce "lugares". Un lugar puede tener más o menos capacidades.

struct APIPlaceResult: Decodable, Identifiable {
    let id: String
    let source: String   // "place" | "destination" | "nominatim"
    let title: String
    let subtitle: String?
    let lat: Double?
    let lng: Double?
}

// MARK: Resolved Place — POST /places/resolve (lugar geográfico, tabla `place`)

struct APIResolvedPlace: Decodable {
    let id: String
    let name: String
    let city: String?
    let country: String?
}

// MARK: Place Context — GET /places/:id/context

struct APIPlaceGuideSpot: Decodable, Identifiable {
    let id: String
    let name: String
    let lat: Double
    let lng: Double
    let coverUrl: String?

    var asPlace: Place {
        Place(
            id: UUID(uuidString: id) ?? UUID(),
            name: name,
            description: "",
            stickerSymbol: "mappin.circle.fill",
            stickerEmoji: "📍",
            category: .culture,
            latitude: lat,
            longitude: lng,
            radiusMeters: 50,
            coverUrl: coverUrl
        )
    }
}

struct APIPlaceGuide: Decodable {
    let spotCount: Int
    let visitCount: Int
    let stickerCount: Int
    let lat: Double?
    let lng: Double?
    let spots: [APIPlaceGuideSpot]?     // preview: hasta 50 spots para el mapa
    let hasMoreSpots: Bool?             // true si hay más de 50 spots en la guía
    let destId: String?                 // UUID del destination vinculado (para crear nuevos spots)
}

struct APIPlaceGuideSpotsPage: Decodable {
    let spots: [APIPlaceGuideSpot]
    let nextCursor: String?
    let hasMore: Bool
}

struct APIPlaceContext: Decodable {
    let buddies: Int
    let totalBuddies: Int
    let stories: Int
    let status: String   // "active" | "growing" | "busy" | "pioneer"
}

// MARK: Destination

struct APIDestination: Decodable, Identifiable {
    let id: String
    let name: String
    let city: String
    let country: String
    let lat: Double
    let lng: Double
    let radiusMeters: Int?
    let coverUrl: String?
    let active: Bool
    let places: [APIPlace]?
    let howToGetThere: String?
    let lodgingTips: String?
    let transportInfo: TransportInfo?
}

struct TransportInfo: Decodable {
    let bus: BusOption?
    let car: CarOption?
    let buddyHelp: Bool?

    struct BusOption: Decodable {
        let enabled: Bool
        let ticketUrl: String?
        let duration: String?
        let companies: [String]?
        let notes: String?
        enum CodingKeys: String, CodingKey {
            case enabled, duration, companies, notes
            case ticketUrl = "ticket_url"
        }
    }

    struct CarOption: Decodable {
        let enabled: Bool
        let routes: [CarRoute]?
        struct CarRoute: Decodable {
            let name: String
            let description: String
        }
    }

    enum CodingKeys: String, CodingKey {
        case bus, car
        case buddyHelp = "buddy_help"
    }
}

// MARK: Place

struct APIPlace: Decodable, Identifiable {
    let id: String
    let destinationId: String?
    let name: String
    let description: String?
    let placeType: String?
    let lat: Double
    let lng: Double
    let geofenceRadius: Int?
    let active: Bool?
    let coverUrl: String?
    let featured: Bool?
    let placeCategory: APIPlaceCategory?
    let stickerCatalog: [APIStickerCatalog]?

    // Convenience: map to existing Place model
    var asPlace: Place {
        Place(
            id: UUID(uuidString: id) ?? UUID(),
            name: name,
            description: description ?? "",
            stickerSymbol: placeCategory?.icon ?? "mappin.circle.fill",
            stickerEmoji: stickerCatalog?.first?.emoji ?? "",
            stickerImageUrl: stickerCatalog?.first?.imageUrl,
            stickerId: stickerCatalog?.first?.id,
            category: placeTypeToCategory(placeType ?? ""),
            latitude: lat,
            longitude: lng,
            radiusMeters: Double(geofenceRadius ?? 50),
            coverUrl: coverUrl,
            featured: featured ?? false
        )
    }
}

private func placeTypeToCategory(_ type: String) -> Place.Category {
    switch type {
    case "cafe":       return .cafe
    case "park":       return .nature
    case "landmark":   return .culture
    case "market":     return .market
    case "activity":   return .nature
    default:           return .culture
    }
}

struct APIPlaceCategory: Decodable {
    let name: String
    let icon: String?
}

// MARK: Sticker

struct APIStickerCatalog: Decodable, Identifiable {
    let id: String
    let name: String
    let emoji: String?
    let rarity: String
    let description: String?
    let imageUrl: String?
}

struct APIUserSticker: Decodable, Identifiable {
    let id: String
    let userId: String
    let stickerId: String
    let unlockedAt: Date
    let stickerCatalog: APIStickerCatalog?
}

// MARK: Journey

struct APIJourney: Decodable, Identifiable, Hashable {
    static func == (lhs: APIJourney, rhs: APIJourney) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    let id: String
    let userId: String?
    let title: String?
    let coverUrl: String?
    var status: String
    let isPublic: Bool?
    let likesCount: Int?
    let createdAt: Date?
    let arrivalAt: Date?
    let departureAt: Date?
    let destination: APIDestinationRef?
    let place: APIPlaceRef?               // para journeys GPS-only (sin destination)
    let users: APIUserRef?
    let journeyPlace: [APIJourneyPlace]?
    let buddyCount: Int?
    let destinationId: String?
    let placeId: String?         // para journeys GPS-only (sin destination)
    let tripId: String?          // contenedor: varios lugares = un viaje
    let knowsHowToGet: Bool?
    let hasLodging: Bool?
    // Agregados del feed "Historias de viajeros"
    let momentCount: Int?
    let placeCount: Int?
    let stickerCount: Int?
    let pageThumbs: [String]?   // portadas compuestas (para el collage del álbum)

    var daysUntilArrival: Int? {
        guard let date = arrivalAt else { return nil }
        return Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()), to: Calendar.current.startOfDay(for: date)).day
    }

    /// Duración del viaje en días (llegada → salida), si ambas existen
    var durationDays: Int? {
        guard let a = arrivalAt, let d = departureAt, d >= a else { return nil }
        let days = Calendar.current.dateComponents([.day],
            from: Calendar.current.startOfDay(for: a),
            to: Calendar.current.startOfDay(for: d)).day ?? 0
        return max(1, days)
    }

    func withStatus(_ newStatus: String) -> APIJourney {
        var copy = self; copy.status = newStatus; return copy
    }
}

struct APIDestinationRef: Decodable {
    let id: String?
    let name: String
    let city: String
    let coverUrl: String?
    var lat: Double? = nil
    var lng: Double? = nil
}

struct APIPlaceRef: Decodable {
    let id: String
    let name: String
    let city: String?
}

// Página del feed "Historias de viajeros" (cursor pagination)
struct FeedPage: Decodable {
    let items: [APIJourney]
    let nextCursor: String?
    let hasMore: Bool
}

// Ayuda recién completada (comunidad viva)
struct APIRecentHelp: Decodable, Identifiable {
    let id: String
    let completedAt: Date?
    let buddy: APIUserRef?
}

struct APIUserRef: Decodable {
    let id: String?
    let fullName: String?
    let avatarUrl: String?
}

struct APIJourneyPage: Decodable, Identifiable {
    let id: String
    let pageIndex: Int
    let thumbnailUrl: String
}

struct APIJourneyPlace: Decodable, Identifiable {
    let id: String
    let journeyId: String?
    let placeId: String?
    let collected: Bool
    let collectedAt: Date?
    let photoUrl: String?
    let note: String?
    let place: APIPlace?
}

// MARK: User

struct APIUser: Decodable, Identifiable {
    let id: String
    let fullName: String?
    var avatarUrl: String?
    let role: String?
    let nationality: String?
    let languages: [String]?
    var bio: String?
    let memberSince: Date?
    let buddyProfile: APIBuddyProfile?
}

struct APIBuddyProfile: Decodable {
    let destinationId: String?
    let specialties: [String]?
    let isAvailable: Bool
    let ratingAvg: Double?
    let ratingCount: Int?
    let totalHelps: Int?
    let destination: APIDestinationRef?
}

struct APIBuddyMe: Decodable {
    let isBuddy: Bool
    let profile: APIBuddyMeProfile?
}

struct APIBuddyMeProfile: Decodable {
    let id: String
    let isAvailable: Bool
    let specialties: [String]?
    let totalHelps: Int?
    let ratingAvg: Double?
    let ratingCount: Int?
    let offersAccepted: Int?
    let verificationStatus: String?
    let destinationIds: [String]?
    let activeZoneIds: [String]?
    let placeIds: [String]?
    let destination: APIDestinationRef?
}

// MARK: Matching

struct APIHelpRequest: Decodable, Identifiable {
    let id: String
    let travelerId: String
    let destinationId: String?
    let category: String
    let description: String?
    let arrivalAt: Date?
    let isActive: Bool
    let createdAt: Date?
    let users: APIUserRef?
}

struct APIMatch: Decodable, Identifiable {
    let id: String
    let requestId: String
    let travelerId: String
    let buddyId: String
    let status: String
    let matchedAt: Date?
    let completedAt: Date?
    let createdAt: Date?
    let traveler: APIUserRef?
    let buddy: APIUserRef?
    /// Anotado por el backend: ¿ya existe encuesta de cierre para este match?
    let feedbackSubmitted: Bool?
}

// MARK: Buddy Offer (matching_queue entry directed at this buddy)

struct APIBuddyOffer: Decodable, Identifiable {
    let id: String
    let requestId: String
    let helpRequest: OfferRequest?

    struct OfferRequest: Decodable {
        let id: String
        let category: String?
        let description: String?
        let arrivalAt: Date?
        let destination: APIDestinationRef?
        let users: APIUserRef?  // traveler
    }
}

// MARK: Matching Status (polling endpoint)

struct APIMatchingStatus: Decodable {
    let status: String      // "searching" | "matched" | "failed" | "cancelled" | "none"
    let position: Int?      // candidato actual (1-based), solo cuando searching
    let total: Int?         // total de candidatos, solo cuando searching
    let buddy: APIUserRef?  // solo cuando status == "matched"
}

// MARK: Message

struct APIMessage: Decodable, Identifiable {
    let id: String
    let matchId: String?
    let senderId: String?
    let type: String?
    let content: String?
    let audioUrl: String?
    let imageUrl: String?
    let readAt: Date?
    let createdAt: Date?
    let users: APIUserRef?
}
