import SwiftUI
import UIKit
import CoreLocation

// MARK: – Caché con su propio reloj

/// Un valor con fecha de vencimiento propia.
///
/// La clave es "propia": antes el perfil entero tenía UN solo `lastFetchedAt`,
/// así que cualquier recarga arrastraba todo. Cambiar el avatar volvía a pedir
/// los trips; borrar un trip volvía a pedir el perfil. Con un reloj por bloque,
/// cada uno se invalida por su cuenta.
@MainActor
final class TimedCache<Value> {
    private var value: Value?
    private var storedAt: Date?
    private let ttl: TimeInterval

    init(ttl: TimeInterval) { self.ttl = ttl }

    var isFresh: Bool {
        guard let storedAt else { return false }
        return Date().timeIntervalSince(storedAt) < ttl
    }

    var ageSeconds: Int {
        storedAt.map { Int(Date().timeIntervalSince($0)) } ?? -1
    }

    /// Solo si sigue vigente. Es lo que decide si hay que ir a la red.
    func fresh() -> Value? { isFresh ? value : nil }

    /// Sin importar la frescura. Sirve para pintar algo de inmediato mientras la
    /// versión nueva viaja: una lista vieja se ve mejor que un hueco.
    func stale() -> Value? { value }

    func write(_ v: Value) { value = v; storedAt = Date() }
    func invalidate() { storedAt = nil }
    func clear() { value = nil; storedAt = nil }
}

// MARK: – Repositorios

/// Quién soy: usuario, perfil de buddy, stickers y destinos.
///
/// Los cuatro viven juntos porque alimentan la misma zona de la pantalla —la
/// cabecera y sus filas— y se invalidan por los mismos motivos. Los trips y los
/// lugares tienen sus propios repositorios justamente porque no.
@MainActor
final class ProfileRepository {
    static let shared = ProfileRepository()
    private init() {}

    struct Profile {
        var user: APIUser
        var buddyMe: APIBuddyMe?
        var stickers: [APIUserSticker]
        var destinations: [APIDestination]
    }

    let cache = TimedCache<Profile>(ttl: 10)

    /// El usuario, y nada más. Se pide aparte del resto del bloque para que la
    /// cabecera aparezca sin esperar a stickers ni destinos.
    ///
    /// Reintenta una vez: tras un alta social el backend puede tardar un
    /// instante en tener la fila del usuario (Apple sobre todo).
    func fetchUser() async -> APIUser? {
        if let me = try? await APIClient.shared.fetchCurrentUser() { return me }
        print("👤 [ProfileRepo] fetchCurrentUser falló — reintentando en 1.5s…")
        try? await Task.sleep(for: .seconds(1.5))
        return try? await APIClient.shared.fetchCurrentUser()
    }

    /// Devuelve nil por bloque que NO llegó, sin convertirlo en vacío.
    ///
    /// Antes hacía `s ?? []` y `d ?? []` acá mismo, así que el llamador no podía
    /// distinguir "no tienes stickers" de "la petición falló". Con `try?` una
    /// CANCELACIÓN también cae en esa rama, y las tareas de .refreshable se
    /// cancelan de rutina: bastaba eso para que un refresco escribiera vacíos
    /// encima de datos buenos.
    func fetchRest(travelerId: String) async -> (buddy: APIBuddyMe?, stickers: [APIUserSticker]?, destinations: [APIDestination]?) {
        async let buddyTask    = try? APIClient.shared.fetchBuddyMe()
        async let stickersTask = try? APIClient.shared.fetchUserStickers(travelerId: travelerId)
        async let destsTask    = try? APIClient.shared.fetchDestinations()
        let (b, s, d) = await (buddyTask, stickersTask, destsTask)
        return (b, s, d)
    }
}

/// Los trips publicados, paginados por cursor.
@MainActor
final class TripsRepository {
    static let shared = TripsRepository()
    private init() {}

