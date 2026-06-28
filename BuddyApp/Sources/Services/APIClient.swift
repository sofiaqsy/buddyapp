import Foundation

// MARK: – API Client
// All communication with buddy-core backend

final class APIClient {

    static let shared = APIClient()

    let baseURL = "https://buddy-core-504b393f8333.herokuapp.com/v1"
    private let anonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZpcmhjamZ1Z2Zoa3Nrenpxa2NlIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODEwMjI5MzMsImV4cCI6MjA5NjU5ODkzM30.E4mk6bcNal61wLN6zvj2TVgSoVdo2ka_2OdX56jBwsk"
    private let supabaseURL = "https://virhcjfugfhkskzzqkce.supabase.co"

    // Deduplicate concurrent refresh calls — only one in-flight at a time.
    private var refreshTask: Task<Bool, Never>?

    private var headers: [String: String] {
        // Priority: Traveler JWT (guest or verified) → anon key
        let token = TravelerService.shared.token ?? anonKey
        return [
            "Content-Type":  "application/json",
            "Authorization": "Bearer \(token)"
        ]
    }

    private init() {}

    // Coalesces concurrent refresh attempts into one network call.
    private func sharedRefresh() async -> Bool {
        if let existing = refreshTask { return await existing.value }
        let task = Task<Bool, Never> {
            defer { refreshTask = nil }
            if let tid = TravelerService.shared.travelerId,
               (try? await TravelerService.shared.forceRefresh(travelerId: tid)) != nil {
                return true
            }
            let ok = await AuthService.shared.tryRefresh()
            if !ok {
                // All refresh paths exhausted. forceRefresh already called clearSession()
                // if it had a chance to run; call it again defensively so Session.hasSession
                // is guaranteed false before we fire the notification.
                TravelerService.shared.clearSession()
                await MainActor.run {
                    NotificationCenter.default.post(name: .sessionExpired, object: nil)
                }
            }
            return ok
        }
        refreshTask = task
        return await task.value
    }

    // MARK: – Generic request

    private func request<T: Decodable>(
        path: String,
        method: String = "GET",
        body: [String: Any]? = nil,
        isRetry: Bool = false
    ) async throws -> T {
        guard let url = URL(string: baseURL + path) else {
            throw APIError.invalidURL
        }

        // Ensure a Traveler session exists for write operations on traveler-owned resources.
        // Read-only paths (GET /destinations, GET /feed, etc.) work with the anon key.
        // This creates a guest Traveler lazily on the first meaningful action.
        let writeMethods = ["POST", "PATCH", "PUT", "DELETE"]
        let needsIdentity = writeMethods.contains(method) && !Session.hasSession
        print("🌐 [APIClient] \(method) \(path) — Session.hasSession=\(Session.hasSession) needsIdentity=\(needsIdentity)")
        if needsIdentity, !TravelerService.shared.hasSession {
            print("🌐 [APIClient] → lazy session creation triggered by \(method) \(path)")
            let token = try await TravelerService.shared.ensureSession()
            print("🧳 [APIClient] guest session created → token prefix: \(token.prefix(20))…")
            await MainActor.run {
                // Sync AuthState so views react (e.g. tabs update their empty state)
                NotificationCenter.default.post(name: .travelerSessionCreated, object: nil)
            }
        }

        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
        req.httpMethod = method
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }

        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await URLSession.shared.data(for: req)

        guard let http = response as? HTTPURLResponse else {
            throw APIError.unknown
        }

        if http.statusCode == 401, !isRetry {
            let refreshed = await sharedRefresh()
            if refreshed {
                return try await request(path: path, method: method, body: body, isRetry: true)
            } else {
                throw APIError.server(401, "Session expired")
            }
        }

        guard (200..<300).contains(http.statusCode) else {
            let msg = (try? JSONDecoder().decode(APIErrorResponse.self, from: data))?.error
            throw APIError.server(http.statusCode, msg ?? "Unknown error")
        }

