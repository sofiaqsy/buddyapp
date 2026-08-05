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
    let destinationId: String?

    enum CodingKeys: String, CodingKey {
        case id, name, city, country
        case destinationId = "destination_id"
    }
}

// MARK: Place Context — GET /places/:id/context

struct APIPlaceGuideSpot: Decodable, Identifiable {
    let id: String
    let name: String
    let lat: Double
    let lng: Double
    let coverUrl: String?
    /// `var` con default para que los tres sitios que rehacen un spot tras
    /// editarlo en el mapa no tengan que pasarlo; Decodable lo sigue leyendo.
    var placeCategory: APIPlaceCategory? = nil

    var asPlace: Place {
        Place(
            id: UUID(uuidString: id) ?? UUID(),
            name: name,
            description: "",
            stickerSymbol: placeCategory?.icon ?? "mappin.circle.fill",
            stickerEmoji: "📍",
            // .hidden y no .culture: por esta vía nunca hubo dato de categoría,
            // así que decir "Cultura" era inventarlo. La categoría de verdad
            // viaja en categoryName, que ahora sí llega.
            category: .hidden,
            categoryName: placeCategory?.name,
            categoryIcon: placeCategory?.icon,
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
            categoryName: placeCategory?.name,
            categoryIcon: placeCategory?.icon,
            latitude: lat,
            longitude: lng,
            radiusMeters: Double(geofenceRadius ?? 50),
            coverUrl: coverUrl,
            featured: featured ?? false
        )
    }
}

/// `place_type` → el enum viejo de seis casos.
///
/// El `default` era `.culture`, y eso es lo que hacía que "El encanto" —un
/// hotel— se anunciara como "Cultura": su place_type es 'other', que no está
/// contemplado, y la rama por defecto inventaba una categoría en vez de admitir
/// que no la sabe. Hoy 10 de los 14 spots son 'other', así que la mayoría del
/// catálogo salía etiquetado igual de mal.
///
/// Ahora cae en `.hidden`, que es el único caso del enum que no afirma nada
/// sobre qué es el lugar. La categoría de verdad viaja aparte, en
/// `Place.categoryName`, y sale de `spot_category`.
private func placeTypeToCategory(_ type: String) -> Place.Category {
    switch type {
    case "cafe":       return .cafe
    case "park":       return .nature
    case "landmark":   return .culture
    case "market":     return .market
    case "activity":   return .nature
    default:           return .hidden
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
    let spot: APISpotRef?                 // el local exacto que el buddy documentó
    let users: APIUserRef?
    let journeyPlace: [APIJourneyPlace]?
    let buddyCount: Int?
    let destinationId: String?
    let placeId: String?         // para journeys GPS-only (sin destination)
    let spotId: String?          // spot curado elegido en "Compartir un lugar"
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
    let geoClass: String?   // "amenity", "shop", "tourism"... vs "place"/"boundary" (ciudad, no POI)
    let geoType: String?    // "cafe", "hotel"... vs "city"/"town"/"village"/"administrative"

    /// false cuando el geocoding solo resolvió al nivel de ciudad/distrito
    /// administrativo — no es un lugar específico (cafetería, hospedaje, etc.)
    /// que un buddy pueda "compartir". Ver findOrCreatePlace en buddy-core/src/lib/geo.js.
    var isSpecificPlace: Bool {
        if let geoClass {
            if geoClass == "boundary" { return false }
            if geoClass == "place", let geoType,
               ["city", "town", "village", "administrative", "suburb", "neighbourhood"].contains(geoType) {
                return false
            }
            return true
        }
        // Sin geo_class: o el backend aún no expone esos campos, o es una fila
        // antigua. Heurística equivalente — un place a nivel ciudad tiene el
        // mismo name que su city ("Lima"/"Lima"); un POI real no ("Cafetería
        // Rosal" en city "Lima").
        guard let city, !city.isEmpty else { return false }
        return name.caseInsensitiveCompare(city) != .orderedSame
    }
}

/// Spot curado del catálogo (tabla `spot`) — el local concreto: "Aneczú",
/// no la ciudad "Villa Rica".
struct APISpotRef: Decodable {
    let id: String
    let name: String
    let lat: Double?
    let lng: Double?
    let coverUrl: String?
    /// "approved" | "pending" — pending = propuesto por un buddy, aún sin
    /// aprobar en el admin. El buddy ya puede documentarlo mientras tanto.
    let status: String?

    var isPendingApproval: Bool { status == "pending" }
}

/// Categoría del catálogo de lugares (tabla `spot_category`). `icon` ya viene
/// como nombre de SF Symbol desde el backend, así que se pinta directo.
struct APISpotCategory: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let icon: String?
}

