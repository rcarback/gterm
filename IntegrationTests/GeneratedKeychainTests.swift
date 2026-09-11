import XCTest
import Security
@testable import gterm

final class GeneratedKeychainTests: XCTestCase {
    func testGeneratedKeyPersistsWithDeviceOnlyKeychainProtection() throws {
        let suite = "keychain-integration.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = KeyStore(defaults: defaults)
        let key = try store.generateKey(name: "Disposable integration key")
        defer { store.delete(key) }
        let connections = ConnectionStore()
        var host = SavedConnection()
        host.host = "test.invalid"
        host.username = "test"
        host.keyIDs = [key.id]
        connections.save(host, password: nil)
        defer { connections.delete(host) }
        XCTAssertEqual(ConnectionStore().connections.first { $0.id == host.id }?.keyIDs, [key.id])
        connections.removeKeyReference(key.id)
        XCTAssertEqual(ConnectionStore().connections.first { $0.id == host.id }?.keyIDs, [])
        let first = try store.publicKey(for: key)
        let reloaded = KeyStore(defaults: defaults)
        XCTAssertEqual(try reloaded.publicKey(for: key).line, first.line)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "io.github.madeye.gterm",
            kSecAttrAccount as String: "sshkey." + key.id.uuidString,
            kSecReturnAttributes as String: true
        ]
        var result: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &result), errSecSuccess)
        let attributes = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(attributes[kSecAttrAccessible as String] as? String,
                       kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertNotEqual(attributes[kSecAttrSynchronizable as String] as? Bool, true)
        XCTAssertNotNil(attributes[kSecAttrAccessGroup as String])
    }
}
