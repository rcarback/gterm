import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The "Keys" tab: generate, import, and manage SSH private keys. Keys are validated on
/// import and stored securely in the Keychain (device-only). Keys can be
/// imported from a file or pasted in as plain text.
struct KeyListView: View {
    @ObservedObject var store: KeyStore
    @ObservedObject var connections: ConnectionStore

    @State private var generating = false
    @State private var selectedKey: StoredKey?
    @State private var deletingKey: StoredKey?
    @State private var importing = false
    @State private var pastingText = false
    @State private var pendingText: String?
    @State private var pendingName = ""
    @State private var importError: String?

    var body: some View {
        NavigationStack {
            List {
                if store.keys.isEmpty {
                    ContentUnavailableView(
                        "No Keys",
                        systemImage: "key",
                        description: Text("Generate or import an SSH key to use for connections.")
                    )
                }
                ForEach(store.keys) { key in
                    Button {
                        selectedKey = key
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(key.name).font(.headline)
                            Text(key.type).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .tint(.primary)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            deletingKey = key
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle("Keys")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            generating = true
                        } label: {
                            Label("Generate Key", systemImage: "key.fill")
                        }
                        Button {
                            importing = true
                        } label: {
                            Label("Import from File", systemImage: "doc")
                        }
                        Button {
                            pastingText = true
                        } label: {
                            Label("Enter Text", systemImage: "doc.plaintext")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $generating) {
                GenerateKeyView(store: store)
            }
            .sheet(item: $selectedKey) { key in
                NavigationStack {
                    PublicKeyDetailsView(store: store, key: key)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { selectedKey = nil }
                            }
                        }
                }
            }
            .confirmationDialog("Delete key?", isPresented: Binding(
                get: { deletingKey != nil },
                set: { if !$0 { deletingKey = nil } }
            ), titleVisibility: .visible, presenting: deletingKey) { key in
                Button("Delete \(key.name)", role: .destructive) {
                    connections.removeKeyReference(key.id)
                    store.delete(key)
                    deletingKey = nil
                }
            } message: { key in
                Text(deletionMessage(for: key))
            }
            .fileImporter(
                isPresented: $importing,
                allowedContentTypes: [.data, .text, .item],
                allowsMultipleSelection: false
            ) { result in
                readFile(result)
            }
            .sheet(isPresented: $pastingText) {
                PasteKeyView { name, text in
                    pastingText = false
                    importText(name: name, text: text)
                }
            }
            .alert("Name this key", isPresented: Binding(
                get: { pendingText != nil },
                set: { if !$0 { pendingText = nil } }
            )) {
                TextField("name", text: $pendingName)
                Button("Save") { saveImported() }
                Button("Cancel", role: .cancel) { pendingText = nil }
            }
            .alert(
                "Import failed",
                isPresented: Binding(
                    get: { importError != nil },
                    set: { if !$0 { importError = nil } }
                ),
                presenting: importError
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { message in
                Text(message)
            }
        }
    }

    private func deletionMessage(for key: StoredKey) -> String {
        let hosts = connections.connections
            .filter { $0.keyIDs.contains(key.id) }
            .map(\.title)
        let affected = hosts.isEmpty
            ? "No saved hosts use this key."
            : "This key will be removed from these saved hosts: \(hosts.joined(separator: ", "))."
        return "\(affected) Deleting this key cannot be undone and does not remove its public key from servers."
    }

    private func readFile(_ result: Result<[URL], Error>) {
        guard let url = (try? result.get())?.first else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8) else {
                importError = "Key file isn't valid text."
                return
            }
            // Validate before prompting for a name.
            _ = try SSHKeyParser.parse(text)
            pendingName = url.deletingPathExtension().lastPathComponent
            pendingText = text
        } catch let error as SSHKeyError {
            importError = error.description
        } catch {
            importError = "Couldn't read key file: \(error.localizedDescription)"
        }
    }

    /// Import a key supplied as plain text (pasted or typed). Validates the key
    /// material and stores it directly; the name is taken from the paste sheet.
    private func importText(name: String, text: String) {
        do {
            try store.importKey(name: name, text: text)
        } catch let error as SSHKeyError {
            importError = error.description
        } catch {
            importError = error.localizedDescription
        }
    }

    private func saveImported() {
        guard let text = pendingText else { return }
        pendingText = nil
        do {
            try store.importKey(name: pendingName, text: text)
        } catch let error as SSHKeyError {
            importError = error.description
        } catch {
            importError = error.localizedDescription
        }
    }
}

