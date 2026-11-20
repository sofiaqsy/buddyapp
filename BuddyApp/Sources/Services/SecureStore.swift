import Foundation
import Security

/// Tokens de sesión en el Keychain, no en UserDefaults (auditoría, 20 Nov
/// 2026: UserDefaults entra en las copias de seguridad y se lee sin cifrar).
///
/// - Solo este dispositivo (`...ThisDeviceOnly`): no viaja a otro iPhone.
/// - Disponible tras el primer desbloqueo, como los otros secretos de la app.
/// - Migración: si un token aún está en UserDefaults (versión anterior), se
///   mueve al Keychain en la primera lectura y se borra de UserDefaults, así
///   nadie pierde su sesión al actualizar.
/// - Copia en memoria para no ir al Keychain en cada petición.
final class SecureStore {
    /// Claves que antes vivían en UserDefaults.
    enum Key: String, CaseIterable {
        case accessToken   = "buddy.accessToken"
        case refreshToken  = "buddy.refreshToken"
        case travelerToken = "buddy.traveler.token"
    }

    static let shared = SecureStore(service: "com.buddyapp.session", defaults: .standard)

    private let service: String
    private let defaults: UserDefaults
    private let lock = NSLock()
    private var cache: [Key: String?] = [:]

    /// `service` y `defaults` distintos en las pruebas: nunca tocan la sesión real.
    init(service: String, defaults: UserDefaults) {
        self.service = service
        self.defaults = defaults
    }

    func string(_ key: Key) -> String? {
        lock.lock(); defer { lock.unlock() }
        if let cached = cache[key] { return cached }
        var value = read(key)
        if let legacy = defaults.string(forKey: key.rawValue) {
            if value == nil {
                if write(key, legacy) { defaults.removeObject(forKey: key.rawValue) }
                value = legacy
            } else {
                // Ya está en el Keychain: la copia vieja sobra.
                defaults.removeObject(forKey: key.rawValue)
            }
        }
        cache[key] = .some(value)
        return value
    }

    func set(_ value: String?, _ key: Key) {
        lock.lock(); defer { lock.unlock() }
        if let value { _ = write(key, value) } else { delete(key) }
        defaults.removeObject(forKey: key.rawValue)
        cache[key] = .some(value)
    }

    func remove(_ key: Key) { set(nil, key) }

    /// Solo para pruebas: olvida la copia en memoria.
    func clearMemoryCache() { lock.lock(); cache = [:]; lock.unlock() }

    // MARK: Keychain
    private func base(_ key: Key) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key.rawValue]
    }
    private func read(_ key: Key) -> String? {
        var q = base(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    @discardableResult
    private func write(_ key: Key, _ value: String) -> Bool {
        let data = Data(value.utf8)
        let attrs: [String: Any] = [kSecValueData as String: data,
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let s = SecItemUpdate(base(key) as CFDictionary, attrs as CFDictionary)
        if s == errSecSuccess { return true }
        guard s == errSecItemNotFound else { return false }
        var add = base(key); attrs.forEach { add[$0] = $1 }
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
    private func delete(_ key: Key) { SecItemDelete(base(key) as CFDictionary) }
}
