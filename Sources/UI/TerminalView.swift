import SwiftUI

/// SwiftUI wrapper that hosts a `TerminalSurfaceView` owned by an
/// `ActiveSession`. The session and surface outlive this view: dismissing the
/// screen detaches the surface but leaves the SSH connection running, and
/// presenting it again reattaches the same surface with its scrollback.
struct TerminalView: UIViewRepresentable {
    let surface: TerminalSurfaceView

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.clipsToBounds = true
        let viewport = UIView()
        viewport.clipsToBounds = true
        viewport.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(viewport)
        surface.translatesAutoresizingMaskIntoConstraints = false
        viewport.addSubview(surface)
        NSLayoutConstraint.activate([
            viewport.topAnchor.constraint(equalTo: container.topAnchor),
            viewport.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            viewport.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            viewport.bottomAnchor.constraint(equalTo: container.keyboardLayoutGuide.topAnchor),
            surface.topAnchor.constraint(equalTo: viewport.topAnchor),
            surface.leadingAnchor.constraint(equalTo: viewport.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: viewport.trailingAnchor),
            surface.heightAnchor.constraint(equalTo: surface.followsCursorWhileTyping
                ? container.safeAreaLayoutGuide.heightAnchor : viewport.heightAnchor),
        ])
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