    struct Page {
        var items: [APIJourney]
        var nextCursor: String?
        var hasMore: Bool
    }

    let cache = TimedCache<Page>(ttl: 10)

    func fetch(travelerId: String, cursor: String?) async -> FeedPage? {
        try? await APIClient.shared.fetchUserTrips(travelerId: travelerId, cursor: cursor)
    }
}

/// Los lugares que recomienda.
///
/// Sin cursor: `place_cards_by_traveler(p_traveler_id, p_limit)` solo acepta un
/// límite. Cuando la RPC lo tenga, este repositorio es donde vive el cambio y la
/// vista no se entera.
@MainActor
final class SharesRepository {
    static let shared = SharesRepository()
    private init() {}

    let cache = TimedCache<[APIPlaceCard]>(ttl: 10)

    func fetch(travelerId: String) async -> [APIPlaceCard]? {
        try? await APIClient.shared.fetchUserShares(travelerId: travelerId)
    }
}

// MARK: – ViewModel

/// Todo el estado de datos del tab Yo.
///
/// La vista se quedó con lo suyo —qué sheet está abierta, qué texto se está
/// editando, a dónde navega— y dejó de ser también la capa de red, la de caché y
/// la de paginación. No es por rendimiento: es que la pantalla ya era grande y
/// cada arreglo tenía que leerse entera para saber qué tocaba qué.
@MainActor
final class YoViewModel: ObservableObject {

    // Cabecera
    @Published private(set) var user: APIUser?
    @Published private(set) var buddyMe: APIBuddyMe?
    @Published private(set) var stickers: [APIUserSticker] = []
    @Published private(set) var destinations: [APIDestination] = []
    @Published private(set) var isLoadingProfile = true

    // Trips
    @Published private(set) var journeys: [APIJourney] = []
    @Published private(set) var tripsHasMore = false
    @Published private(set) var isLoadingMoreTrips = false

    // Lugares que recomienda
    @Published private(set) var shares: [APIPlaceCard] = []

    // Demanda sin cubrir en la zona
    @Published private(set) var unattendedCount = 0
    @Published private(set) var unattendedPlaceName = ""

    // Fallos que la vista convierte en alerta
    @Published var bioSaveFailed = false
    @Published var avatarUploadFailed = false
    @Published private(set) var isSavingBio = false
    @Published private(set) var isUploadingAvatar = false

    private var tripsNextCursor: String?
    private var isLoadingBlock = false

    // MARK: Carga

    /// Cada bloque llega cuando llega.
    ///
    /// Antes los cinco requests se lanzaban juntos y se esperaban con un solo
    /// `await`, así que la mitad inferior de la pantalla aparecía de golpe, al
    /// ritmo del más lento: si los lugares tardaban 400 ms, los trips se
    /// quedaban invisibles 400 ms aunque hubieran llegado en 80. Ahora cada
    /// bloque se publica en cuanto está.
    func load(force: Bool = false) async {
        guard Session.hasSession else {
            print("👤 [YoVM] sin sesión — saliendo")
            isLoadingProfile = false
            return
        }
        guard !isLoadingBlock || force else { return }
        isLoadingBlock = true
        defer { isLoadingBlock = false }

        await loadHeader(force: force)
        guard let id = user?.id else { return }

        // Sin `await` conjunto: son tres tareas sueltas que se publican por
        // separado. Ahí está toda la diferencia con la versión anterior.
        async let trips: Void  = loadTrips(travelerId: id, force: force)
        async let shares: Void = loadShares(travelerId: id, force: force)
        _ = await (trips, shares)
    }

