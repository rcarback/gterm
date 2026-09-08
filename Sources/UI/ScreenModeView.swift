import SwiftUI

@MainActor
final class ScreenAttachment: ObservableObject {
    @Published private(set) var surface: TerminalSurfaceView?
    @Published private(set) var scrollingHistory = false
    @Published private(set) var controlsHidden = false
    private var terminal: ScreenTerminal?
    private var scrollInput = ScreenScrollInput()
    private var pendingScroll: CGFloat = 0
    private var historyLimit = 0
    private var scrollTask: Task<Void, Never>?
    private var generation = 0
    var onClose: ((Error?) -> Void)?
    var readHistoryLimit: (() async throws -> Int)?
    var onScrollError: ((Error) -> Void)?

    func open(command: String, ssh: SSHSession, ghostty: Ghostty.App) async throws {
        generation += 1
        let token = generation
        let view = TerminalSurfaceView(ghostty: ghostty)
        view.followsCursorWhileTyping = true
        view.onTouchScroll = { [weak self] delta in self?.scroll(delta) }
        view.onBeforeInput = { [weak self] in self?.returnToLive() }
        view.onGeometryChange = { [weak self] in
            guard let self, self.scrollingHistory else { return }
            if self.scrollInput.isActive {
                self.returnToLive()
            } else {
                self.scheduleScroll()
            }
        }
        view.canTapToMoveCursor = { [weak self] in self?.scrollingHistory == false }
        view.onTap = { [weak self] in
            guard let self, self.controlsHidden,
                  self.scrollingHistory || self.surface?.isKeyboardPresented != true else { return false }
            self.returnToLive()
            self.surface?.showKeyboardIfNeeded()
            return true
        }
        let terminal = try await ssh.openScreenTerminal(command: command, view: view) { [weak self] error in
            guard let self, token == self.generation else { return }
            self.onClose?(error)
        }
        guard token == generation else { terminal.close(); throw CancellationError() }
        self.terminal = terminal
        surface = view
    }

    func close() {
        generation += 1
        scrollTask?.cancel()
        scrollTask = nil
        pendingScroll = 0
        scrollInput = ScreenScrollInput()
        scrollingHistory = false
        controlsHidden = false
        _ = surface?.resignFirstResponder()
        surface?.delegate = nil
        terminal?.close()
        terminal = nil
        surface = nil
    }

    func scroll(_ points: CGFloat) {
        guard surface != nil, terminal != nil else { return }
        guard scrollingHistory || points > 0 else { return }
        if !scrollingHistory {
            scrollingHistory = true
            hideControls()
        }
        if !scrollInput.isActive {
            pendingScroll += points
            if scrollTask == nil { scheduleScroll() }
            return
        }
        sendScroll(points)
    }

    func hideControls() {
        controlsHidden = true
        surface?.collapseKeyboard()
    }

    private func scheduleScroll() {
        scrollTask?.cancel()
        scrollTask = Task { [weak self] in
            // Screen aborts copy mode on resize. Let the keyboard and controls
            // finish changing the PTY dimensions before entering that mode.
            do { try await Task.sleep(for: .milliseconds(350)) }
            catch { return }
            guard let self, self.scrollingHistory else { return }
            guard !Task.isCancelled, self.scrollingHistory else { return }
            do {
                guard let readHistoryLimit = self.readHistoryLimit else {
                    throw ScreenError(message: "Screen history reader is unavailable. Reopen Screen mode.")
                }
                let limit = try await readHistoryLimit()
                guard !Task.isCancelled, self.scrollingHistory else { return }
                self.historyLimit = limit
            } catch is CancellationError {
                if !Task.isCancelled { self.returnToLive() }
                return
            }
            catch {
                guard !Task.isCancelled, self.scrollingHistory else { return }
                self.returnToLive()
                self.controlsHidden = false
                self.onScrollError?(error)
                return
            }
            let points = self.pendingScroll
            self.pendingScroll = 0
            self.scrollTask = nil
            guard points > 0, self.historyLimit > 0 else { self.returnToLive(); return }
            self.sendScroll(points)
        }
    }

    private func sendScroll(_ points: CGFloat) {
        guard let surface, let terminal else { return }
        let rowHeight = Double(surface.bounds.height) / Double(max(1, surface.gridSize.rows))
        let data = scrollInput.scroll(points: Double(points), pointsPerLine: rowHeight, historyLimit: historyLimit)
        if !data.isEmpty {
            terminal.sendInput(data)
            if !scrollInput.isActive { returnToLive() }
        }
    }

    func returnToLive() {
        scrollTask?.cancel()
        scrollTask = nil
        pendingScroll = 0
        let data = scrollInput.returnToLive()
        scrollingHistory = false
        if !data.isEmpty { terminal?.sendInput(data) }
    }

    func showControls() {
        returnToLive()
        controlsHidden = false
    }
}