        do {
            return try JSONDecoder.buddy.decode(T.self, from: data)
        } catch {
            #if DEBUG
            let preview = String(data: data.prefix(500), encoding: .utf8) ?? "<non-UTF8>"
            print("❌ [APIClient] decode \(T.self) failed [\(path)]: \(error)\nraw: \(preview)")
            #endif
            throw error
        }
    }

    func requestVoid(
        path: String,
        method: String = "PATCH",
        body: [String: Any]? = nil,
        isRetry: Bool = false
    ) async throws {
        guard let url = URL(string: baseURL + path) else { throw APIError.invalidURL }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
        req.httpMethod = method
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (_, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw APIError.unknown }

        if http.statusCode == 401, !isRetry {
            let refreshed = await sharedRefresh()
            if refreshed {
                try await requestVoid(path: path, method: method, body: body, isRetry: true)
            } else {
                throw APIError.server(401, "Session expired")
            }
            return
        }

        guard (200..<300).contains(http.statusCode) else { throw APIError.unknown }
    }

    // MARK: – Destinations

    // Respuesta paginada del backend { items, total, limit, offset }
    private struct DestinationsPage: Decodable {
        let items: [APIDestination]
        let total: Int
    }

    // Carga inicial: primeras 50 destinaciones (suficiente para pickers rápidos)
    func fetchDestinations() async throws -> [APIDestination] {
        let page: DestinationsPage = try await request(path: "/destinations?limit=50")
        return page.items
    }

    // Búsqueda paginada — usada por el DestinationPickerSheet
    func searchDestinations(query: String, limit: Int = 20, offset: Int = 0) async throws -> (items: [APIDestination], total: Int) {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let path = "/destinations?q=\(encoded)&limit=\(limit)&offset=\(offset)"
        let page: DestinationsPage = try await request(path: path)
        return (page.items, page.total)
    }

    func fetchDestination(id: String) async throws -> APIDestination {
        try await request(path: "/destinations/\(id)")
    }

    // MARK: – Places

    func fetchPlaces(destinationId: String) async throws -> [APIPlace] {
        try await request(path: "/places?destination_id=\(destinationId)")
    }

    // MARK: – Favorites (per-user)

    /// Favoritos POR TRIP — lista de place_id (strings) del journey.
    func fetchFavorites(journeyId: String) async throws -> [String] {
        try await request(path: "/favorites/\(journeyId)")
    }
    func addFavorite(journeyId: String, placeId: String) async throws {
        try await requestVoid(path: "/favorites/\(journeyId)/\(placeId)", method: "POST")
    }
    func removeFavorite(journeyId: String, placeId: String) async throws {
        try await requestVoid(path: "/favorites/\(journeyId)/\(placeId)", method: "DELETE")
    }

    // MARK: – Journeys

    func fetchJourneyFeed() async throws -> [APIJourney] {
        try await request(path: "/journeys")
    }

    func fetchJourney(id: String) async throws -> APIJourney {
        try await request(path: "/journeys/\(id)")
    }

    func createJourney(
        destinationId: String,
        title: String?,
        arrivalAt: Date?,
        knowsHowToGet: Bool = false,
        hasLodging: Bool = false
    ) async throws -> APIJourney {
        // Backend derives owner from the Traveler JWT — no identity param in body.
        var body: [String: Any] = [
            "destination_id":   destinationId,
            "knows_how_to_get": knowsHowToGet,
            "has_lodging":      hasLodging
        ]
        if let title     { body["title"]      = title }
        if let arrivalAt { body["arrival_at"] = ISO8601DateFormatter().string(from: arrivalAt) }
        return try await request(path: "/journeys", method: "POST", body: body)
    }

    /// Garantiza que exista un Trip para el destino dado — reusa uno activo/en
    /// planificación o lo crea automáticamente. El Trip deja de ser una tarea
    /// del usuario: pedir ayuda nunca exige crearlo a mano.
    /// Reusa fetchUserJourneys / createJourney / updateJourneyStatus.
    func ensureActiveTrip(destinationId: String) async throws -> APIJourney {
        // Always use the Traveler-first path — backend resolves owner from JWT.
        let journeys: [APIJourney] = (try? await fetchTravelerJourneys()) ?? []

        if let existing = journeys.first(where: {
            ($0.destination?.id ?? $0.destinationId) == destinationId
                && ["active", "planning"].contains($0.status)
        }) {
            if existing.status != "active" {
                try? await updateJourneyStatus(journeyId: existing.id, status: "active")
            }
            return existing
        }

        let created = try await createJourney(destinationId: destinationId, title: nil, arrivalAt: nil)
        try? await updateJourneyStatus(journeyId: created.id, status: "active")
        return created
    }

    func updateJourney(journeyId: String, arrivalAt: Date? = nil, knowsHowToGet: Bool? = nil, hasLodging: Bool? = nil) async throws -> APIJourney {
        var body: [String: Any] = [:]
        if let arrivalAt { body["arrival_at"] = ISO8601DateFormatter().string(from: arrivalAt) }
        if let knowsHowToGet { body["knows_how_to_get"] = knowsHowToGet }
        if let hasLodging { body["has_lodging"] = hasLodging }
        return try await request(path: "/journeys/\(journeyId)", method: "PATCH", body: body)
    }

    func cancelJourney(journeyId: String) async throws {
        try await requestVoid(path: "/journeys/\(journeyId)", method: "DELETE")
    }

    func fetchPublicJourneys(limit: Int = 20) async throws -> [APIJourney] {
        try await request(path: "/journeys?limit=\(limit)", method: "GET")
    }

    /// Feed "Historias de viajeros" con cursor pagination + ranking servidor.
    func fetchStories(destinationId: String?, lat: Double?, lng: Double?,
                      cursor: String?, limit: Int = 10) async throws -> FeedPage {
        var q = "limit=\(limit)"
        if let d = destinationId { q += "&destination_id=\(d)" }
        if let lat, let lng { q += "&lat=\(lat)&lng=\(lng)" }
        if let c = cursor, let enc = c.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            q += "&cursor=\(enc)"
        }
        return try await request(path: "/feed/stories?\(q)")
    }

    func updateJourneyStatus(journeyId: String, status: String) async throws {
        try await requestVoid(path: "/journeys/\(journeyId)", method: "PATCH", body: ["status": status])
    }

    func publishJourney(journeyId: String, pages: [CollagePage]) async throws {
        try await uploadAndSavePages(journeyId: journeyId, pages: pages)
        // Marca el journey como completado + público
        try await requestVoid(
            path: "/journeys/\(journeyId)",
            method: "PATCH",
            body: ["status": "completed", "is_public": true] as [String: Any]
        )
    }

    /// Sube las portadas de un journey y guarda sus URLs (sin tocar el status).
    /// Reutilizable para publicar journey por journey dentro de un trip.
    private func uploadAndSavePages(journeyId: String, pages: [CollagePage]) async throws {
        print("⬆️ [uploadAndSavePages] journeyId=\(journeyId) pages.count=\(pages.count)")
        let results: [(Int, String)] = await withTaskGroup(of: (Int, String)?.self) { group in
            for (index, page) in pages.enumerated() {
                group.addTask {
                    print("⬆️ [uploadAndSavePages] page[\(index)] id=\(page.id) thumbFile=\(page.thumbnailFileName ?? "NIL")")
                    guard let filename = page.thumbnailFileName else {
                        print("⬆️ [uploadAndSavePages] page[\(index)] SKIP — thumbnailFileName is nil")
                        return nil
                    }
                    guard let image = MemoirPersistence.shared.loadThumbnail(filename, journeyId: journeyId) else {
                        print("⬆️ [uploadAndSavePages] page[\(index)] SKIP — loadThumbnail returned nil for file=\(filename)")
                        return nil
                    }
                    guard let data = image.jpegData(compressionQuality: 0.82) else {
                        print("⬆️ [uploadAndSavePages] page[\(index)] SKIP — jpegData failed (image size=\(image.size))")
                        return nil
                    }
                    print("⬆️ [uploadAndSavePages] page[\(index)] uploading \(data.count) bytes → memoir-photos/memoirs/\(journeyId)/page_\(index).jpg")
                    let path = "memoirs/\(journeyId)/page_\(index).jpg"
                    do {
                        guard let url = try? await self.uploadToStorage(bucket: "memoir-photos", path: path, data: data) else {
                            print("⬆️ [uploadAndSavePages] page[\(index)] UPLOAD FAILED — uploadToStorage returned nil")
                            return nil
                        }
                        print("⬆️ [uploadAndSavePages] page[\(index)] UPLOAD OK → \(url)")
                        return (index, url)
                    }
                }
            }
            var collected: [(Int, String)] = []
            for await r in group { if let r { collected.append(r) } }
            return collected
        }
        print("⬆️ [uploadAndSavePages] uploaded \(results.count)/\(pages.count) page(s)")
        let pagePayload: [[String: Any]] = results
            .sorted { $0.0 < $1.0 }
            .map { ["page_index": $0.0, "thumbnail_url": $0.1] }

        if !pagePayload.isEmpty {
            print("⬆️ [uploadAndSavePages] POSTing \(pagePayload.count) page(s) to /journeys/\(journeyId)/pages")
            try await requestVoid(
                path: "/journeys/\(journeyId)/pages",
                method: "POST",
                body: ["pages": pagePayload] as [String: Any]
            )
            print("⬆️ [uploadAndSavePages] POST /pages SUCCESS")
        } else {
            print("⬆️ [uploadAndSavePages] pagePayload is EMPTY — POST /pages skipped entirely")
        }
    }

    // MARK: - Trip (contenedor de varios lugares = una publicación)

    /// Publica el VIAJE completo: sube las portadas de cada lugar y cierra el
    /// trip → todos sus journeys quedan completados como UNA sola historia.
    func publishTrip(tripId: String, places: [(journeyId: String, pages: [CollagePage])]) async throws {
        for place in places {
            try await uploadAndSavePages(journeyId: place.journeyId, pages: place.pages)
        }
        try await requestVoid(
            path: "/trips/\(tripId)",
            method: "PATCH",
            body: ["status": "completed", "is_public": true] as [String: Any]
        )
    }

    /// Elimina el viaje completo: borra el trip, sus lugares (journeys) y cierra
    /// los apoyos (match) en curso.
    func cancelTrip(tripId: String) async throws {
        try await requestVoid(path: "/trips/\(tripId)", method: "DELETE")
    }

    func fetchJourneyPages(journeyId: String) async throws -> [APIJourneyPage] {
        try await request(path: "/journeys/\(journeyId)/pages", method: "GET")
    }

    // MARK: – Avatar

    /// Upload a traveler avatar via buddy-core.
    /// The backend owns all Storage interaction — this method knows nothing about
    /// buckets, paths, RLS, or service-role keys.
    func uploadAvatar(imageData: Data) async throws -> String {
        let boundary = "BuddyBoundary.\(UUID().uuidString)"
        var body = Data()
        body.appendMultipart(boundary: boundary, name: "avatar",
                             filename: "avatar.jpg", mime: "image/jpeg", data: imageData)
        body.append("--\(boundary)--\r\n")

        let token = TravelerService.shared.token ?? anonKey
        guard let url = URL(string: baseURL + "/users/me/avatar") else { throw APIError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = body

        print("🖼️ [APIClient] POST /users/me/avatar (\(imageData.count / 1024) KB)…")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw APIError.unknown }

        guard (200..<300).contains(http.statusCode) else {
            let preview = String(data: data.prefix(200), encoding: .utf8) ?? ""
            print("❌ [APIClient] POST /users/me/avatar → \(http.statusCode): \(preview)")
            let msg = (try? JSONDecoder().decode(APIErrorResponse.self, from: data))?.error
            throw APIError.server(http.statusCode, msg ?? "Upload failed")
        }

        struct AvatarResponse: Decodable { let avatarUrl: String }
        do {
            let resp = try JSONDecoder.buddy.decode(AvatarResponse.self, from: data)
            print("🖼️ [APIClient] ✅ avatar uploaded → \(resp.avatarUrl.suffix(50))")
            return resp.avatarUrl
        } catch {
            print("❌ [APIClient] decode AvatarResponse: \(error)\nraw: \(String(data: data.prefix(300), encoding: .utf8) ?? "")")
            throw error
        }
    }

    // MARK: – Storage (memoir photos only — pending migration to backend)
    // TODO: route memoir photo uploads through buddy-core, same as avatars.
    // Until then this method remains here for uploadAndSavePages().

    private func uploadToStorage(bucket: String, path: String, data: Data) async throws -> String {
        let token = AuthService.shared.accessToken ?? anonKey
        let urlStr = "\(supabaseURL)/storage/v1/object/\(bucket)/\(path)"
        guard let url = URL(string: urlStr) else { throw APIError.unknown }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        req.setValue("true", forHTTPHeaderField: "x-upsert")
        req.httpBody = data
        let (body, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw APIError.unknown }
        let ok = (200..<300).contains(http.statusCode)
        if !ok {
            print("❌ [Storage] \(http.statusCode) \(bucket)/\(path) — \(String(data: body.prefix(200), encoding: .utf8) ?? "")")
            throw APIError.server(http.statusCode, "Storage upload failed")
        }
        return "\(supabaseURL)/storage/v1/object/public/\(bucket)/\(path)"
    }

    func collectPlace(journeyId: String, placeId: String) async throws -> APIJourneyPlace {
        try await request(
            path: "/journeys/\(journeyId)/collect",
            method: "POST",
            body: ["place_id": placeId]
        )
    }

    func likeJourney(journeyId: String) async throws {
        // Backend derives identity from the JWT — no body param needed.
        let _: EmptyResponse = try await request(
            path: "/journeys/\(journeyId)/like",
            method: "POST",
            body: [:]
        )
    }

    // MARK: – Users

    func fetchUser(id: String) async throws -> APIUser {
        try await request(path: "/users/\(id)")
    }

    /// Perfil del usuario autenticado — resuelve la identidad desde el JWT.
    /// Válido para Traveler JWT y Supabase JWT. Usar siempre en lugar de
    /// fetchUser(id:) cuando el id puede ser un auth_user_id.
    func fetchCurrentUser() async throws -> APIUser {
        try await request(path: "/users/me")
    }

    func fetchBuddyMe() async throws -> APIBuddyMe {
        try await request(path: "/buddy/me")
    }

    /// El usuario se convierte en buddy (crea su perfil en verificación).
    func becomeBuddy() async throws -> APIBuddyMe {
        try await request(path: "/buddy/me", method: "POST", body: [:])
    }

    /// Actualiza preferencias del buddy (especialidades y/o zona).
    func updateBuddyMe(specialties: [String]? = nil,
                       destinationIds: [String]? = nil,
                       activeZoneIds: [String]? = nil,
                       isAvailable: Bool? = nil) async throws -> APIBuddyMe {
        var body: [String: Any] = [:]
        if let specialties    { body["specialties"]     = specialties }
        if let destinationIds { body["destination_ids"] = destinationIds }
        if let activeZoneIds  { body["active_zone_ids"]  = activeZoneIds }
        if let isAvailable    { body["is_available"]    = isAvailable }
        return try await request(path: "/buddy/me", method: "PATCH", body: body)
    }

    func fetchUserStickers(travelerId: String) async throws -> [APIUserSticker] {
        try await request(path: "/users/\(travelerId)/stickers")
    }

    struct StickerUnlockResponse: Decodable {
        let ok: Bool
        let alreadyUnlocked: Bool
        let sticker: APIStickerCatalog
    }

    func unlockStickerByQR(stickerId: String) async throws -> StickerUnlockResponse {
        try await request(path: "/stickers/\(stickerId)/unlock", method: "POST")
    }

    func fetchUserJourneys(travelerId: String) async throws -> [APIJourney] {
        try await request(path: "/users/\(travelerId)/journeys")
    }

    /// Journeys del Traveler actual (guest o verified) — no requiere userId,
    /// el backend lo resuelve desde el traveler_id en el JWT.
    func fetchTravelerJourneys() async throws -> [APIJourney] {
        try await request(path: "/travelers/me/journeys")
    }

    /// Publicaciones del perfil AGRUPADAS por viaje (una por trip, con momentos
    /// y lugares agregados). Devuelve una página cursor-based (max 12 por página).
    func fetchUserTrips(travelerId: String, cursor: String? = nil) async throws -> FeedPage {
        var path = "/users/\(travelerId)/trips"
        if let cursor, let encoded = cursor.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            path += "?cursor=\(encoded)"
        }
        return try await request(path: path)
    }

    func updateUserBio(travelerId: String, bio: String) async throws {
        try await requestVoid(path: "/users/\(travelerId)", method: "PATCH", body: ["bio": bio])
    }

    func deleteAccount() async throws {
        try await requestVoid(path: "/users/me", method: "DELETE")
    }

    func reportUser(reportedUserId: String, reason: String, details: String? = nil, matchId: String? = nil) async throws {
        var body: [String: Any] = ["reported_user_id": reportedUserId, "reason": reason]
        if let d = details  { body["details"]  = d }
        if let m = matchId  { body["match_id"] = m }
        try await requestVoid(path: "/users/report", method: "POST", body: body)
    }

    // MARK: – Generic helpers (for services like PushService)

    func post(path: String, body: [String: Any]) async throws -> [String: Any] {
        struct AnyResponse: Decodable {}
        _ = try? await requestVoid(path: path, method: "POST", body: body)
        return [:]
    }

    func delete(path: String, body: [String: Any]? = nil) async throws {
        try await requestVoid(path: path, method: "DELETE", body: body)
    }

    // MARK: – Matching

    // Ownership is derived from the Traveler JWT by the backend — never passed in the body.
    func createHelpRequest(destinationId: String, journeyId: String? = nil, category: String, description: String?, arrivalAt: Date?) async throws -> APIHelpRequest {
        var body: [String: Any] = [
            "destination_id": destinationId,
            "category": category
        ]
        if let journeyId    { body["journey_id"]  = journeyId }
        if let description  { body["description"] = description }
        if let arrivalAt    { body["arrival_at"]  = ISO8601DateFormatter().string(from: arrivalAt) }
        return try await request(path: "/matching/request", method: "POST", body: body)
    }

    func fetchOpenRequests(destinationId: String) async throws -> [APIHelpRequest] {
        try await request(path: "/matching/requests/\(destinationId)")
    }

    /// Cancela la solicitud de ayuda (is_active=false) → deja de mostrarse a buddies
    func cancelHelpRequest(requestId: String) async throws {
        try await requestVoid(path: "/matching/request/\(requestId)", method: "DELETE")
    }

    /// Estado actual del matching para una solicitud.
    /// Dispara la escalación lazy en el backend si el candidato actual expiró.
    func fetchMatchingStatus(requestId: String) async throws -> APIMatchingStatus {
        try await request(path: "/matching/status/\(requestId)")
    }

    /// Ayudas recién completadas en un destino (comunidad viva)
    func fetchRecentHelp(destinationId: String) async throws -> [APIRecentHelp] {
        let path = "/matching/recent-help/\(destinationId)"
        print("🌐 [APIClient] GET \(baseURL)\(path)")
        let result: [APIRecentHelp] = try await request(path: path)
        print("🌐 [APIClient] recent-help → \(result.count) records: \(result.map { $0.id })")
        return result
    }

    func fetchBuddyCount(destinationId: String) async throws -> Int {
        struct CountResponse: Decodable { let count: Int }
        let resp: CountResponse = try await request(path: "/matching/available/\(destinationId)")
        return resp.count
    }

    // buddy_id is derived from the Traveler JWT by the backend — not accepted from the body.
    func acceptRequest(requestId: String) async throws -> APIMatch {
        try await request(
            path: "/matching/match",
            method: "POST",
            body: ["request_id": requestId]
        )
    }

    func updateMatchStatus(matchId: String, status: String) async throws -> APIMatch {
        try await request(
            path: "/matching/match/\(matchId)",
            method: "PATCH",
            body: ["status": status]
        )
    }

    // No path parameter — backend resolves ownership from the JWT.
    func fetchMatches() async throws -> [APIMatch] {
        try await request(path: "/matching/matches")
    }

    func fetchMyOffers() async throws -> [APIBuddyOffer] {
        try await request(path: "/matching/my-offers")
    }

    func declineBuddyOffer(requestId: String) async throws {
        // Backend derives buddy_id from the JWT — no body param needed.
        try await requestVoid(
            path: "/matching/decline",
            method: "POST",
            body: ["request_id": requestId]
        )
    }

    /// Envía la encuesta de cierre (feeling + presión comercial) al motor de reputación.
    func submitFeedback(matchId: String, feeling: String, commercialPressure: String) async throws {
        try await requestVoid(
            path: "/matching/feedback",
            method: "POST",
            body: ["match_id": matchId, "feeling": feeling, "commercial_pressure": commercialPressure]
        )
    }

    // MARK: – Messages

    func fetchMessages(matchId: String, limit: Int = 30, before: Date? = nil) async throws -> [APIMessage] {
        var path = "/messages/\(matchId)?limit=\(limit)"
        if let before {
            let iso = ISO8601DateFormatter().string(from: before)
            path += "&before=\(iso.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? iso)"
        }
        return try await request(path: path)
    }

    func sendMessage(matchId: String, content: String, type: String = "text", audioUrl: String? = nil) async throws -> APIMessage {
        // Backend derives sender_id from the JWT — never from the body.
        var body: [String: Any] = ["content": content, "type": type]
        if let audioUrl { body["audio_url"] = audioUrl }
        return try await request(path: "/messages/\(matchId)", method: "POST", body: body)
    }

    func markMessagesRead(matchId: String) async {
        // Backend derives reader_id from the JWT — no guard, no body param needed.
        guard Session.hasSession else { return }
        try? await requestVoid(path: "/messages/\(matchId)/read", method: "PATCH")
    }
}