struct APISpotCategoriesResponse: Decodable {
    let categories: [APISpotCategory]
}

/// Resultado de GET /places/nearby — spot curado con su distancia al GPS.
struct APINearbySpot: Decodable, Identifiable {
    let id: String
    let name: String
    let lat: Double?
    let lng: Double?
    let coverUrl: String?
    let destinationId: String?
    /// nil solo en /places/search sin coordenadas — /places/nearby siempre lo trae.
    let distanceMeters: Int?
    let destination: APIDestinationRef?
    /// "approved" | "pending". Las pendientes aparecen a propósito: son
    /// lugares que otro buddy ya propuso, y elegirlas evita duplicarlos.
    let status: String?

    var isPendingApproval: Bool { status == "pending" }

    /// "a 40 m" / "a 1,2 km" — la pista que necesita el buddy para saber cuál
    /// de los locales cercanos es en el que está parado. Sin distancia cae al
    /// nombre del destino, que al menos ubica el resultado.
    var distanceLabel: String {
        guard let d = distanceMeters else { return destination?.name ?? "" }
        return d < 1000 ? "a \(d) m" : String(format: "a %.1f km", Double(d) / 1000)
    }
}

struct APINearbySpotsResponse: Decodable {
    let spots: [APINearbySpot]
    /// Solo lo manda /places/nearby; /places/search devuelve únicamente `spots`.
    let radius: Int?
}

/// Buddy mostrado en la tarjeta de un lugar. Es un buddy del DESTINO (así se
/// asignan), no del local — por eso la tarjeta lo rotula "N buddies en Lima".
struct APIPlaceBuddy: Decodable, Hashable {
    /// El backend lo manda desde siempre; el modelo no lo declaraba, así que se
    /// descartaba al decodificar y no había forma de abrir el perfil de nadie.
    let travelerId: String?
    let fullName: String?
    let avatarUrl: String?
    /// Solo lo trae GET /destinations/:id/buddies (la pestaña "Buddies" del
    /// detalle de lugar). El array embebido en place_cards_nearby no lo manda.
    let isAvailable: Bool?

    var initial: String {
        String(fullName?.trimmingCharacters(in: .whitespaces).first ?? "B").uppercased()
    }
}

struct APIDestinationBuddiesResponse: Decodable {
    let buddies: [APIPlaceBuddy]
}

/// Tarjeta del carrusel "Lugares por aquí": el sujeto es el LUGAR, no la foto
/// ni quien la subió. Ver place_cards_nearby en buddy-core.
/// Hashable (por id) para poder empujarla a un NavigationPath — abrir su mapa
/// tiene que ser un push dentro del NavigationStack existente, no un modal:
/// un .fullScreenCover SIEMPRE tapa la barra de tabs de la app, un push no.
struct APIPlaceCard: Decodable, Identifiable, Hashable {
    static func == (lhs: APIPlaceCard, rhs: APIPlaceCard) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    let id: String
    let name: String
    /// Con esto se puede pedirle a RouteStore la guía completa del destino y
    /// reutilizar TripDetailView (el mapa con "Recomendado por la comunidad")
    /// en vez de un mapa nuevo.
    let destinationId: String?
    let destinationName: String?
    let lat: Double?
    let lng: Double?
    let coverUrl: String?
    let coverUrls: [String]?
    /// Quién documentó la foto de portada — "Recomendado por {nombre}" en el
    /// carrusel de exploración.
    let coverAuthorName: String?
    let coverAuthorAvatarUrl: String?
    /// Nombre de la categoría del spot ("Alojamiento", "Café"…). Viene del
    /// catálogo curado, no de las categorías de ayuda: dice qué ES el lugar.
    let category: String?
    /// "approved" | "pending". Un lugar propuesto por un buddy nace pendiente:
    /// no sale en el mapa ni en la guía hasta que se apruebe, pero su autor sí
    /// lo ve en su propio perfil y puede seguir sumándole fotos mientras tanto.
    ///
    /// Opcional porque los endpoints que solo devuelven lugares aprobados no lo
    /// mandan; nil se lee como aprobado.
    let status: String?
    /// Todavía esperando aprobación. Solo debería llegar true en el perfil de
    /// quien lo propuso: el backend no manda pendientes a nadie más.
    var estaPendiente: Bool { status == "pending" }
    let photoCount: Int
    let isNew: Bool
    let buddyCount: Int
    let buddies: [APIPlaceBuddy]

