import SwiftUI

/// The "Hosts" tab: saved SSH connections. Tap to connect (resolving selected
/// keys and any saved password; prompting for a password only if there's no
/// key and none saved). A host with a live background session shows a status
/// dot; tapping it reattaches, and a leading swipe disconnects. Swipe to
/// edit/delete, "+" to add.
struct ConnectionListView: View {
    @ObservedObject var store: ConnectionStore
    @ObservedObject var keyStore: KeyStore
    @ObservedObject var forwardStore: PortForwardStore
    @ObservedObject var sessions: SessionManager
    let onConnect: (SSHConnection) -> Void

    @State private var editing: SavedConnection?
    @State private var pendingRoute: ConnectionCredentialRequest?
    @State private var routeError: String?
    @State private var readyConnection: SSHConnection?

    var body: some View {
        NavigationStack {
            List {
                if store.connections.isEmpty {
                    ContentUnavailableView(
                        "No Connections",
                        systemImage: "terminal",
                        description: Text("Tap + to add an SSH host.")
                    )
                }
                ForEach(store.connections) { conn in
                    Button { connect(conn) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(conn.title).font(.headline)
                                Text(conn.subtitle).font(.subheadline).foregroundStyle(.secondary)
                                if let id = conn.jumpHostID {
                                    Text("via \(store.connections.first(where: { $0.id == id })?.title ?? "unavailable jump host")")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if let session = sessions.session(for: conn.id) {
                                SessionBadge(session: session)
                            }
                        }
                    }
                    .swipeActions(edge: .leading) {
                        if let session = sessions.session(for: conn.id) {
                            Button { sessions.disconnect(session) } label: {
                                Label("Disconnect", systemImage: "bolt.slash")
                            }.tint(.orange)
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            store.delete(conn)
                            forwardStore.deleteForwards(for: conn.id)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        Button { editing = conn } label: {
                            Label("Edit", systemImage: "pencil")
                        }.tint(.blue)
                    }
                }
            }
            .navigationTitle("Hosts")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { editing = SavedConnection() } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(item: $editing) { conn in
                AddConnectionView(store: store, keyStore: keyStore, forwardStore: forwardStore, connection: conn)
            }
            .sheet(item: $pendingRoute, onDismiss: {
                if let connection = readyConnection {
                    readyConnection = nil
                    onConnect(connection)
                }
            }) { request in
                ConnectionCredentialsView(hosts: request.missing) { passwords in
                    openRoute(request.route, passwords: passwords, afterDismiss: true)
                }
            }
            .alert("Cannot Connect", isPresented: Binding(
                get: { routeError != nil }, set: { if !$0 { routeError = nil } }
            )) {
                Button("OK", role: .cancel) { routeError = nil }
            } message: {
                Text(routeError ?? "")
            }
        }
    }

    private func keyTexts(for conn: SavedConnection) -> [String] {
        conn.keyIDs.compactMap { keyStore.text(for: $0) }
    }

    private func makeConnection(_ conn: SavedConnection, password: String) -> SSHConnection {
        SSHConnection(
            host: conn.host, port: conn.port, username: conn.username,
            password: password, privateKeys: keyTexts(for: conn),
            savedID: conn.id, attachHerdr: conn.attachHerdr)
    }

    private func connect(_ conn: SavedConnection) {
        // A live background session just gets reattached — no credentials
        // needed, so skip any password prompt.
        if let session = sessions.session(for: conn.id), session.isAlive {
            onConnect(session.connection)
            return
        }
        do {
            let route = try SSHRoute.resolve(conn, in: store.connections)
            let missing = route.filter {
                keyTexts(for: $0).isEmpty && (store.savedPassword(for: $0) ?? "").isEmpty
            }
            if missing.isEmpty {
                openRoute(route, passwords: [:])
            } else {
                pendingRoute = ConnectionCredentialRequest(route: route, missing: missing)
            }
        } catch { routeError = error.localizedDescription }
    }

    private func openRoute(_ route: [SavedConnection], passwords: [UUID: String], afterDismiss: Bool = false) {
        var endpoints = route.map {
            makeConnection($0, password: passwords[$0.id] ?? store.savedPassword(for: $0) ?? "")
        }
        guard var destination = endpoints.popLast() else { return }
        destination.jumpHosts = endpoints
        if afterDismiss { readyConnection = destination }
        else { onConnect(destination) }
    }
}

/// Live status dot for a host with a background session: green when
/// connected, orange while connecting, gray once the session has died.
private struct SessionBadge: View {
    @ObservedObject var session: ActiveSession

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var color: Color {
        switch session.state {
        case .connected: return .green
        case .idle, .connecting, .authenticating: return .orange
        case .failed, .closed: return .gray
        }
    }

    private var text: String {
        switch session.state {
        case .connected: return "active"
        case .idle, .connecting, .authenticating: return "connecting"
        case .failed, .closed: return "ended"
        }
    }
}

private struct ConnectionCredentialRequest: Identifiable {
    let id = UUID()
    let route: [SavedConnection]
    let missing: [SavedConnection]
}

/// Collect missing passwords together so each hop can authenticate independently.
private struct ConnectionCredentialsView: View {
    let hosts: [SavedConnection]
    let onConnect: ([UUID: String]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var passwords: [UUID: String] = [:]

    var body: some View {
        NavigationStack {
            Form {
                ForEach(hosts) { host in
                    Section(host.title) {
                        Text("\(host.username)@\(host.host):\(host.port)")
                            .font(.caption).foregroundStyle(.secondary)
                        SecureField("Password", text: Binding(
                            get: { passwords[host.id] ?? "" },
                            set: { passwords[host.id] = $0 }
                        ))
                    }
                }
            }
            .navigationTitle("Connection Passwords")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect") { onConnect(passwords); dismiss() }
                        .disabled(hosts.contains { (passwords[$0.id] ?? "").isEmpty })
                }
            }
        }
    }
}
