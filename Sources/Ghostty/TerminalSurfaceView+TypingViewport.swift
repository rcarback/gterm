import UIKit
import GhosttyKit

extension TerminalSurfaceView {
    func updateTypingViewport() {
        guard followsCursorWhileTyping, window != nil, isKeyboardPresented,
              let surface = ghosttySurface else {
            typingDisplayLink?.invalidate()
            typingDisplayLink = nil
            transform = .identity
            return
        }
        if typingDisplayLink == nil {
            let target = TypingViewportTarget(view: self)
            let link = CADisplayLink(target: target, selector: #selector(TypingViewportTarget.refresh))
            link.preferredFramesPerSecond = 30
            link.add(to: .main, forMode: .common)
            typingDisplayLink = link
        }
        // The renderer can move the cursor after processing remote output,
        // independently of UIKit layout or keyboard input callbacks.
        var x = 0.0, bottom = 0.0, width = 0.0, height = 0.0
        ghostty_surface_ime_point(surface, &x, &bottom, &width, &height)
        guard bottom.isFinite, height.isFinite, height > 0, bottom >= 0 else {
            transform = .identity
            return
        }
        guard let viewport = superview else { return }
        let maximumOffset = max(0, bounds.height + CGFloat(height) - viewport.bounds.height)
        let offset = min(maximumOffset, max(0, CGFloat(bottom + height) - viewport.bounds.height))
        let translation = CGAffineTransform(translationX: 0, y: -offset)
        guard transform != translation else { return }
        UIView.performWithoutAnimation { transform = translation }
    }
}

@MainActor
private final class TypingViewportTarget: NSObject {
    weak var view: TerminalSurfaceView?
    init(view: TerminalSurfaceView) { self.view = view }
    @objc func refresh() { view?.updateTypingViewport() }
}