    var photoLabel: String { "\(photoCount) foto\(photoCount == 1 ? "" : "s")" }

    /// Tarjetas de relleno para el esqueleto del carrusel.
    ///
    /// Existen para que el skeleton pueda renderizar el carrusel REAL en vez de
    /// una silueta parecida. Cualquier réplica hecha a mano se desalinea:
    /// la que había centraba el grupo de tres y agrandaba la del medio, mientras
    /// que el carrusel de verdad centra la PRIMERA y agranda ésa. Al llegar los
    /// datos, la card grande saltaba del medio a la izquierda.
    ///
    /// coverUrl nil a propósito: CachedImage ya pinta su placeholder, y una URL
    /// falsa dispararía una petición de red condenada a fallar.
    static func placeholders(_ n: Int = 3) -> [APIPlaceCard] {
        (0..<n).map { i in
            APIPlaceCard(
                id: "placeholder-\(i)", name: "Nombre del lugar",
                destinationId: nil, destinationName: nil, lat: nil, lng: nil,
                coverUrl: nil, coverUrls: nil,
                coverAuthorName: "Buddy", coverAuthorAvatarUrl: nil,
                category: "Categoría", status: nil, photoCount: 0, isNew: false,
                buddyCount: 0, buddies: [])
        }
    }

    /// "6 buddies en Villa Rica" — nombrar el destino evita dar a entender que
    /// esos buddies están dentro del local.
    var buddyLabel: String? {
        guard buddyCount > 0 else { return nil }
        let noun = buddyCount == 1 ? "buddy" : "buddies"
        if let destinationName { return "\(buddyCount) \(noun) en \(destinationName)" }
        return "\(buddyCount) \(noun)"
    }
}

struct APIPlaceCardsResponse: Decodable {
    let items: [APIPlaceCard]
}

/// Una visita al lugar: las fotos que UNA persona subió en UNA ocasión. La
/// galería es una tarjeta por visita, no un montón de fotos sueltas — así se
/// ve quién estuvo y cuándo.
struct APIPlaceVisit: Decodable, Identifiable {
    let journeyId: String
    let travelerId: String?
    let traveler: APIVisitAuthor?
    let isBuddy: Bool?
    let placeName: String?
    let createdAt: Date?
    let photos: [String]
    /// Las mismas fotos, con su página. Opcional porque el server viejo no la
    /// manda: sin ella la galería se ve igual, solo que no se puede borrar.
    let photoPages: [APIPlacePhoto]?

    var id: String { journeyId }
}

/// Una foto del memoir con su identidad.
///
/// clientPageId es el UUID de la página en el libro del cliente y no cambia
/// nunca; pageIndex sí se mueve al reordenar o al filtrarse una página vacía al
/// publicar. Es opcional porque las filas escritas antes de la migración no lo
/// tienen: esas se pueden ver, pero no borrar por identidad.
struct APIPlacePhoto: Decodable, Identifiable, Hashable {
    let url: String
    let pageIndex: Int
    let clientPageId: String?

    var id: String { "\(url)#\(pageIndex)" }
}

struct APIVisitAuthor: Decodable {
    let fullName: String?
    let avatarUrl: String?
}

