import Foundation
import CoreLocation
import Combine

// Lo que sabe mostrar TripDetailGate después de llamar ensureLoaded(for:).
// "No hay guía" no es un error — es un estado válido para destinos GPS libres.
enum MapLoadState: Equatable {
    case loading
    case guideAvailable                      // ruta con spots curados — TripDetailView completo
    case noGuide(lat: Double, lng: Double)   // sin spots pero tenemos coords — mapa centrado
    case noData                              // sin guía ni coordenadas — mensaje informativo
    case error(String)
}

final class RouteStore: ObservableObject {
    @Published var route: Route = .placeholder
    @Published var unlockedPlace: Place?
    @Published var isReady = false
    @Published var isLoading = false
    @Published var apiError: String?

    private let key = "buddyapp.route.v5"
    private var routeBuilt = false

    // Identifica qué ruta está cargada actualmente.
    // Formato: "dest:<destinationId>" | "place:<placeId>"
    private(set) var loadedKey: String? = nil

    // Dedup: si hay un fetch en vuelo para la misma key, la segunda
    // llamada espera su resultado en lugar de lanzar un fetch paralelo.
    private var fetchingTask: Task<MapLoadState, Never>? = nil
    private var fetchingKey: String? = nil

    init() { load() }

    func buildRouteIfNeeded(near origin: CLLocationCoordinate2D) {
        guard !routeBuilt else { return }
        routeBuilt = true
        Task { await fetchDestinationFromAPI() }
    }

    // MARK: – Public API: ensureLoaded(for:)

    /// Punto de entrada único para las vistas. RouteStore decide internamente
    /// qué tipo de viaje es y qué cargar — las vistas no necesitan saber nada.
    @MainActor
    func ensureLoaded(for journey: APIJourney) async -> MapLoadState {
        let placeId  = journey.placeId ?? journey.place?.id
        let destId   = journey.destinationId ?? journey.destination?.id

        // Decidir qué cargar y qué key usar para el caché/dedup
        if let placeId {
            return await _ensureLoaded(key: "place:\(placeId)") {
                await self._fetchPlaceState(placeId: placeId, journey: journey)
            }
        } else if let destId {
            return await _ensureLoaded(key: "dest:\(destId)") {
                await self._fetchDestState(destId: destId)
            }
        } else if let lat = journey.destination?.lat, let lng = journey.destination?.lng {
            print("🗺️ [RouteStore] sin guía, solo coords del destination ref")
            return .noGuide(lat: lat, lng: lng)
        } else {
            print("🗺️ [RouteStore] sin guía ni coordenadas para journey=\(journey.id.prefix(8))")
            return .noData
        }
    }

    /// Dedup interno: si ya hay un fetch en vuelo para la misma key, espera
    /// su resultado en lugar de disparar un segundo request.
    @MainActor
    private func _ensureLoaded(key: String, fetch: @escaping () async -> MapLoadState) async -> MapLoadState {
        // Caché hit
        if loadedKey == key, isReady {
            print("🗺️ [RouteStore] caché válido para \(key) — sin fetch")
            return .guideAvailable
        }
        // Fetch en vuelo para la misma key — esperar
        if fetchingKey == key, let task = fetchingTask {
            print("🗺️ [RouteStore] fetch en vuelo para \(key) — esperando")
            return await task.value
        }
        // Cache miss: limpiar datos del destino anterior inmediatamente
        isReady = false
        fetchingKey = key
        let task = Task<MapLoadState, Never> { await fetch() }
        fetchingTask = task
        let result = await task.value
        fetchingTask = nil
        fetchingKey = nil
        return result
    }

    // MARK: – Fetch internos (privados)

    @MainActor
    private func _fetchDestState(destId: String) async -> MapLoadState {
        print("🗺️ [RouteStore] fetch destination destId=\(destId.prefix(8))")
        isLoading = true
        defer { isLoading = false }
        do {
            let dest = try await APIClient.shared.fetchDestination(id: destId)
            let places: [Place] = (dest.places ?? []).map { $0.asPlace }
            print("🗺️ [RouteStore] destination=\(dest.name) lat=\(dest.lat) lng=\(dest.lng) spots=\(places.count)")
            route = Route(
                id: UUID(uuidString: dest.id) ?? UUID(),
                title: dest.name,
                subtitle: dest.city,
                city: dest.city,
                places: places,
                radiusMeters: dest.radiusMeters,
                centerLat: places.isEmpty ? dest.lat : nil,
                centerLng: places.isEmpty ? dest.lng : nil
            )
            loadedKey = "dest:\(destId)"
            isReady = true
            save()
            return .guideAvailable
        } catch {
            apiError = error.localizedDescription
            return .error(error.localizedDescription)
        }
    }

    @MainActor
    private func _fetchPlaceState(placeId: String, journey: APIJourney) async -> MapLoadState {
        print("🗺️ [RouteStore] fetch place placeId=\(placeId.prefix(8))")
        isLoading = true
        defer { isLoading = false }
        do {
            let guide = try await APIClient.shared.fetchPlaceGuide(id: placeId, source: "place")
            let places: [Place] = (guide.spots ?? []).map { $0.asPlace }
            // Coords: preferir las del guide; fallback al destination ref del journey
            let lat = guide.lat ?? journey.destination?.lat
            let lng = guide.lng ?? journey.destination?.lng
            print("🗺️ [RouteStore] place guide.lat=\(guide.lat.map{String($0)} ?? "nil") guide.lng=\(guide.lng.map{String($0)} ?? "nil") → lat=\(lat.map{String($0)} ?? "nil")")

            let destName: String?
            let destCity: String?
            if let destId = guide.destId {
                let dest = try? await APIClient.shared.fetchDestination(id: destId)
                destName = dest?.name
                destCity = dest?.city
            } else {
                destName = journey.destination?.name ?? journey.place?.name
                destCity = nil
            }
            // Sin coords ni en guide ni en journey → .noData (no hay nada que mostrar)
            guard lat != nil || !places.isEmpty else { return .noData }
            route = Route(
                id: UUID(uuidString: placeId) ?? UUID(),
                title: destName ?? placeId,
                subtitle: destCity ?? "",
                city: destCity ?? "",
                places: places,
                centerLat: lat,
                centerLng: lng
            )
            loadedKey = "place:\(placeId)"
            isReady = true
            return .guideAvailable
        } catch {
            apiError = error.localizedDescription
            return .error(error.localizedDescription)
        }
    }

    // MARK: – Legacy: fetchDestinationFromAPI (buildRouteIfNeeded lo sigue usando)

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
            let places: [Place] = (dest.places ?? []).map { $0.asPlace }
            guard !places.isEmpty else { return }
            route = Route(
                id: UUID(uuidString: dest.id) ?? UUID(),
                title: dest.name,
                subtitle: dest.city,
                city: dest.city,
                places: places,
                radiusMeters: dest.radiusMeters
            )
            loadedKey = "dest:\(destId)"
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
        loadedKey = nil
        fetchingKey = nil
        fetchingTask = nil
        unlockedPlace = nil
        UserDefaults.standard.removeObject(forKey: key)
    }

    // MARK: – Persistence

    private func save() {
        let snapshot = route
        Task(priority: .utility) {
            if let data = try? JSONEncoder().encode(snapshot) {
                UserDefaults.standard.set(data, forKey: self.key)
            }
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
