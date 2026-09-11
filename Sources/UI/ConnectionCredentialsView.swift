import SwiftUI

/// Collect credentials independently for each host that needs them.
struct ConnectionCredentialsView: View {
    let hosts: [SavedConnection]
    @ObservedObject var keyStore: KeyStore
    let onConnect: ([UUID: String], [UUID: UUID]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var passwords: [UUID: String] = [:]
    @State private var selectedKeys: [UUID: UUID] = [:]
    @State private var selectingHost: SavedConnection?

    var body: some View {
        NavigationStack {
            Form {
                ForEach(hosts) { host in
                    Section {
                        Text("\(host.username)@\(host.host):\(host.port)")
                            .font(.caption).foregroundStyle(.secondary)
                        Button {
                            selectingHost = host
                        } label: {
                            Label(selectedKeys[host.id].flatMap { keyStore.key(for: $0)?.name }
                                  ?? "Select SSH Key", systemImage: "key")
                        }
                        if selectedKeys[host.id] != nil {
                            Button("Use Password Only") { selectedKeys.removeValue(forKey: host.id) }
                        }
                        SecureField("Password (optional with a key)", text: Binding(
                            get: { passwords[host.id] ?? "" },
                            set: { passwords[host.id] = $0 }
                        ))
                    } header: {
                        Text(host.title)
                    } footer: {
                        Text("Choose a saved key or enter a password. The key selection is remembered when you connect.")
                    }
                }
            }
            .navigationTitle("Connection Credentials")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect") { onConnect(passwords, selectedKeys); dismiss() }
                        .disabled(hosts.contains {
                            (passwords[$0.id] ?? "").isEmpty && selectedKeys[$0.id] == nil
                        })
                }
            }
            .sheet(item: $selectingHost) { host in
                NavigationStack {
                    List {
                        if keyStore.keys.isEmpty {
                            ContentUnavailableView("No SSH Keys", systemImage: "key",
                                                   description: Text("Generate or import a key in the Keys tab."))
                        }
                        ForEach(keyStore.keys) { key in
                            Button {
                                selectedKeys[host.id] = key.id
                                selectingHost = nil
                            } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(key.name)
                                        Text(key.type).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if selectedKeys[host.id] == key.id { Image(systemName: "checkmark") }
                                }
                            }
                        }
                    }
                    .navigationTitle("Select SSH Key")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { selectingHost = nil }
                        }
                    }
                }
            }
        }
    }
}