/// A sheet for importing an SSH private key from plain text. Provides a name
/// field, a multi-line editor for the key material, and a Paste button that
/// pulls the current clipboard contents into the editor.
private struct PasteKeyView: View {
    /// Called with (name, keyText) when the user taps Import.
    let onImport: (String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var keyText = ""

    private var trimmedKey: String {
        keyText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Optional name", text: $name)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                Section {
                    TextEditor(text: $keyText)
                        .font(.system(.footnote, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .frame(minHeight: 220)
                } header: {
                    HStack {
                        Text("Private Key")
                        Spacer()
                        Button {
                            if let clip = UIPasteboard.general.string {
                                keyText = clip
                            }
                        } label: {
                            Label("Paste", systemImage: "doc.on.clipboard")
                                .labelStyle(.titleAndIcon)
                                .font(.caption)
                        }
                        .textCase(nil)
                        .disabled(!UIPasteboard.general.hasStrings)
                    }
                } footer: {
                    Text("Paste an OpenSSH or PEM private key. It is validated on import and stored in the Keychain (device-only).")
                }
            }
            .navigationTitle("Enter Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        onImport(name.trimmingCharacters(in: .whitespaces), trimmedKey)
                    }
                    .disabled(trimmedKey.isEmpty)
                }
            }
        }
    }
}

private struct GenerateKeyView: View {
    @ObservedObject var store: KeyStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var saving = false
    @State private var algorithm: SSHKeyAlgorithm = .ed25519
    @State private var rsaSize = "3072"
    @State private var generationTask: Task<Void, Never>?

    private var validSize: Bool {
        algorithm != .rsa || Int(rsaSize).map(SSHKeyGenerator.isValidRSASize) == true
    }
    @State private var generatedKey: StoredKey?
    @State private var generationError: String?

    var body: some View {
        NavigationStack {
            Group {
                if let key = generatedKey {
                    PublicKeyDetailsView(store: store, key: key)
                } else {
                    Form {
                        Section("Name") {
                            TextField("Optional name", text: $name)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                        }
                        Section {
                            Picker("Algorithm", selection: $algorithm) {
                                ForEach(SSHKeyAlgorithm.allCases) { option in
                                    Text(option.rawValue).tag(option)
                                }
                            }
                            .disabled(saving)
                            if algorithm == .rsa {
                                TextField("RSA size (bits)", text: $rsaSize)
                                    .keyboardType(.numberPad).disabled(saving)
                                Text("Use 2048–32768 bits, in multiples of 128. Sizes such as 8192 and 16384 are supported. Larger keys take longer to generate.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if saving { ProgressView("Generating key…") }
                        } footer: {
                            Text("Creates a key on this device and stores it in the Keychain. The private key stays on this device.")
                        }
                        if let generationError {
                            Section {
                                Text(generationError).foregroundStyle(.red)
                            } footer: {
                                Text("The key was not saved. Tap Create to try again.")
                            }
                        }
                    }
                    .navigationTitle("Generate Key")
                    .navigationBarTitleDisplayMode(.inline)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(generatedKey == nil ? "Cancel" : "Done") {
                        generationTask?.cancel()
                        dismiss()
                    }
                }
                if generatedKey == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Create") { create() }
                            .disabled(saving || !validSize)
                    }
                }
            }
            .interactiveDismissDisabled(saving)
            .onDisappear { generationTask?.cancel() }
        }
    }

    private func create() {
        guard !saving, generatedKey == nil, validSize else { return }
        saving = true
        generationError = nil
        let requestedName = name
        let requestedAlgorithm = algorithm
        let requestedBits = Int(rsaSize) ?? 3072
        generationTask = Task { @MainActor in
            defer { saving = false }
            do {
                let generated = try await SSHKeyGenerationWorker.shared.generate(
                    name: requestedName, algorithm: requestedAlgorithm, rsaBits: requestedBits
                )
                try Task.checkCancellation()
                generatedKey = try store.importKey(name: requestedName, text: generated.privateKey)
            } catch is CancellationError {
                return
            } catch let error as SSHKeyError {
                generationError = error.description
            } catch {
                generationError = error.localizedDescription
            }
        }
    }
}

private struct PublicKeyDetailsView: View {
    @ObservedObject var store: KeyStore
    let key: StoredKey
    @State private var publicKey: SSHPublicKey?
    @State private var loadError: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("Name", value: key.name)
                LabeledContent("Algorithm", value: key.type)
            }
            if let publicKey {
                Section("SHA256 Fingerprint") {
                    Text(publicKey.fingerprint)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                }
                Section {
                    Button {
                        UIPasteboard.general.string = publicKey.line
                    } label: {
                        Label("Copy Public Key", systemImage: "doc.on.doc")
                    }
                    ShareLink(item: publicKey.line) {
                        Label("Share Public Key", systemImage: "square.and.arrow.up")
                    }
                    Text(publicKey.line)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                } header: {
                    Text("Public Key")
                } footer: {
                    Text("Add only this public key to ~/.ssh/authorized_keys on your server. Copy and Share include only the public key.")
                }
            } else if let loadError {
                Section {
                    Text(loadError).foregroundStyle(.red)
                    Button("Retry") { loadPublicKey() }
                }
            }
            Section {
                Text("The private key stays in this device’s Keychain and is not restored from backups. Keep another way to access your servers if this device is lost. Deleting a key here does not remove its public key from servers.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Public Key")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadPublicKey() }
    }

    private func loadPublicKey() {
        do {
            publicKey = try store.publicKey(for: key)
            loadError = nil
        } catch let error as SSHKeyError {
            loadError = error.description
        } catch {
            loadError = error.localizedDescription
        }
    }
}
