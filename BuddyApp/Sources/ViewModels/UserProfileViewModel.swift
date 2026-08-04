import SwiftUI

/// A quién abrir. Viaja por el NavigationPath.
///
/// Lleva el nombre además del id para poder pintar la cabecera en cuanto se
/// empuja la pantalla: el que tocó la cara ya sabe de quién es, y esperar a que
/// vuelva `/users/:id` para mostrarlo deja medio segundo de vacío.
struct TravelerProfileRoute: Hashable {
    let travelerId: String
    let previewName: String?
    let previewAvatarUrl: String?
}

/// Perfiles ya cargados, para que reabrir a la misma persona no vuelva a pedir
/// todo.
///
/// No es una optimización cosmética: el log mostró el perfil de Jared pedido
/// CUATRO veces seguidas —16 peticiones— porque la pantalla se reconstruye cada
/// vez que el Home re-renderiza, y con ella un ViewModel nuevo y vacío. La
/// caché hace que esas reconstrucciones sean gratis y, sobre todo, que no
/// muestren un perfil vacío mientras vuelven a cargar.
@MainActor
final class UserProfileRepository {
    static let shared = UserProfileRepository()
    private init() {}

    struct Snapshot {
        var user: APIUser
        var stickers: [APIUserSticker]
        var journeys: [APIJourney]
        var shares: [APIPlaceCard]
        var tripsNextCursor: String?
        var tripsHasMore: Bool
        var storedAt: Date
    }

    private var cache: [String: Snapshot] = [:]
    /// 60s: mirar tres perfiles y volver al primero no debería costar red, pero
    /// tampoco queremos servir datos de hace media hora.
    private let ttl: TimeInterval = 60

    func fresh(_ id: String) -> Snapshot? {
        guard let s = cache[id], Date().timeIntervalSince(s.storedAt) < ttl else { return nil }
        return s
    }
    func store(_ s: Snapshot, for id: String) { cache[id] = s }
}

/// El perfil de OTRA persona. Solo lectura.
///
/// Los cuatro bloques se piden a la vez y se escriben juntos. Con caché por id
/// (UserProfileRepository): reabrir a la misma persona en menos de un minuto no
/// cuesta red, que es lo que evita que reconstruir la pantalla la vacíe.
@MainActor
final class UserProfileViewModel: ObservableObject {

    @Published private(set) var user: APIUser?
    @Published private(set) var isLoadingUser = true

    @Published private(set) var stickers: [APIUserSticker] = []
    @Published private(set) var journeys: [APIJourney] = []
    @Published private(set) var shares: [APIPlaceCard] = []
    @Published private(set) var tripsHasMore = false
    @Published private(set) var isLoadingMoreTrips = false
    @Published private(set) var loadFailed = false

    private let travelerId: String
    private var tripsNextCursor: String?

    init(travelerId: String) { self.travelerId = travelerId }

    var isMe: Bool { Session.travelerId == travelerId }

