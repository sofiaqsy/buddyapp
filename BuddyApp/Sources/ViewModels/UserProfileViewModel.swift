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

/// El perfil de OTRA persona. Solo lectura.
///
/// Los tres bloques cargan por separado, igual que en el tab Yo: la cabecera no
/// espera a los trips, y los trips no esperan a los lugares. Sin cachés
/// compartidas, en cambio — las de Yo son de "mi" perfil, y meter aquí un
/// diccionario por id sería guardar en memoria a cada buddy que se mire de paso.
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

        // La cabecera primero y sola: es lo único que la pantalla necesita para
        // dejar de verse vacía.
        async let userTask = try? APIClient.shared.fetchUser(id: travelerId)
        async let stickersTask = try? APIClient.shared.fetchUserStickers(travelerId: travelerId)
        async let tripsTask    = try? APIClient.shared.fetchUserTrips(travelerId: travelerId)
        async let sharesTask   = try? APIClient.shared.fetchUserShares(travelerId: travelerId)

        user = await userTask
        isLoadingUser = false
        if user == nil {
            loadFailed = true
            print("👤 [UserProfileVM] ❌ no se pudo cargar \(travelerId.prefix(8))")
        }

        stickers = await stickersTask ?? []
        let page = await tripsTask
        journeys        = page?.items ?? []
        tripsNextCursor = page?.nextCursor
        tripsHasMore    = page?.hasMore ?? false
        shares = await sharesTask ?? []

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
