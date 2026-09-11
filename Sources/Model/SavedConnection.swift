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
    /// When true, the SSH PTY execs `herdr` (start or attach to the default
    /// background session) instead of a login shell. Off by default so hosts
    /// without Herdr on `PATH` keep working.
    var attachHerdr: Bool = false

    var title: String { name.isEmpty ? "\(username)@\(host)" : name }

    var subtitle: String {
        let hostPart = port == 22 ? "\(username)@\(host)" : "\(username)@\(host):\(port)"
        if keyIDs.isEmpty { return hostPart }
        return "\(hostPart) · \(keyIDs.count) key\(keyIDs.count == 1 ? "" : "s")"
    }
}

extension SavedConnection {
    enum CodingKeys: String, CodingKey {
        case id, name, host, port, username, keyIDs, savePassword, jumpHostID, attachHerdr
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 22
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        keyIDs = try c.decodeIfPresent([UUID].self, forKey: .keyIDs) ?? []
        savePassword = try c.decodeIfPresent(Bool.self, forKey: .savePassword) ?? false
        jumpHostID = try c.decodeIfPresent(UUID.self, forKey: .jumpHostID)
        attachHerdr = try c.decodeIfPresent(Bool.self, forKey: .attachHerdr) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(host, forKey: .host)
        try c.encode(port, forKey: .port)
        try c.encode(username, forKey: .username)
        try c.encode(keyIDs, forKey: .keyIDs)
        try c.encode(savePassword, forKey: .savePassword)
        try c.encodeIfPresent(jumpHostID, forKey: .jumpHostID)
        try c.encode(attachHerdr, forKey: .attachHerdr)
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
