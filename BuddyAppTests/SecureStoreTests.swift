import XCTest
@testable import BuddyApp

/// Tokens en el Keychain (paso 5). Usa un servicio y un UserDefaults de
/// prueba: la sesión real de la app no se toca.
final class SecureStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var store: SecureStore!
    private let suite = "buddy.tests.securestore"
    private let service = "com.buddyapp.tests.\(UUID().uuidString)"

    override func setUp() {
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
        store = SecureStore(service: service, defaults: defaults)
    }
    override func tearDown() {
        SecureStore.Key.allCases.forEach { store.remove($0) }
        defaults.removePersistentDomain(forName: suite)
    }

    func test_setAndRead_fromKeychainNotUserDefaults() {
        store.set("T-1", .accessToken)
        XCTAssertNil(defaults.string(forKey: "buddy.accessToken"))
        store.clearMemoryCache()
        XCTAssertEqual(store.string(.accessToken), "T-1", "Se lee del Keychain, no de la memoria")
    }

    func test_overwrite_keepsLatest() {
        store.set("old", .refreshToken)
        store.set("new", .refreshToken)
        store.clearMemoryCache()
        XCTAssertEqual(store.string(.refreshToken), "new")
    }

    func test_remove_deletesValue() {
        store.set("x", .travelerToken)
        store.remove(.travelerToken)
        store.clearMemoryCache()
        XCTAssertNil(store.string(.travelerToken))
    }

    func test_missing_isNil() {
        XCTAssertNil(store.string(.accessToken))
    }

    func test_migration_movesOldTokenAndKeepsSession() {
        defaults.set("legacy-jwt", forKey: "buddy.traveler.token")
        XCTAssertEqual(store.string(.travelerToken), "legacy-jwt", "El usuario sigue con sesión")
        XCTAssertNil(defaults.string(forKey: "buddy.traveler.token"), "Ya no queda en UserDefaults")
        store.clearMemoryCache()
        XCTAssertEqual(store.string(.travelerToken), "legacy-jwt", "Quedó en el Keychain")
    }

    func test_leftoverOldCopy_isRemovedWhenKeychainHasValue() {
        store.set("kc", .travelerToken)
        defaults.set("old-copy", forKey: "buddy.traveler.token")
        store.clearMemoryCache()
        XCTAssertEqual(store.string(.travelerToken), "kc", "Manda el Keychain")
        XCTAssertNil(defaults.string(forKey: "buddy.traveler.token"))
    }

    func test_set_alsoClearsLeftoverUserDefaultsCopy() {
        defaults.set("stale", forKey: "buddy.refreshToken")
        store.set("fresh", .refreshToken)
        XCTAssertNil(defaults.string(forKey: "buddy.refreshToken"))
    }

    func test_keysAreSeparate() {
        store.set("a", .accessToken); store.set("r", .refreshToken)
        store.clearMemoryCache()
        XCTAssertEqual(store.string(.accessToken), "a")
        XCTAssertEqual(store.string(.refreshToken), "r")
    }

    func test_realApp_noTokensLeftInUserDefaults() {
        // Tras usar la app con esta versión, ningún token queda en UserDefaults.
        SecureStore.Key.allCases.forEach { _ = SecureStore.shared.string($0) }
        for k in SecureStore.Key.allCases {
            XCTAssertNil(UserDefaults.standard.string(forKey: k.rawValue), k.rawValue)
        }
    }
}
