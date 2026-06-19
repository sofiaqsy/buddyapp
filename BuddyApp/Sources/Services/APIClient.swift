import Foundation

// MARK: – API Client
// All communication with buddy-core backend

final class APIClient {

    static let shared = APIClient()

    let baseURL = "https://buddy-core-504b393f8333.herokuapp.com/v1"
    private let anonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZpcmhjamZ1Z2Zoa3Nrenpxa2NlIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODEwMjI5MzMsImV4cCI6MjA5NjU5ODkzM30.E4mk6bcNal61wLN6zvj2TVgSoVdo2ka_2OdX56jBwsk"
    private let supabaseURL = "https://virhcjfugfhkskzzqkce.supabase.co"

    private var headers: [String: String] {
        // Use user's access token if available, otherwise fall back to anon key
        let token = AuthService.shared.accessToken ?? anonKey
        return [
            "Content-Type":  "application/json",
            "Authorization": "Bearer \(token)"
        ]
    }

    private init() {}

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

        // Auto-refresh on 401 then retry once (WhatsApp-style permanent session)
        if http.statusCode == 401, !isRetry {
            let refreshed = await AuthService.shared.tryRefresh()
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

        return try JSONDecoder.buddy.decode(T.self, from: data)
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
            let refreshed = await AuthService.shared.tryRefresh()
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

    func fetchDestinations() async throws -> [APIDestination] {
        try await request(path: "/destinations")
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
        userId: String,
        destinationId: String,
        title: String?,
        arrivalAt: Date?,
        knowsHowToGet: Bool = false,
        hasLodging: Bool = false
    ) async throws -> APIJourney {
        var body: [String: Any] = [
            "user_id": userId,
            "destination_id": destinationId,
            "knows_how_to_get": knowsHowToGet,
            "has_lodging": hasLodging
        ]
        if let title { body["title"] = title }
        if let arrivalAt { body["arrival_at"] = ISO8601DateFormatter().string(from: arrivalAt) }
        return try await request(path: "/journeys", method: "POST", body: body)
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
        // 1. Subir todas las portadas EN PARALELO — con N páginas el tiempo
        //    total es ~1 subida, no N subidas encadenadas
        let results: [(Int, String)] = await withTaskGroup(of: (Int, String)?.self) { group in
            for (index, page) in pages.enumerated() {
                group.addTask {
                    guard let filename = page.thumbnailFileName,
                          let image = MemoirPersistence.shared.loadThumbnail(filename, journeyId: journeyId),
                          let data = image.jpegData(compressionQuality: 0.82) else { return nil }
                    let path = "memoirs/\(journeyId)/page_\(index).jpg"
                    guard let url = try? await self.uploadToStorage(bucket: "memoir-photos", path: path, data: data) else { return nil }
                    return (index, url)
                }
            }
            var collected: [(Int, String)] = []
            for await r in group { if let r { collected.append(r) } }
            return collected
        }
        let pagePayload: [[String: Any]] = results
            .sorted { $0.0 < $1.0 }
            .map { ["page_index": $0.0, "thumbnail_url": $0.1] }

        // 2. Save page URLs to backend
        if !pagePayload.isEmpty {
            try await requestVoid(
                path: "/journeys/\(journeyId)/pages",
                method: "POST",
                body: ["pages": pagePayload] as [String: Any]
            )
        }

        // 3. Mark journey as completed + public
        try await requestVoid(
            path: "/journeys/\(journeyId)",
            method: "PATCH",
            body: ["status": "completed", "is_public": true] as [String: Any]
        )
    }

    func fetchJourneyPages(journeyId: String) async throws -> [APIJourneyPage] {
        try await request(path: "/journeys/\(journeyId)/pages", method: "GET")
    }

    // Upload binary data to Supabase Storage, returns public URL
    private func uploadToStorage(bucket: String, path: String, data: Data) async throws -> String {
        let token = AuthService.shared.accessToken ?? anonKey
        let urlStr = "\(supabaseURL)/storage/v1/object/\(bucket)/\(path)"
        guard let url = URL(string: urlStr) else { throw APIError.unknown }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        req.setValue("origin", forHTTPHeaderField: "x-upsert")  // overwrite if exists
        req.httpBody = data

        let (_, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw APIError.unknown
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

    func likeJourney(journeyId: String, userId: String) async throws {
        let _: EmptyResponse = try await request(
            path: "/journeys/\(journeyId)/like",
            method: "POST",
            body: ["user_id": userId]
        )
    }

    // MARK: – Users

    func fetchUser(id: String) async throws -> APIUser {
        try await request(path: "/users/\(id)")
    }

    func fetchUserStickers(userId: String) async throws -> [APIUserSticker] {
        try await request(path: "/users/\(userId)/stickers")
    }

    struct StickerUnlockResponse: Decodable {
        let ok: Bool
        let alreadyUnlocked: Bool
        let sticker: APIStickerCatalog
    }

    func unlockStickerByQR(stickerId: String) async throws -> StickerUnlockResponse {
        try await request(path: "/stickers/\(stickerId)/unlock", method: "POST")
    }

    func fetchUserJourneys(userId: String) async throws -> [APIJourney] {
        try await request(path: "/users/\(userId)/journeys")
    }

    func updateUserBio(userId: String, bio: String) async throws {
        try await requestVoid(path: "/users/\(userId)", method: "PATCH", body: ["bio": bio])
    }

    func uploadAvatar(userId: String, imageData: Data) async throws -> String {
        let path = "avatars/\(userId).jpg"
        let url = try await uploadToStorage(bucket: "memoir-photos", path: path, data: imageData)
        try await requestVoid(path: "/users/\(userId)", method: "PATCH", body: ["avatar_url": url])
        return url
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

    func createHelpRequest(travelerId: String, destinationId: String, category: String, description: String?, arrivalAt: Date?) async throws -> APIHelpRequest {
        var body: [String: Any] = [
            "traveler_id": travelerId,
            "destination_id": destinationId,
            "category": category
        ]
        if let description { body["description"] = description }
        if let arrivalAt { body["arrival_at"] = ISO8601DateFormatter().string(from: arrivalAt) }
        return try await request(path: "/matching/request", method: "POST", body: body)
    }

    func fetchOpenRequests(destinationId: String) async throws -> [APIHelpRequest] {
        try await request(path: "/matching/requests/\(destinationId)")
    }

    /// Cancela la solicitud de ayuda (is_active=false) → deja de mostrarse a buddies
    func cancelHelpRequest(requestId: String) async throws {
        try await requestVoid(path: "/matching/request/\(requestId)", method: "DELETE")
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

    func acceptRequest(requestId: String, buddyId: String) async throws -> APIMatch {
        try await request(
            path: "/matching/match",
            method: "POST",
            body: ["request_id": requestId, "buddy_id": buddyId]
        )
    }

    func updateMatchStatus(matchId: String, status: String) async throws -> APIMatch {
        try await request(
            path: "/matching/match/\(matchId)",
            method: "PATCH",
            body: ["status": status]
        )
    }

    func fetchMatches(userId: String) async throws -> [APIMatch] {
        try await request(path: "/matching/matches/\(userId)")
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

    func sendMessage(matchId: String, senderId: String, content: String, type: String = "text", audioUrl: String? = nil) async throws -> APIMessage {
        var body: [String: Any] = ["sender_id": senderId, "content": content, "type": type]
        if let audioUrl { body["audio_url"] = audioUrl }
        return try await request(path: "/messages/\(matchId)", method: "POST", body: body)
    }

    func markMessagesRead(matchId: String) async {
        guard let userId = AuthService.shared.userId else { return }
        try? await requestVoid(path: "/messages/\(matchId)/read", method: "PATCH", body: ["reader_id": userId])
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
