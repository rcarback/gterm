import Combine
import Foundation

/// Stores saved connections (metadata in UserDefaults, password in Keychain).
final class ConnectionStore: ObservableObject {
    @Published private(set) var connections: [SavedConnection] = []

    private let key = "savedConnections"
    private let defaults: UserDefaults
    private func passwordAccount(_ c: SavedConnection) -> String { c.id.uuidString }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    private func load() {
        guard let data = defaults.data(forKey: key),
              let decoded = try? SavedConnectionCodec.decode(data)
        else { return }
        connections = decoded
    }

    private func persist() {
        if let data = try? SavedConnectionCodec.encode(connections) {
            defaults.set(data, forKey: key)
        }
    }

    func save(_ connection: SavedConnection, password: String?) {
        if let idx = connections.firstIndex(where: { $0.id == connection.id }) {
            connections[idx] = connection
        } else {
            connections.append(connection)
        }
        if connection.savePassword, let password, !password.isEmpty {
            Keychain.setPassword(password, account: passwordAccount(connection))
        } else if !connection.savePassword {
            Keychain.deletePassword(account: passwordAccount(connection))
        }
        persist()
    }

    func delete(_ connection: SavedConnection) {
        connections.removeAll { $0.id == connection.id }
        Keychain.deletePassword(account: passwordAccount(connection))
        persist()
    }

    func savedPassword(for connection: SavedConnection) -> String? {
        Keychain.password(account: passwordAccount(connection))
    }

    /// Remove references to a key that has been deleted from the KeyStore.
    func removeKeyReference(_ keyID: UUID) {
        var changed = false
        for i in connections.indices where connections[i].keyIDs.contains(keyID) {
            connections[i].keyIDs.removeAll { $0 == keyID }
            changed = true
        }
        if changed { persist() }
    }
}