    /// Cabecera. El usuario se publica antes de pedir el resto del bloque, así
    /// que nombre y avatar aparecen sin esperar stickers ni destinos.
    private func loadHeader(force: Bool) async {
        let repo = ProfileRepository.shared
        if !force, let hit = repo.cache.fresh() {
            print("👤 [YoVM] perfil en caché (\(repo.cache.ageSeconds)s)")
            apply(hit)
            isLoadingProfile = false
            return
        }
        if user == nil { isLoadingProfile = true }

        guard let me = await repo.fetchUser() else {
            print("👤 [YoVM] ❌ fetchCurrentUser falló — token inválido, sin red, o sin perfil en DB")
            isLoadingProfile = false
            return
        }
        user = me
        isLoadingProfile = false   // ← la cabecera ya se puede pintar

        let rest = await repo.fetchRest(travelerId: me.id)

        // Un bloque que no llegó NO se escribe como vacío.
        //
        // buddyMe manda si se puede recomendar lugares (canRecommendPlaces mira
        // verificationStatus), así que ponerlo a nil hacía desaparecer la
        // tarjeta "Añadir lugar" — se leía como si se hubiera salido de un modo
        // edición. Y bastaba un refresco para provocarlo: .refreshable cancela
        // su tarea de rutina, `try?` convierte esa cancelación en nil, y nil se
        // escribía encima del perfil bueno.
        //
        // nil aquí SIEMPRE significa "no lo sé": dejar de ser buddy llega como
        // una respuesta válida con isBuddy=false, no como fallo.
        if let b = rest.buddy { buddyMe = b } else { print("👤 [YoVM] ⚠️ buddy/me no llegó — conservo el anterior") }
        if let s = rest.stickers { stickers = s } else { print("👤 [YoVM] ⚠️ stickers no llegaron — conservo los anteriores") }
        if let d = rest.destinations { destinations = d } else { print("👤 [YoVM] ⚠️ destinos no llegaron — conservo los anteriores") }

        // A la caché va lo que la pantalla está mostrando, no la respuesta
        // cruda: guardar los nil convertiría un fallo puntual en un perfil
        // mutilado que sobrevive al siguiente arranque.
        repo.cache.write(.init(user: me, buddyMe: buddyMe,
                               stickers: stickers, destinations: destinations))
    }

    private func loadTrips(travelerId: String, force: Bool) async {
        let repo = TripsRepository.shared
        if !force, let hit = repo.cache.fresh() {
            journeys = hit.items; tripsNextCursor = hit.nextCursor; tripsHasMore = hit.hasMore
            return
        }
        // Lo viejo se pinta mientras llega lo nuevo: un grid con contenido
        // desactualizado se lee mejor que uno vacío que aparece de golpe.
        if journeys.isEmpty, let stale = repo.cache.stale() { journeys = stale.items }

        guard let page = await repo.fetch(travelerId: travelerId, cursor: nil) else { return }
        journeys        = page.items
        tripsNextCursor = page.nextCursor
        tripsHasMore    = page.hasMore
        repo.cache.write(.init(items: page.items, nextCursor: page.nextCursor, hasMore: page.hasMore))
        print("👤 [YoVM] trips → \(page.items.count) hasMore=\(page.hasMore)")
    }

    private func loadShares(travelerId: String, force: Bool) async {
        let repo = SharesRepository.shared
        if !force, let hit = repo.cache.fresh() { shares = hit; return }
        if shares.isEmpty, let stale = repo.cache.stale() { shares = stale }

        guard let items = await repo.fetch(travelerId: travelerId) else { return }
        shares = items
        repo.cache.write(items)
        print("👤 [YoVM] shares → \(items.count)")
    }

    /// Si el usuario no es buddy y tiene ubicación, cuántas solicitudes recientes
    /// de su zona se quedaron sin atender — para invitarlo a postular ahí.
    func loadUnattendedDemand(location: CLLocation?) async {
        guard buddyMe?.isBuddy != true, let loc = location else { return }
        do {
            let place = try await APIClient.shared.resolvePlace(
                lat: loc.coordinate.latitude, lng: loc.coordinate.longitude)
            guard let destinationId = place.destinationId else { return }
            let count = try await APIClient.shared.fetchUnattendedCount(destinationId: destinationId)
            guard count > 0 else { return }
            unattendedCount = count
            unattendedPlaceName = place.name
        } catch {
            print("👤 [YoVM] loadUnattendedDemand falló:", error.localizedDescription)
        }
    }