@MainActor
struct ScreenModeView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var controller: ScreenController
    @StateObject private var attachment: ScreenAttachment
    @State private var showWindowList = false
    @State private var search = ""
    @State private var editWindow: ScreenWindow?
    @State private var showNamePrompt = false
    @State private var windowName = ""
    @State private var closeWindow: ScreenWindow?
    @State private var openedInitialSession = false
    @State private var showingAICommands = false
    @State private var showingForwards = false
    @State private var browsing: PortForward?

    @ObservedObject private var session: ActiveSession
    @ObservedObject private var forwardStore: PortForwardStore

    init(session: ActiveSession, forwardStore: PortForwardStore, ghostty: Ghostty.App) {
        let attachment = ScreenAttachment()
        let controller = ScreenController(
            execute: { try await session.ssh.execute($0) },
            attach: { try await attachment.open(command: $0, ssh: session.ssh, ghostty: ghostty) },
            detach: { attachment.close() }
        )
        attachment.onClose = { [weak controller] in controller?.terminalClosed($0) }
        attachment.readHistoryLimit = { [weak controller] in
            guard let controller else { throw CancellationError() }
            return try await controller.readHistoryLimit()
        }
        attachment.onScrollError = { [weak controller] error in
            controller?.errorMessage = "Read Screen history: " + error.localizedDescription
        }
        self.session = session
        self.forwardStore = forwardStore
        _attachment = StateObject(wrappedValue: attachment)
        _controller = StateObject(wrappedValue: controller)
    }

    private var connectionForwards: [PortForward] {
        guard let id = session.connection.savedID else { return [] }
        return forwardStore.forwards(for: id)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let message = controller.errorMessage, !attachment.controlsHidden {
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.triangle")
                        Text(message).font(.caption).textSelection(.enabled)
                    }
                    .foregroundStyle(.orange)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("screen.error")
                }
                if let surface = attachment.surface {
                    TerminalView(surface: surface)
                    if !attachment.controlsHidden {
                        controls
                        windowTabs
                    }
                } else {
                    sessionPicker
                }
            }
            .ignoresSafeArea(.keyboard)
            .background(Color.black)
            .navigationTitle(controller.sessionID ?? "GNU Screen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(attachment.controlsHidden ? .hidden : .visible, for: .navigationBar)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        controller.detach()
                        dismiss()
                    } label: { Image(systemName: "rectangle.split.3x1") }
                    .accessibilityLabel("Close GNU Screen")
                    if attachment.surface != nil {
                        Button { attachment.hideControls() } label: { Image(systemName: "chevron.up") }
                            .accessibilityLabel("Hide Screen controls")
                    }
                    Button {
                        Task {
                            if controller.sessionID == nil { await controller.discover() }
                            else { await controller.refresh() }
                        }
                    } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("Refresh Screen")
                    .disabled(controller.busy)
                    Button { showingAICommands = true } label: {
                        Image(systemName: "sparkles")
                    }
                    .accessibilityLabel("AI commands")
                    .disabled(attachment.surface == nil)
                    Button { showingForwards = true } label: {
                        Image(systemName: "network")
                    }
                    .accessibilityLabel("Port forwards")
                    .disabled(session.state != .connected)
                }
            }
            .overlay(alignment: .top) {
                if controller.busy && !attachment.controlsHidden {
                    ProgressView().padding(8).allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topTrailing) {
                if attachment.controlsHidden {
                    Button { attachment.showControls() } label: {
                        Image(systemName: "chevron.down")
                            .font(.body.weight(.semibold))
                            .frame(width: 44, height: 44)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Show Screen controls")
                    .accessibilityValue(attachment.scrollingHistory ? "Browsing history" : "Live output")
                    .padding(8)
                }
            }
        }
        .preferredColorScheme(.dark)
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            if controller.sessionID != nil { await controller.refresh() }
            else if !openedInitialSession {
                openedInitialSession = true
                await controller.discoverAndAttachIfOnlySession()
            } else { await controller.discover() }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) }
                catch { return }
                guard !Task.isCancelled else { return }
                if controller.sessionID != nil && !controller.stale && !attachment.controlsHidden {
                    await controller.refresh(background: true)
                }
            }
        }
        .onDisappear {
            controller.detach()
        }
        .sheet(isPresented: $showWindowList, onDismiss: {
            _ = attachment.surface?.becomeFirstResponder()
        }) { windowList }
        .sheet(isPresented: $showingAICommands, onDismiss: {
            _ = attachment.surface?.becomeFirstResponder()
        }) {
            AICommandSheet(
                runCommand: { attachment.surface?.runCommand($0) },
                gatherContext: {
                    (
                        attachment.surface?.readVisibleText() ?? "",
                        CommandHistory.shared.recent(limit: 15)
                    )
                }
            )
        }
        .sheet(isPresented: $showingForwards, onDismiss: {
            _ = attachment.surface?.becomeFirstResponder()
        }) {
            PortForwardStatusSheet(
                forwards: connectionForwards,
                statuses: session.forwardStates,
                onToggle: { forward, enabled in
                    if enabled { session.ssh.startForward(forward.id) }
                    else { session.ssh.stopForward(forward.id) }
                },
                onOpenBrowser: { forward in
                    showingForwards = false
                    browsing = forward
                }
            )
        }
        .fullScreenCover(item: $browsing) { forward in
            if let url = forward.localURL {
                BrowserScreen(initialURL: url) { browsing = nil }
            }
        }
        .alert(editWindow == nil ? "Add window" : "Rename window", isPresented: $showNamePrompt) {
            TextField("Window name", text: $windowName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let window = editWindow
                Task {
                    if let window { await controller.rename(window, title: windowName) }
                    else { await controller.addWindow(title: windowName) }
                }
            }
        } message: {
            Text("Use letters, numbers, spaces, dots, underscores, or hyphens.")
        }
        .confirmationDialog("Close window?", isPresented: Binding(
            get: { closeWindow != nil }, set: { if !$0 { closeWindow = nil } }
        ), titleVisibility: .visible) {
            if let window = closeWindow {
                Button("Close \(window.number): \(window.title)", role: .destructive) {
                    Task { await controller.close(window) }
                    closeWindow = nil
                }
            }
            Button("Cancel", role: .cancel) { closeWindow = nil }
        } message: {
            Text("Closing a window terminates its running program. Closing the last window ends the Screen session.")
        }
    }

    private var sessionPicker: some View {
        List {
            Section {
                ForEach(controller.sessions) { session in
                    Button {
                        Task { await controller.attach(session) }
                    } label: {
                        HStack {
                            Text(session.id)
                            Spacer()
                            Text(session.isDetached ? "Detached" : "Attached")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(controller.busy)
                }
            } header: { Text("Remote sessions") } footer: {
                Text("Choose a session on this host. You can join sessions already open elsewhere. To create one, run screen -S work in your shell. Sessions in nested SSH or sudo shells are not listed here.")
            }
            if controller.sessions.isEmpty && !controller.busy && controller.errorMessage == nil {
                Text("No Screen sessions found.").foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("screen.sessions")
    }

    private var windowTabs: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(controller.windows) { window in
                    Button {
                        Task { await controller.select(window.number) }
                    } label: {
                        windowLabel(window)
                            .padding(.horizontal, 12).padding(.vertical, 10)
                            .background(window.selected ? Color.accentColor.opacity(0.3) : Color.secondary.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .accessibilityAddTraits(window.selected ? .isSelected : [])
                    .accessibilityIdentifier("screen.window.\(window.number)")
                    .contextMenu { windowActions(window) }
                }
            }.padding(8)
        }
        .disabled(!controller.canAct || attachment.scrollingHistory || scenePhase != .active)
    }

    private func windowLabel(_ window: ScreenWindow) -> some View {
        HStack(spacing: 5) {
            Text("\(window.number): \(window.title)").lineLimit(1)
            if window.bell {
                Image(systemName: "bell.fill").foregroundStyle(.orange)
                    .accessibilityLabel("Bell in window \(window.number)")
            }
            if window.activity {
                Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(.cyan)
                    .accessibilityLabel("New activity in window \(window.number)")
            }
        }
    }

    @ViewBuilder private func windowActions(_ window: ScreenWindow) -> some View {
        Button("Rename", systemImage: "pencil") {
            editWindow = window
            windowName = window.title
            showNamePrompt = true
        }
        Button("Monitor activity", systemImage: "waveform") {
            Task { await controller.monitor(window, enabled: true) }
        }
        Button("Stop monitoring", systemImage: "waveform.slash") {
            Task { await controller.monitor(window, enabled: false) }
        }
        Button("Close window", systemImage: "trash", role: .destructive) { closeWindow = window }
    }

    private var controls: some View {
        HStack(spacing: 20) {
            Button { showWindowList = true } label: { Image(systemName: "list.bullet") }
                .accessibilityLabel("Find a Screen window")
                .disabled(attachment.scrollingHistory)
            Button {
                editWindow = nil
                windowName = "shell"
                showNamePrompt = true
            } label: { Image(systemName: "plus") }
            .accessibilityLabel("Add Screen window")
            .disabled(attachment.scrollingHistory)
            Button { attachment.scroll(attachment.surface.map { $0.bounds.height / 2 } ?? 120) }
                label: { Image(systemName: "clock.arrow.circlepath") }
                .accessibilityLabel("Browse Screen history")
            Spacer()
            Button("Detach") {
                Task {
                    controller.detach()
                    if controller.sessionID == nil { await controller.discover() }
                }
            }
                .disabled(controller.busy)
        }
        .padding(12)
        .disabled(!controller.canAct || scenePhase != .active)
    }

    private var windowList: some View {
        NavigationStack {
            List(controller.windows.filter { search.isEmpty || "\($0.number) \($0.title)".localizedCaseInsensitiveContains(search) }) { window in
                Button {
                    showWindowList = false
                    Task { await controller.select(window.number) }
                } label: { windowLabel(window) }
                .disabled(!controller.canAct)
            }
            .searchable(text: $search, prompt: "Number or title")
            .navigationTitle("Screen windows")
            .toolbar { Button("Done") { showWindowList = false } }
        }
    }

}
