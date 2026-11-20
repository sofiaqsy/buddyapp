import XCTest
@testable import BuddyApp

/// Renovación de una cuenta verificada (camino Supabase, /auth/refresh), con
/// almacenes de PRUEBA, servidor falso y un centro de avisos propio: la app
/// real no recibe "sesión expirada" ni pierde su sesión.
final class AuthServiceTests: XCTestCase {
    private let suite = "buddy.tests.auth"
    private var defaults: UserDefaults!
    private var store: SecureStore!
    private var center: NotificationCenter!
    private var traveler: TravelerService!
    private var auth: AuthService!
    private var expired = 0
    private var token: NSObjectProtocol?

    override func setUp() {
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
        store = SecureStore(service: "com.buddyapp.tests.\(UUID().uuidString)", defaults: defaults)
        center = NotificationCenter()
        expired = 0
        token = center.addObserver(forName: .sessionExpired, object: nil, queue: nil) { [weak self] _ in self?.expired += 1 }
        StubURLProtocol.reset()
        let session = StubURLProtocol.session()
        var authRef: AuthService?
        traveler = TravelerService(defaults: defaults, store: store, session: session,
                                   keychainService: "com.buddyapp.tests.kc.\(UUID().uuidString)",
                                   verifiedRefresh: { await authRef?.tryRefresh() ?? false })
        auth = AuthService(defaults: defaults, store: store, session: session, notifications: center, traveler: traveler)
        authRef = auth
    }
    override func tearDown() {
        traveler.clearSession()
        SecureStore.Key.allCases.forEach { store.remove($0) }
        defaults.removePersistentDomain(forName: suite)
        if let token { center.removeObserver(token) }
        StubURLProtocol.reset()
    }

    private func reply(_ status: Int, _ json: String = "{}", delay: TimeInterval = 0) {
        StubURLProtocol.handler = { r in
            guard r.url?.path.hasSuffix("/auth/refresh") == true else { return .init(status: 404) }
            return .init(status: status, body: Data(json.utf8), delay: delay)
        }
    }
    private func calls() -> [URLRequest] { StubURLProtocol.requests.filter { $0.url?.path.hasSuffix("/auth/refresh") == true } }
    private func signedIn(user: String = "U1") {
        store.set("access-old", .accessToken)
        store.set("refresh-old", .refreshToken)
        defaults.set(user, forKey: "buddy.userId")
    }

    func test_noRefreshToken_failsAndAnnouncesExpiry() async {
        let ok = await auth.tryRefresh()
        XCTAssertFalse(ok)
        XCTAssertEqual(expired, 1)
        XCTAssertTrue(calls().isEmpty, "Sin token no se llama al servidor")
    }

    func test_ok_savesTokensAndHydratesTraveler() async throws {
        signedIn()
        reply(200, #"{"access_token":"A2","refresh_token":"R2","user_id":"U1","traveler_id":"T9","traveler_token":"TT9","traveler_status":"verified"}"#)
        let ok = await auth.tryRefresh()
        XCTAssertTrue(ok)
        XCTAssertEqual(store.string(.accessToken), "A2")
        XCTAssertEqual(store.string(.refreshToken), "R2")
        XCTAssertEqual(traveler.travelerId, "T9")
        XCTAssertEqual(traveler.token, "TT9")
        XCTAssertTrue(traveler.isVerified)
        XCTAssertEqual(expired, 0)
        let r = try XCTUnwrap(calls().first)
        XCTAssertEqual(r.httpMethod, "POST")
        XCTAssertEqual(r.timeoutInterval, 15)
    }

    func test_otherUserReturned_forcesLoginAndKeepsTokens() async {
        signedIn(user: "U1")
        reply(200, #"{"access_token":"A2","refresh_token":"R2","user_id":"OTHER"}"#)
        let ok = await auth.tryRefresh()
        XCTAssertFalse(ok)
        XCTAssertEqual(expired, 1)
        XCTAssertEqual(store.string(.accessToken), "access-old", "No se mezclan cuentas")
    }

    func test_okWithoutTravelerIdentity_clearsStaleTravelerToken() async {
        signedIn()
        traveler.hydrate(travelerId: "T1", token: "stale", status: "verified")
        reply(200, #"{"access_token":"A2","refresh_token":"R2","user_id":"U1"}"#)
        let ok = await auth.tryRefresh()
        XCTAssertTrue(ok)
        XCTAssertNil(traveler.token, "El token viejo del viajero no se queda")
        XCTAssertNil(traveler.travelerId)
    }

    func test_rejected_clearsTokensAndAnnouncesExpiry() async {
        signedIn()
        reply(401, #"{"error":"invalid"}"#)
        let ok = await auth.tryRefresh()
        XCTAssertFalse(ok)
        XCTAssertNil(store.string(.accessToken))
        XCTAssertNil(store.string(.refreshToken))
        XCTAssertEqual(expired, 1)
    }

    func test_offline_keepsSession() async {
        signedIn()
        StubURLProtocol.handler = { _ in .init(error: URLError(.notConnectedToInternet)) }
        let ok = await auth.tryRefresh()
        XCTAssertTrue(ok, "Sin señal no se cierra la sesión")
        XCTAssertEqual(store.string(.refreshToken), "refresh-old")
        XCTAssertEqual(expired, 0)
    }

    func test_concurrentRefresh_hitsServerOnce() async {
        signedIn()
        reply(200, #"{"access_token":"A2","refresh_token":"R2","user_id":"U1"}"#, delay: 0.3)
        async let a = auth.tryRefresh()
        async let b = auth.tryRefresh()
        async let c = auth.tryRefresh()
        let r = await [a, b, c]
        XCTAssertEqual(r, [true, true, true])
        XCTAssertEqual(calls().count, 1)
    }

    /// De punta a punta: cuenta verificada sin secret → TravelerService usa
    /// AuthService.tryRefresh → token nuevo del viajero.
    func test_verifiedTraveler_refreshesThroughAuth() async throws {
        signedIn()
        traveler.hydrate(travelerId: "V1", token: "old", status: "verified", secret: nil)
        reply(200, #"{"access_token":"A2","refresh_token":"R2","user_id":"U1","traveler_id":"V1","traveler_token":"NEW","traveler_status":"verified"}"#)
        let t = try await traveler.forceRefresh(travelerId: "V1")
        XCTAssertEqual(t, "NEW")
        XCTAssertFalse(traveler.needsReauth)
    }

    func test_verifiedTraveler_authRejected_keepsAccountAsksLogin() async {
        signedIn()
        traveler.hydrate(travelerId: "V1", token: "old", status: "verified", secret: nil)
        reply(401)
        do { _ = try await traveler.forceRefresh(travelerId: "V1"); XCTFail() }
        catch TravelerError.sessionExpired {}
        catch { XCTFail("\(error)") }
        XCTAssertTrue(traveler.needsReauth)
        XCTAssertEqual(expired, 1)
    }
}