    // MARK: Paginación de trips

    func loadMoreTrips() async {
        guard tripsHasMore, !isLoadingMoreTrips, let userId = user?.id else { return }
        isLoadingMoreTrips = true
        defer { isLoadingMoreTrips = false }
        guard let page = await TripsRepository.shared.fetch(travelerId: userId, cursor: tripsNextCursor) else { return }
        // Por id y no a ciegas: si se publica un trip mientras se pagina, el
        // cursor por created_at puede devolver uno que ya está en la lista, y un
        // id repetido rompe la identidad del grid.
        let known = Set(journeys.map(\.id))
        journeys += page.items.filter { !known.contains($0.id) }
        tripsNextCursor = page.nextCursor
        tripsHasMore    = page.hasMore
        TripsRepository.shared.cache.write(
            .init(items: journeys, nextCursor: tripsNextCursor, hasMore: tripsHasMore))
        print("👤 [YoVM] loadMoreTrips +\(page.items.count) → \(journeys.count)")
    }

    /// Gancho del grid de trips.
    ///
    /// Se dispara al 80% de lo cargado y no en el último: con páginas de 12 la
    /// petición sale en el trip 10, con dos filas por delante, que a velocidad de
    /// scroll normal alcanza para que llegue antes de tocar el fondo. Esperar al
    /// último garantiza ver el spinner.
    func tripAppeared(_ journey: APIJourney) {
        guard let idx = journeys.firstIndex(where: { $0.id == journey.id }) else { return }
        // De a seis y no las doce: bajar portadas que quizá nadie mire gasta
        // datos del usuario y compite con las que sí están en pantalla.
        let ahead = journeys.dropFirst(idx + 1).prefix(6)
        ImagePrefetcher.prefetch(ahead.compactMap { $0.pageThumbs?.first ?? $0.coverUrl })

        guard tripsHasMore, !isLoadingMoreTrips, !journeys.isEmpty else { return }
        guard Double(idx + 1) / Double(journeys.count) >= 0.8 else { return }
        Task { await loadMoreTrips() }
    }

    /// Solo precarga: `/users/:id/shares` no tiene página siguiente que pedir.
    func shareAppeared(_ place: APIPlaceCard) {
        guard let idx = shares.firstIndex(where: { $0.id == place.id }) else { return }
        let ahead = shares.dropFirst(idx + 1).prefix(6)
        ImagePrefetcher.prefetch(ahead.compactMap { $0.coverUrls?.first ?? $0.coverUrl })
    }

    // MARK: Mutaciones
    //
    // Cada una invalida SOLO su bloque. Es el motivo de tener tres cachés:
    // cambiar el avatar no debe volver a pedir los trips, y borrar un trip no
    // debe volver a pedir el perfil.

    func saveBio(_ text: String) async -> Bool {
        guard let userId = Session.travelerId else { return false }
        isSavingBio = true
        defer { isSavingBio = false }
        do {
            try await APIClient.shared.updateUserBio(travelerId: userId, bio: text)
            user = user.map { var c = $0; c.bio = text; return c }
            ProfileRepository.shared.cache.invalidate()
            Haptic.success()
            return true
        } catch {
            bioSaveFailed = true
            return false
        }
    }

    func uploadAvatar(jpegData: Data) async {
        isUploadingAvatar = true
        defer { isUploadingAvatar = false }
        do {
            let url = try await APIClient.shared.uploadAvatar(imageData: jpegData)
            print("🖼️ [YoVM] avatar ✅ \(url.suffix(60))")
            user = user.map { var c = $0; c.avatarUrl = url; return c }
            ProfileRepository.shared.cache.invalidate()
            Haptic.success()
        } catch {
            print("🖼️ [YoVM] avatar ❌ \(error)")
            avatarUploadFailed = true
        }
    }