struct APIPlaceGallery: Decodable {
    let visits: [APIPlaceVisit]
    let totalPhotos: Int
    let buddyCount: Int
    let travelerCount: Int
    let hasMore: Bool
    /// Cursor opaco de la siguiente página. El servidor lo manda desde siempre;
    /// hasta ahora este modelo no lo declaraba, así que se descartaba al
    /// decodificar y la galería se quedaba con la primera página para siempre.
    let nextCursor: String?
    /// MI recomendación de este lugar, publicada o no y con fotos o sin ellas.
    ///
    /// Antes la vista la deducía de `visits`, que solo trae journeys publicados
    /// y con fotos. Eso cerraba el círculo: "Añadir foto" solo aparecía si ya
    /// había una foto, así que un lugar recién añadido no tenía por dónde
    /// recibir la primera. El servidor la calcula sin ese filtro.
    ///
    /// Opcional porque un servidor anterior no la manda; en ese caso se sigue
    /// deduciendo como antes.
    let myVisit: APIPlaceVisit?
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

// Pulso global de la red — GET /community/pulse
// type: "traveling" (viajeros con trip activo ahora) | "helped" (ayuda
// completada) | "ready" (buddies disponibles). El cliente arma la frase.
struct APIPulseItem: Decodable, Identifiable {
    let type: String
    let city: String
    let count: Int?
    let at: Date?
    /// Enum crudo de help_request.category — el texto lo arma la vista.
    let category: String?
    /// Quién ayudó. Sin él la fila nombra a alguien a quien no se puede abrir.
    /// Nil en los items "traveling", que cuentan gente sin nombrarla.
    let buddyId: String?
    let buddyName: String?
    let buddyAvatarUrl: String?
    var id: String { "\(type)-\(city)-\(at?.timeIntervalSince1970 ?? 0)" }
}

extension APIPulseItem {
    /// Filas de relleno para el esqueleto de Comunidad viva.
    ///
    /// La sección entera no existía mientras cargaba y aparecía después,
    /// empujando hacia abajo todo lo que venía detrás. Con estas filas ocupa su
    /// sitio definitivo desde el primer frame.
    ///
    /// Los textos tienen largo realista —no "..."— porque el redacted dibuja
    /// una barra del ancho del texto: con marcadores cortos las barras salían
    /// mínimas y el bloque no reservaba el alto real de dos líneas.
    static func placeholders(_ n: Int = 3) -> [APIPulseItem] {
        (0..<n).map { i in
            APIPulseItem(type: "helped", city: "Ciudad", count: nil,
                         at: Date(timeIntervalSince1970: TimeInterval(i)),
                         category: "general",
                         buddyId: nil, buddyName: "Nombre", buddyAvatarUrl: nil)
        }
    }
}

struct APIPulseResponse: Decodable {
    let items: [APIPulseItem]
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
    /// El PRIMER destino que declaró, no su cobertura. Sirve de respaldo.
    let destination: APIDestinationRef?
    /// Todos los destinos donde eligió ser buddy. Hay quien cubre seis, así que
    /// `destination` a secas contaba mucho menos de lo que la persona cubre.
    let destinations: [APIDestinationRef]?

    /// Los nombres de su cobertura, sin repetir y en orden. Cae en
    /// `destination` para los perfiles que aún no tienen el array poblado.
    var coverageNames: [String] {
        if let all = destinations, !all.isEmpty {
            return all.compactMap { $0.name ?? $0.city }
        }
        return [destination?.name ?? destination?.city].compactMap { $0 }
    }
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
    /// Intenciones POR LUGAR: { placeId: [intención] }.
    ///
    /// `specialties` sigue existiendo como lista global del perfil y es el
    /// respaldo para los lugares que el buddy todavía no configuró. Sin este
    /// mapa, la pantalla dibujaba una fila de intenciones por lugar pero las N
    /// escribían la misma lista.
    let placeSpecialties: [String: [String]]?
    let destination: APIDestinationRef?

    /// Lo que hay que pintar en la tarjeta de un lugar. Cae a la lista global
    /// cuando ese lugar aún no tiene nada propio guardado.
    func specialties(forPlace placeId: String) -> Set<String> {
        if let propias = placeSpecialties?[placeId] { return Set(propias) }
        return Set(specialties ?? [])
    }
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
    let destination: APIDestinationRef?

    // Solo presentes en GET /matching/requests/for-buddy — metadata de
    // "Solicitudes de ayuda" (respaldo comunitario con ventana de exclusividad).
    let candidateCount: Int?
    let isPriorityForMe: Bool?
    let isCommunityUnlocked: Bool?
    let communityUnlocksIn: Int?
    let offerSecondsRemaining: Int?
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
    /// El backend siempre lo manda en /matching/matches. Trae el destino, que
    /// es lo que deja saber DESDE DÓNDE piden ayuda — un buddy puede estar
    /// atendiendo varios lugares a la vez y sin esto las conversaciones son
    /// indistinguibles.
    let helpRequest: MatchHelpRequest?

    struct MatchHelpRequest: Decodable {
        let category: String?
        let description: String?
        let destination: APIDestinationRef?
    }
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
