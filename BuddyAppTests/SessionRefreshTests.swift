import XCTest
@testable import BuddyApp

/// Renovación de sesión (login), con almacenes de PRUEBA y servidor falso.
/// Nunca toca la sesión real de la app en el simulador.
final class TravelerServiceTests: XCTestCase {
    private let suite = "buddy.tests.traveler"
    private var defaults: UserDefaults!
    private var store: SecureStore!
    private var kcService: String!
    private var verifiedResult = false
    private var verifiedNewToken: String?

    private func makeService() -> TravelerService {
        TravelerService(defaults: defaults, store: store, session: StubURLProtocol.session(),
                        keychainService: kcService,
                        verifiedRefresh: { [unowned self] in
                            if let t = self.verifiedNewToken { self.store.set(t, .travelerToken) }
                            return self.verifiedResult
                        })
    }

    override func setUp() {
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
        kcService = "com.buddyapp.tests.kc.\(UUID().uuidString)"
        store = SecureStore(service: "com.buddyapp.tests.\(UUID().uuidString)", defaults: defaults)
        StubURLProtocol.reset()
        verifiedResult = false; verifiedNewToken = nil
    }
    override func tearDown() {
        makeService().clearSession()
        defaults.removePersistentDomain(forName: suite)
        StubURLProtocol.reset()
    }

