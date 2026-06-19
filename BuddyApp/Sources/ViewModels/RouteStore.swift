import Foundation
import CoreLocation
import Combine

final class RouteStore: ObservableObject {
    @Published var route: Route = .placeholder
    @Published var unlockedPlace: Place?
    @Published var isReady = false
    @Published var isLoading = false
    @Published var apiError: String?

    private let key = "buddyapp.route.v5"
    private var routeBuilt = false

    init() { load() }

    // MARK: – Load from API

    func buildRouteIfNeeded(near origin: CLLocationCoordinate2D) {
        guard !routeBuilt else { return }
        routeBuilt = true
        // Siempre refresca del API para tener stickers actualizados,
        // aunque ya haya datos cacheados en UserDefaults
        Task { await fetchDestinationFromAPI() }
    }

    @MainActor
    func fetchDestinationFromAPI(id: String? = nil) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let destId: String
            if let id {
                destId = id
            } else {
                let destinations = try await APIClient.shared.fetchDestinations()
                guard let first = destinations.first else { return }
                destId = first.id
            }

            let dest = try await APIClient.shared.fetchDestination(id: destId)
            let apiPlaces: [APIPlace] = dest.places ?? []
            let places: [Place] = apiPlaces.map { $0.asPlace }
            guard !places.isEmpty else { return }

            route = Route(
                id: UUID(uuidString: dest.id) ?? UUID(),
                title: dest.name,
                subtitle: dest.city,
                city: dest.city,
                places: places,
                radiusMeters: dest.radiusMeters
            )
            isReady = true
            save()
        } catch {
            apiError = error.localizedDescription
        }
    }

    // MARK: – Collect a place

    func collect(placeId: UUID) {
        guard let idx = route.places.firstIndex(where: { $0.id == placeId }) else { return }
        unlockedPlace = route.places[idx]
        save()
    }

    /// Called after QR scan or when loading user stickers — marks matching places as collected
    @MainActor
    func markStickerCollected(stickerId: String) {
        var changed = false
        for i in route.places.indices {
            if route.places[i].stickerId == stickerId, !route.places[i].isCollected {
                route.places[i].isCollected = true
                changed = true
            }
        }
        if changed { save() }
        // Notify YoView and anyone listening to refresh stickers list
        NotificationCenter.default.post(name: .stickerUnlocked, object: stickerId)
    }

    /// Sync collected status from the server's user_sticker list
    @MainActor
    func syncCollectedStickers(userStickers: [APIUserSticker]) {
        let unlockedIds = Set(userStickers.map(\.stickerId))
        var changed = false
        for i in route.places.indices {
            guard let sid = route.places[i].stickerId else { continue }
            let should = unlockedIds.contains(sid)
            if route.places[i].isCollected != should {
                route.places[i].isCollected = should
                changed = true
            }
        }
        if changed { save() }
    }

    func dismissUnlock() { unlockedPlace = nil }

    // MARK: – Favorites (per-user, sincroniza con backend)

    /// Carga los favoritos DE ESE TRIP y los aplica sobre los lugares actuales.
    @MainActor
    func loadFavorites(journeyId: String) async {
        guard let ids = try? await APIClient.shared.fetchFavorites(journeyId: journeyId) else { return }
        syncFavorites(placeIds: ids)
    }

    @MainActor
    func syncFavorites(placeIds: [String]) {
        let favs = Set(placeIds.map { $0.lowercased() })
        var changed = false
        for i in route.places.indices {
            let should = favs.contains(route.places[i].id.uuidString.lowercased())
            if route.places[i].isFavorite != should {
                route.places[i].isFavorite = should
                changed = true
            }
        }
        if changed { save() }
    }

    /// Toca/destoca favorito DEL TRIP — actualización optimista + llamada al backend.
    @MainActor
    func toggleFavorite(placeId: UUID, journeyId: String) {
        guard let idx = route.places.firstIndex(where: { $0.id == placeId }) else { return }
        let wasFav = route.places[idx].isFavorite
        route.places[idx].isFavorite = !wasFav   // optimista
        save()
        Haptic.light()
        let idStr = placeId.uuidString
        Task {
            do {
                if wasFav { try await APIClient.shared.removeFavorite(journeyId: journeyId, placeId: idStr) }
                else      { try await APIClient.shared.addFavorite(journeyId: journeyId, placeId: idStr) }
            } catch {
                // Revertir si el backend falla
                await MainActor.run {
                    if let i = self.route.places.firstIndex(where: { $0.id == placeId }) {
                        self.route.places[i].isFavorite = wasFav
                        self.save()
                    }
                }
            }
        }
    }

    @MainActor
    func reset() {
        route = .placeholder
        isReady = false
        routeBuilt = false
        unlockedPlace = nil
        UserDefaults.standard.removeObject(forKey: key)
    }

    // MARK: – Persistence

    private func save() {
        if let data = try? JSONEncoder().encode(route) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let saved = try? JSONDecoder().decode(Route.self, from: data),
              !saved.places.isEmpty else { return }
        route = saved
        isReady = true
        // No marcamos routeBuilt=true para que siempre se refresque del API
    }
}
