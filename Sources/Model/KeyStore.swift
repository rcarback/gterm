import Foundation
import Combine

/// Metadata for an imported SSH private key. The key material itself is NOT
/// stored here — only in the Keychain (see KeyStore).
struct StoredKey: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var type: String // e.g. "Ed25519", "ECDSA P-256"
}

/// Manages imported SSH private keys. Key metadata (name/type) lives in
/// UserDefaults; the secret key text lives in the Keychain, marked
/// `ThisDeviceOnly` so it is never synced to iCloud or included in backups.
final class KeyStore: ObservableObject {
    @Published private(set) var keys: [StoredKey] = []

    private let defaultsKey = "sshKeys"
    private func account(_ id: UUID) -> String { "sshkey." + id.uuidString }

    private let defaults: UserDefaults
    private let saveSecret: (String, String) -> Bool
    private let readSecret: (String) -> String?
    private let deleteSecret: (String) -> Void

    init(defaults: UserDefaults = .standard,
         saveSecret: @escaping (String, String) -> Bool = { Keychain.setPassword($0, account: $1) },
         readSecret: @escaping (String) -> String? = { Keychain.password(account: $0) },
         deleteSecret: @escaping (String) -> Void = { Keychain.deletePassword(account: $0) }) {
        self.defaults = defaults
        self.saveSecret = saveSecret
        self.readSecret = readSecret
        self.deleteSecret = deleteSecret
        load()
    }

    func generateKey(name: String, algorithm: SSHKeyAlgorithm = .ed25519, rsaBits: Int = 3072) throws -> StoredKey {
        let generated = try SSHKeyGenerator.generate(name: name, algorithm: algorithm, rsaBits: rsaBits)
        return try importKey(name: name, text: generated.privateKey)
    }

    func publicKey(for key: StoredKey) throws -> SSHPublicKey {
        guard let text = text(for: key.id) else {
            throw SSHKeyError.malformed("private key is unavailable in Keychain")
        }
        return try SSHKeyGenerator.publicKey(privateKey: text, comment: key.name)
    }

    private func load() {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([StoredKey].self, from: data)
        else { return }
        keys = decoded
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(keys) {
            defaults.set(data, forKey: defaultsKey)
        }
    }

    /// Validate and import a private key. Throws SSHKeyError if it can't be
    /// parsed / is unsupported. The key text is stored in the Keychain.
    @discardableResult
    func importKey(name: String, text: String) throws -> StoredKey {
        let parsed = try SSHKeyParser.parse(text) // validates; throws on failure
        let displayName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Key \(keys.count + 1)" : name
        let key = StoredKey(name: displayName, type: parsed.type)
        guard saveSecret(text, account(key.id)) else {
            throw SSHKeyError.malformed("couldn't store key in Keychain")
        }
        keys.append(key)
        persist()
        return key
    }

    func rename(_ key: StoredKey, to name: String) {
        guard let idx = keys.firstIndex(where: { $0.id == key.id }) else { return }
        keys[idx].name = name
        persist()
    }

    func delete(_ key: StoredKey) {
        keys.removeAll { $0.id == key.id }
        deleteSecret(account(key.id))
        persist()
    }

    func text(for id: UUID) -> String? {
        readSecret(account(id))
    }

    func key(for id: UUID) -> StoredKey? {
        keys.first { $0.id == id }
    }
}
