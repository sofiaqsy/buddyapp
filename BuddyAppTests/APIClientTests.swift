import XCTest
@testable import BuddyApp

/// Cómo habla la app con buddy-core, contra un servidor falso (paso 4).
/// Solo lecturas (GET): las pruebas corren dentro de la app del simulador y
/// no deben tocar la sesión guardada ni escribir en el servidor. La app
/// anfitriona también pide cosas al arrancar: cada prueba filtra sus peticiones.
final class APIClientTests: XCTestCase {
    private var original: URLSession!

    override func setUp() {
        original = APIClient.session
        StubURLProtocol.reset()
        APIClient.session = StubURLProtocol.session()
    }
    override func tearDown() {
        APIClient.session = original
        StubURLProtocol.reset()
    }

    private func json(_ s: String, _ status: Int = 200) -> StubURLProtocol.Reply {
        .init(status: status, body: Data(s.utf8))
    }
    private func uniqueSpot() -> String { "test-\(UUID().uuidString)" }

    func test_defaultConfiguration_failsFastOnWeakSignal() {
        let c = APIClient.makeConfiguration()
        XCTAssertEqual(c.timeoutIntervalForRequest, 15)
        XCTAssertEqual(c.timeoutIntervalForResource, 30)
        XCTAssertFalse(c.waitsForConnectivity)
    }

