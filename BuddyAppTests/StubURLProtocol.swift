import Foundation

/// Servidor falso para las pruebas: responde lo que cada prueba diga y
/// guarda las peticiones recibidas. Nunca sale a internet.
final class StubURLProtocol: URLProtocol {
    struct Reply { var status = 200; var body = Data(); var delay: TimeInterval = 0; var error: Error? = nil }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _handler: ((URLRequest) -> Reply)?
    nonisolated(unsafe) private static var _requests: [URLRequest] = []

    static var handler: ((URLRequest) -> Reply)? {
        get { lock.lock(); defer { lock.unlock() }; return _handler }
        set { lock.lock(); _handler = newValue; lock.unlock() }
    }
    static var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return _requests }
    static func reset() { lock.lock(); _requests = []; _handler = nil; lock.unlock() }

    static func session(timeout: TimeInterval = 15) -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        cfg.timeoutIntervalForRequest = timeout
        return URLSession(configuration: cfg)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self._requests.append(request); Self.lock.unlock()
        let reply = Self.handler?(request) ?? Reply(status: 404)
        let send = { [self] in
            if let e = reply.error { client?.urlProtocol(self, didFailWithError: e); return }
            let r = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.body)
            client?.urlProtocolDidFinishLoading(self)
        }
        if reply.delay > 0 { DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay, execute: send) } else { send() }
    }
    override func stopLoading() {}
}