    /// Optimista: se quita del grid al instante y el backend cancela el viaje
    /// entero —sus lugares y los apoyos en curso—, con lo que sale del feed.
    ///
    /// El id que llega es de un TRIP, no de un journey. `/users/:id/trips`
    /// agrupa los journeys por viaje y `feed_trip_json_by_trip` devuelve
    /// `'id', j_group.trip_id`: una publicación del perfil es un viaje, no un
    /// lugar suelto. Esto llamaba a `cancelJourney` con ese id, así que el
    /// servidor no encontraba ningún journey y respondía 403 SIEMPRE — el
    /// borrado nunca funcionó, solo lo parecía.
    ///
    /// Y si falla, la fila vuelve. Antes desaparecía igual: la vista afirmaba
    /// un hecho que el servidor había rechazado, y el siguiente arranque la
    /// traía de vuelta sin explicación.
    func deletePublication(_ journey: APIJourney) {
        let anteriores = journeys
        journeys.removeAll { $0.id == journey.id }
        TripsRepository.shared.cache.write(
            .init(items: journeys, nextCursor: tripsNextCursor, hasMore: tripsHasMore))
        Haptic.success()
        Task {
            do {
                try await APIClient.shared.cancelTrip(tripId: journey.id)
                print("🗑️ [YoVM] publicación \(journey.id.prefix(8)) eliminada")
            } catch {
                print("❌ [YoVM] deletePublication \(error) — restaurando")
                await MainActor.run {
                    journeys = anteriores
                    TripsRepository.shared.cache.write(
                        .init(items: journeys, nextCursor: tripsNextCursor, hasMore: tripsHasMore))
                    deletePublicationFailed = true
                }
            }
        }
    }

    /// Lo enciende el fallo de borrado; lo apaga la vista al mostrar el aviso.
    /// Sin esto la fila reaparecía sola y parecía un bug distinto.
    @Published var deletePublicationFailed = false

    /// El perfil de buddy lo edita otra pantalla (BuddyProfileView), que
    /// devuelve la versión nueva. Se acepta desde fuera en vez de refetchear:
    /// esa pantalla ya recibió la respuesta del servidor.
    func setBuddyMe(_ updated: APIBuddyMe) {
        buddyMe = updated
        ProfileRepository.shared.cache.invalidate()
    }

    func becomeBuddy() async throws -> APIBuddyMe? {
        let result = try await APIClient.shared.becomeBuddy()
        ProfileRepository.shared.cache.invalidate()
        buddyMe = try? await APIClient.shared.fetchBuddyMe()
        return result
    }

    // MARK: Invalidación desde fuera

    /// Cambió una foto de un lugar: afecta a las portadas de los lugares que
    /// recomienda y a las de los trips, pero no a quién es el usuario.
    func invalidatePhotos() {
        TripsRepository.shared.cache.invalidate()
        SharesRepository.shared.cache.invalidate()
    }

    /// Se desbloqueó un sticker: es cosa de la cabecera, no de los trips.
    func invalidateProfile() {
        ProfileRepository.shared.cache.invalidate()
    }

    func signedOut() {
        ProfileRepository.shared.cache.clear()
        TripsRepository.shared.cache.clear()
        SharesRepository.shared.cache.clear()
        user = nil; buddyMe = nil; stickers = []; destinations = []
        journeys = []; shares = []
        tripsNextCursor = nil; tripsHasMore = false
        // Vuelve al spinner: el siguiente que entre está cargando de cero.
        isLoadingProfile = true
    }

    private func apply(_ p: ProfileRepository.Profile) {
        user = p.user; buddyMe = p.buddyMe
        stickers = p.stickers; destinations = p.destinations
    }
}