// MARK: – Errors

enum APIError: LocalizedError {
    case invalidURL
    case server(Int, String)
    case unknown

    var errorDescription: String? {
        switch self {
        case .invalidURL:         return "URL inválida."
        case .server(let c, let m): return "Error \(c): \(m)"
        case .unknown:            return "Error desconocido."
        }
    }
}

private struct APIErrorResponse: Decodable { let error: String }
private struct EmptyResponse: Decodable {}

// MARK: – Multipart form-data helper

private extension Data {
    /// Appends one multipart file part including headers and the file bytes.
    /// Call `append("--\(boundary)--\r\n")` after the last part to close the body.
    mutating func appendMultipart(boundary: String, name: String,
                                  filename: String, mime: String, data: Data) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: \(mime)\r\n\r\n")
        append(data)
        append("\r\n")
    }

    mutating func append(_ string: String) {
        if let d = string.data(using: .utf8) { append(d) }
    }
}

// MARK: – JSON Decoder with date strategy

extension JSONDecoder {
    static let buddy: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .custom { decoder in
            let str = try decoder.singleValueContainer().decode(String.self)
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = f.date(from: str) { return date }
            f.formatOptions = [.withInternetDateTime]
            if let date = f.date(from: str) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid date: \(str)"))
        }
        return d
    }()
}