    func load() async {
        guard user == nil else { return }

        // Si esta persona se miró hace poco, se pinta y no se pide nada. Es lo
        // que evita las 16 peticiones cuando la pantalla se reconstruye.
        if let hit = UserProfileRepository.shared.fresh(travelerId) {
            apply(hit)
            isLoadingUser = false
            print("👤 [UserProfileVM] \(travelerId.prefix(8)) desde caché — sin red")
            return
        }

        // La cabecera primero y sola: es lo único que la pantalla necesita para
        // dejar de verse vacía.
        async let userTask = try? APIClient.shared.fetchUser(id: travelerId)
        async let stickersTask = try? APIClient.shared.fetchUserStickers(travelerId: travelerId)
        async let tripsTask    = try? APIClient.shared.fetchUserTrips(travelerId: travelerId)
        async let sharesTask   = try? APIClient.shared.fetchUserShares(travelerId: travelerId)

        let cargado   = await userTask
        let stickersR = await stickersTask
        let page      = await tripsTask
        let sharesR   = await sharesTask

        // Si la vista murió mientras las peticiones volaban, sus resultados no
        // valen: URLSession las cancela y `try?` convierte esa cancelación en
        // nil, indistinguible de "esta persona no tiene trips". Eso es lo que
        // hacía que el primer render dijera trips=0 y el siguiente trips=4.
        guard !Task.isCancelled else {
            print("👤 [UserProfileVM] \(travelerId.prefix(8)) cancelado — no se escribe nada")
            return
        }

        user = cargado
        isLoadingUser = false
        if cargado == nil {
            loadFailed = true
            print("👤 [UserProfileVM] ❌ no se pudo cargar \(travelerId.prefix(8))")
            return
        }

        // Un bloque que falla NO se escribe como vacío: decirlo en el log y
        // dejar la sección fuera es honesto; pintar "0 trips" por un fallo de
        // red es mentir sobre esta persona.
        if let stickersR { stickers = stickersR } else { print("👤 [UserProfileVM] ⚠️ stickers no llegaron") }
        if let sharesR   { shares   = sharesR   } else { print("👤 [UserProfileVM] ⚠️ lugares no llegaron") }
        if let page {
            journeys        = page.items
            tripsNextCursor = page.nextCursor
            tripsHasMore    = page.hasMore
        } else {
            print("👤 [UserProfileVM] ⚠️ trips no llegaron")
        }

        if let cargado {
            UserProfileRepository.shared.store(
                .init(user: cargado, stickers: stickers, journeys: journeys, shares: shares,
                      tripsNextCursor: tripsNextCursor, tripsHasMore: tripsHasMore,
                      storedAt: Date()),
                for: travelerId)
        }

        // Se loguea lo que la pantalla VA A PINTAR, no lo que llegó: si la
        // tarjeta sale con una sola zona, este renglón dice si es porque la
        // persona cubre una o porque el dato no vino.
        let bp = user?.buddyProfile
        let cobertura = bp?.coverageNames ?? []
        print("""
        👤 [UserProfileVM] \(travelerId.prefix(8)) "\(user?.fullName ?? "?")" \
        trips=\(journeys.count) lugares=\(shares.count) stickers=\(stickers.count) \
        buddy=\(bp == nil ? "no" : "sí") zonas=\(cobertura.count) [\(cobertura.joined(separator: " · "))]
        """)
    }

    private func apply(_ s: UserProfileRepository.Snapshot) {
        user = s.user; stickers = s.stickers; journeys = s.journeys; shares = s.shares
        tripsNextCursor = s.tripsNextCursor; tripsHasMore = s.tripsHasMore
    }

    // MARK: Paginación de trips — mismo criterio que el tab Yo

    func loadMoreTrips() async {
        guard tripsHasMore, !isLoadingMoreTrips else { return }
        isLoadingMoreTrips = true
        defer { isLoadingMoreTrips = false }
        guard let page = try? await APIClient.shared.fetchUserTrips(travelerId: travelerId, cursor: tripsNextCursor)
        else { return }
        let known = Set(journeys.map(\.id))
        journeys += page.items.filter { !known.contains($0.id) }
        tripsNextCursor = page.nextCursor
        tripsHasMore    = page.hasMore
    }

    /// Pide la siguiente página al 80% de lo cargado y precarga las portadas de
    /// los seis siguientes, para no ver nunca el spinner al llegar al fondo.
    func tripAppeared(_ journey: APIJourney) {
        guard let idx = journeys.firstIndex(where: { $0.id == journey.id }) else { return }
        let ahead = journeys.dropFirst(idx + 1).prefix(6)
        ImagePrefetcher.prefetch(ahead.compactMap { $0.pageThumbs?.first ?? $0.coverUrl })

        guard tripsHasMore, !isLoadingMoreTrips, !journeys.isEmpty else { return }
        guard Double(idx + 1) / Double(journeys.count) >= 0.8 else { return }
        Task { await loadMoreTrips() }
    }

    func shareAppeared(_ place: APIPlaceCard) {
        guard let idx = shares.firstIndex(where: { $0.id == place.id }) else { return }
        let ahead = shares.dropFirst(idx + 1).prefix(6)
        ImagePrefetcher.prefetch(ahead.compactMap { $0.coverUrls?.first ?? $0.coverUrl })
    }
}