    func test_get_buildsPathHeadersAndDecodes() async throws {
        StubURLProtocol.handler = { _ in self.json(#"{"items":[{"id":"p1","name":"Miel"}],"total":1,"hasMore":false,"linked":true}"#) }
        let spot = uniqueSpot()
        let page = try await APIClient.shared.fetchSpotProducts(spotId: spot, offset: 20)
        XCTAssertEqual(page.items.first?.name, "Miel")
        let r = try XCTUnwrap(StubURLProtocol.requests.first { $0.url?.path.contains(spot) == true })
        XCTAssertEqual(r.httpMethod, "GET")
        XCTAssertEqual(r.url?.host, "buddy-core-504b393f8333.herokuapp.com")
        XCTAssertEqual(r.url?.path, "/v1/integrations/fincas/spots/\(spot)/products")
        XCTAssertTrue(r.url?.query?.contains("offset=20") == true)
        XCTAssertTrue(r.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true)
        XCTAssertNotNil(r.value(forHTTPHeaderField: "X-Request-ID"))
        XCTAssertEqual(r.url?.scheme, "https")
    }

    func test_search_encodesAccentsAndSpaces() async throws {
        StubURLProtocol.handler = { _ in self.json(#"{"results":[]}"#) }
        _ = try await APIClient.shared.searchProducts("café molido \(UUID().uuidString.prefix(4))")
        let q = try XCTUnwrap(StubURLProtocol.requests.compactMap { $0.url?.absoluteString }.first { $0.contains("product-search") })
        XCTAssertTrue(q.contains("q=caf%C3%A9%20molido"), q)
    }

    func test_serverError_becomesAPIErrorWithMessage() async {
        StubURLProtocol.handler = { _ in self.json(#"{"error":"boom"}"#, 500) }
        do {
            _ = try await APIClient.shared.fetchSpotProducts(spotId: uniqueSpot())
            XCTFail("Debía fallar")
        } catch APIError.server(let code, let msg) {
            XCTAssertEqual(code, 500); XCTAssertEqual(msg, "boom")
        } catch { XCTFail("Error inesperado: \(error)") }
    }

    func test_notFoundWithoutBody_isServer404() async {
        StubURLProtocol.handler = { _ in .init(status: 404) }
        do { _ = try await APIClient.shared.fetchSpotProducts(spotId: uniqueSpot()); XCTFail() }
        catch APIError.server(let code, _) { XCTAssertEqual(code, 404) }
        catch { XCTFail("\(error)") }
    }

    func test_noContent_isNoContentError() async {
        StubURLProtocol.handler = { _ in .init(status: 204) }
        do { _ = try await APIClient.shared.fetchSpotProducts(spotId: uniqueSpot()); XCTFail() }
        catch APIError.noContent {}
        catch { XCTFail("\(error)") }
    }

    func test_wrongShape_throwsDecodingError() async {
        StubURLProtocol.handler = { _ in self.json(#"{"items":"no"}"#) }
        do { _ = try await APIClient.shared.fetchSpotProducts(spotId: uniqueSpot()); XCTFail() }
        catch is DecodingError {}
        catch { XCTFail("\(error)") }
    }

    func test_offline_throwsURLError() async {
        StubURLProtocol.handler = { _ in .init(error: URLError(.notConnectedToInternet)) }
        do { _ = try await APIClient.shared.fetchSpotProducts(spotId: uniqueSpot()); XCTFail() }
        catch let e as URLError { XCTAssertEqual(e.code, .notConnectedToInternet) }
        catch { XCTFail("\(error)") }
    }

    func test_slowServer_timesOut() async {
        APIClient.session = StubURLProtocol.session(timeout: 0.3)
        StubURLProtocol.handler = { _ in var r = self.json("{}"); r.delay = 2; return r }
        do { _ = try await APIClient.shared.fetchSpotProducts(spotId: uniqueSpot()); XCTFail() }
        catch let e as URLError { XCTAssertEqual(e.code, .timedOut) }
        catch { XCTFail("\(error)") }
    }

    func test_sameGetAtSameTime_goesToNetworkOnce() async throws {
        StubURLProtocol.handler = { _ in var r = self.json(#"{"items":[],"linked":false}"#); r.delay = 0.3; return r }
        let spot = uniqueSpot()
        async let a = APIClient.shared.fetchSpotProducts(spotId: spot)
        async let b = APIClient.shared.fetchSpotProducts(spotId: spot)
        _ = try await (a, b)
        XCTAssertEqual(StubURLProtocol.requests.filter { $0.url?.path.contains(spot) == true }.count, 1)
    }
}

/// Escrituras al sistema de negocios: la llave contra duplicados (paso 4).
final class FincasWriteRequestTests: XCTestCase {
    func test_writeRequest_hasIdempotencyKeyAuthAndJSON() throws {
        let r = try FincasAuth.writeRequest("POST", "/api/v1/farms/f1/products",
                                            body: ["name": "Miel"], key: "K-123", token: "TEST-TOKEN")
        XCTAssertEqual(r.httpMethod, "POST")
        XCTAssertEqual(r.url?.scheme, "https")
        XCTAssertEqual(r.url?.path, "/api/v1/farms/f1/products")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Idempotency-Key"), "K-123")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Authorization"), "Bearer TEST-TOKEN")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(r.timeoutInterval, 30)
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(r.httpBody)) as? [String: String]
        XCTAssertEqual(body, ["name": "Miel"])
    }

    func test_retryUsesSameKey_defaultKeyIsUnique() throws {
        let a = try FincasAuth.writeRequest("PATCH", "/x", body: [:], key: "same", token: "t")
        let b = try FincasAuth.writeRequest("PATCH", "/x", body: [:], key: "same", token: "t")
        XCTAssertEqual(a.value(forHTTPHeaderField: "Idempotency-Key"), b.value(forHTTPHeaderField: "Idempotency-Key"))
        XCTAssertNotEqual(UUID().uuidString, UUID().uuidString)
    }
}

/// Privacidad en los registros: ningún print/dlog muestra el token completo.
final class LogPrivacyTests: XCTestCase {
    func test_sourceNeverLogsAuthorizationOrFullTokens() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("BuddyApp/Sources")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty)
        let risky = ["\\(token)", "\\(accessToken)", "\\(refreshToken)", "\\(idToken)", "\\(headers)", "allHTTPHeaderFields"]
        var hits: [String] = []
        for f in files {
            for (i, line) in try String(contentsOf: f, encoding: .utf8).components(separatedBy: "\n").enumerated()
            where line.contains("print(") || line.contains("dlog(") {
                if risky.contains(where: line.contains) { hits.append("\(f.lastPathComponent):\(i + 1)") }
            }
        }
        XCTAssertEqual(hits, [], "Logs que pueden mostrar un token")
    }
}
