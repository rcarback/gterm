import Foundation

/// A persisted SSH connection. Secrets are never stored here: the password (if
/// saved) lives in the Keychain keyed by `id`; private keys are referenced by
/// `keyIDs` and managed by KeyStore.
struct SavedConnection: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String = ""
    var host: String = ""
    var port: Int = 22
    var username: String = ""
    /// Private keys (from KeyStore) this connection will try, in order.
    var keyIDs: [UUID] = []
    /// Whether a password is saved in the Keychain for this connection.
    var savePassword: Bool = false
    /// Optional for compatibility with connections saved before jump-host support.
    var jumpHostID: UUID? = nil

    var title: String { name.isEmpty ? "\(username)@\(host)" : name }

    var subtitle: String {
        let hostPart = port == 22 ? "\(username)@\(host)" : "\(username)@\(host):\(port)"
        if keyIDs.isEmpty { return hostPart }
        return "\(hostPart) · \(keyIDs.count) key\(keyIDs.count == 1 ? "" : "s")"
    }
}

/// Resolve a saved route before collecting credentials or opening sockets.
/// Missing references must fail rather than silently connect directly.
enum SSHRoute {
    enum RouteError: LocalizedError {
        case cycle, missingHost

        var errorDescription: String? {
            switch self {
            case .cycle: return "The jump-host route contains a loop. Edit its Jump Host settings."
            case .missingHost: return "A jump host was deleted. Select another Jump Host or choose None."
            }
        }
    }

    static func resolve(_ destination: SavedConnection, in connections: [SavedConnection]) throws -> [SavedConnection] {
        var route = [destination]
        var visited: Set<UUID> = [destination.id]
        var current = destination
        while let id = current.jumpHostID {
            guard visited.insert(id).inserted else { throw RouteError.cycle }
            guard let host = connections.first(where: { $0.id == id }) else { throw RouteError.missingHost }
            route.append(host)
            current = host
        }
        return route.reversed()
    }
}
