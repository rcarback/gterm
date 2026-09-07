import Foundation

/// Connection parameters for one SSH endpoint. Jump hosts are ordered from the
/// first reachable host to the last intermediary; credentials stay on device.
struct SSHConnection: Identifiable {
    var id = UUID()
    var host: String
    var port: Int = 22
    var username: String
    var password: String = ""
    var privateKeys: [String] = []
    var term: String = "xterm-256color"
    var savedID: UUID? = nil
    var jumpHosts: [SSHConnection] = []
}