    private func refreshCalls() -> [URLRequest] {
        StubURLProtocol.requests.filter { $0.url?.path.hasSuffix("/travelers/refresh") == true }
    }
    private func jwt(expiresIn s: TimeInterval) -> String {
        func b64(_ d: Data) -> String { d.base64EncodedString().replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_") }
        let payload = try! JSONSerialization.data(withJSONObject: ["exp": Int(Date().timeIntervalSince1970 + s)])
        return "\(b64(Data(#"{"alg":"HS256"}"#.utf8))).\(b64(payload)).sig"
    }

    func test_hydrate_savesInTestStoresOnly() {
        let s = makeService()
        s.hydrate(travelerId: "T1", token: "JWT1", status: "guest", secret: "S1")
        XCTAssertEqual(s.travelerId, "T1")
        XCTAssertEqual(s.token, "JWT1")
        XCTAssertTrue(s.isGuest)
        XCTAssertNotEqual(TravelerService.shared.travelerId, "T1", "La sesión real no cambia")
    }

    func test_guestRefresh_ok_savesNewTokenAndSendsSecret() async throws {
        let s = makeService()
        s.hydrate(travelerId: "T1", token: "old", status: "guest", secret: "S1")
        StubURLProtocol.handler = { _ in .init(status: 200, body: Data(#"{"token":"new","status":"guest"}"#.utf8)) }
        let t = try await s.forceRefresh(travelerId: "T1")
        XCTAssertEqual(t, "new")
        XCTAssertEqual(s.token, "new")
        let r = try XCTUnwrap(refreshCalls().first)
        XCTAssertEqual(r.httpMethod, "POST")
        let body = try XCTUnwrap(r.httpBodyStream.map { s -> Data in
            s.open(); defer { s.close() }; var d = Data(); var b = [UInt8](repeating: 0, count: 1024)
            while s.hasBytesAvailable { let n = s.read(&b, maxLength: 1024); if n <= 0 { break }; d.append(b, count: n) }; return d } ?? r.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(json["traveler_id"], "T1")
        XCTAssertEqual(json["secret"], "S1")
        XCTAssertNotNil(json["device_id"])
    }

    func test_guestRefresh_upgradesStatusWhenServerSaysVerified() async throws {
        let s = makeService()
        s.hydrate(travelerId: "T1", token: "old", status: "guest", secret: "S1")
        StubURLProtocol.handler = { _ in .init(status: 200, body: Data(#"{"token":"new","status":"verified"}"#.utf8)) }
        _ = try await s.forceRefresh(travelerId: "T1")
        XCTAssertTrue(s.isVerified)
    }

    func test_guestRefresh_401_expiresAndClearsGuest() async {
        let s = makeService()
        s.hydrate(travelerId: "T1", token: "old", status: "guest", secret: "S1")
        StubURLProtocol.handler = { _ in .init(status: 401) }
        do { _ = try await s.forceRefresh(travelerId: "T1"); XCTFail("Debía expirar") }
        catch TravelerError.sessionExpired {}
        catch { XCTFail("\(error)") }
        XCTAssertNil(s.travelerId)
        XCTAssertNil(s.token)
        XCTAssertFalse(s.needsReauth, "Un guest no pide login: se borra")
    }

    func test_guestRefresh_serverError_keepsSession() async {
        let s = makeService()
        s.hydrate(travelerId: "T1", token: "old", status: "guest", secret: "S1")
        StubURLProtocol.handler = { _ in .init(status: 500) }
        do { _ = try await s.forceRefresh(travelerId: "T1"); XCTFail() }
        catch TravelerError.refreshFailed {}
        catch { XCTFail("\(error)") }
        XCTAssertEqual(s.travelerId, "T1", "Un 500 no borra la sesión")
        XCTAssertEqual(s.token, "old")
    }

    func test_guestRefresh_offline_keepsSession() async {
        let s = makeService()
        s.hydrate(travelerId: "T1", token: "old", status: "guest", secret: "S1")
        StubURLProtocol.handler = { _ in .init(error: URLError(.notConnectedToInternet)) }
        do { _ = try await s.forceRefresh(travelerId: "T1"); XCTFail() } catch {}
        XCTAssertEqual(s.travelerId, "T1", "Sin señal no se pierde la sesión")
    }

    func test_verifiedRefresh_ok_usesAccountPath() async throws {
        let s = makeService()
        s.hydrate(travelerId: "V1", token: "old", status: "verified", secret: nil)
        verifiedResult = true; verifiedNewToken = "fresh"
        let t = try await s.forceRefresh(travelerId: "V1")
        XCTAssertEqual(t, "fresh")
        XCTAssertTrue(refreshCalls().isEmpty, "Sin secret no llama a /travelers/refresh")
    }

    func test_verifiedRefresh_fails_keepsAccountAndAsksLogin() async {
        let s = makeService()
        s.hydrate(travelerId: "V1", token: "old", status: "verified", secret: nil)
        verifiedResult = false
        do { _ = try await s.forceRefresh(travelerId: "V1"); XCTFail() }
        catch TravelerError.sessionExpired {}
        catch { XCTFail("\(error)") }
        XCTAssertTrue(s.needsReauth, "Una cuenta verificada pide login, nunca pasa a guest")
        XCTAssertNil(s.token)
    }

    func test_concurrentRefresh_hitsServerOnce() async throws {
        let s = makeService()
        s.hydrate(travelerId: "T1", token: "old", status: "guest", secret: "S1")
        StubURLProtocol.handler = { _ in .init(status: 200, body: Data(#"{"token":"new"}"#.utf8), delay: 0.3) }
        async let a = s.forceRefresh(travelerId: "T1")
        async let b = s.forceRefresh(travelerId: "T1")
        async let c = s.forceRefresh(travelerId: "T1")
        let r = try await [a, b, c]
        XCTAssertEqual(r, ["new", "new", "new"])
        XCTAssertEqual(refreshCalls().count, 1)
    }

    func test_refreshIfExpiring_onlyWhenCloseToExpiry() async {
        let s = makeService()
        StubURLProtocol.handler = { _ in .init(status: 200, body: Data(#"{"token":"new"}"#.utf8)) }
        s.hydrate(travelerId: "T1", token: jwt(expiresIn: 3600), status: "guest", secret: "S1")
        await s.refreshTokenIfExpiring()
        XCTAssertTrue(refreshCalls().isEmpty, "Token con 1 h de vida: no se renueva")
        s.hydrate(travelerId: "T1", token: jwt(expiresIn: 30), status: "guest", secret: "S1")
        await s.refreshTokenIfExpiring()
        XCTAssertEqual(refreshCalls().count, 1, "Vence en 30 s: se renueva antes")
        XCTAssertEqual(s.token, "new")
    }

    func test_clearSession_removesEverything() {
        let s = makeService()
        s.hydrate(travelerId: "T1", token: "JWT", status: "verified", secret: "S1")
        s.clearSession()
        XCTAssertNil(s.travelerId); XCTAssertNil(s.token); XCTAssertFalse(s.hasSession)
    }
}

/// El camino 401 de APIClient: renovar y repetir UNA vez.
final class APIClient401Tests: XCTestCase {
    private var original: URLSession!
    override func setUp() {
        original = APIClient.session
        StubURLProtocol.reset()
        APIClient.session = StubURLProtocol.session()
    }
    override func tearDown() {
        APIClient.session = original
        APIClient.shared.refreshOverride = nil
        StubURLProtocol.reset()
    }
    private func mine(_ spot: String) -> Int { StubURLProtocol.requests.filter { $0.url?.path.contains(spot) == true }.count }

    func test_401_thenRefreshOk_retriesAndSucceeds() async throws {
        let spot = "t401-\(UUID().uuidString)"
        var refreshes = 0
        APIClient.shared.refreshOverride = { refreshes += 1; return true }
        StubURLProtocol.handler = { r in
            guard r.url?.path.contains(spot) == true else { return .init(status: 404) }
            return self.mine(spot) == 1 ? .init(status: 401) : .init(status: 200, body: Data(#"{"items":[],"linked":false}"#.utf8))
        }
        let page = try await APIClient.shared.fetchSpotProducts(spotId: spot)
        XCTAssertEqual(page.linked, false)
        XCTAssertEqual(refreshes, 1)
        XCTAssertEqual(mine(spot), 2)
    }

    func test_401_refreshFails_sessionExpiredError() async {
        let spot = "t401-\(UUID().uuidString)"
        APIClient.shared.refreshOverride = { false }
        StubURLProtocol.handler = { r in r.url?.path.contains(spot) == true ? .init(status: 401) : .init(status: 404) }
        do { _ = try await APIClient.shared.fetchSpotProducts(spotId: spot); XCTFail() }
        catch APIError.server(let c, let m) { XCTAssertEqual(c, 401); XCTAssertEqual(m, "Session expired") }
        catch { XCTFail("\(error)") }
        XCTAssertEqual(mine(spot), 1, "Sin sesión nueva no se repite")
    }

    func test_401_twice_doesNotLoop() async {
        let spot = "t401-\(UUID().uuidString)"
        var refreshes = 0
        APIClient.shared.refreshOverride = { refreshes += 1; return true }
        // Solo SUS peticiones reciben 401: las de la app anfitriona no cuentan.
        StubURLProtocol.handler = { r in r.url?.path.contains(spot) == true ? .init(status: 401) : .init(status: 404) }
        do { _ = try await APIClient.shared.fetchSpotProducts(spotId: spot); XCTFail() } catch {}
        XCTAssertEqual(refreshes, 1, "Solo un intento de renovar")
        XCTAssertEqual(mine(spot), 2, "Una sola repetición, sin bucle")
    }
}
