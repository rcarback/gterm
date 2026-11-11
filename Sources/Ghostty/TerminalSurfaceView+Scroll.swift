import UIKit
import GhosttyKit

/// Touch scrolling: a one-finger drag emulates the desktop mouse wheel, driving
/// ghostty's `mouse_scroll`. This scrolls the local scrollback, and — exactly
/// like a desktop mouse — is forwarded to programs that grab the mouse (tmux /
/// vim with mouse mode, `less`, …). A host that keeps its own scrollback, as
/// Screen mode does, takes the drag through `onTouchScroll` and can decline it
/// so a mouse-reporting program still gets the wheel.
///
/// It uses precision (pixel) scrolling so the content tracks the finger, with
/// natural direction: dragging down reveals older lines. While a long-press
/// selection is active the recognizer is disabled (see TerminalSurfaceView+
/// Selection), so a stationary hold selects and an immediate drag scrolls.
extension TerminalSurfaceView {
    func setupScrollGesture() {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleScrollPan(_:)))
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)
        scrollPan = pan
    }

    @objc private func handleScrollPan(_ gesture: UIPanGestureRecognizer) {
        guard let surface = ghosttySurface else { return }
        switch gesture.state {
        case .began:
            lastScrollTranslationY = gesture.translation(in: self).y
            // A wheel report carries the pointer position, so put the pointer
            // where the finger is before any report is sent.
            let loc = gesture.location(in: self)
            ghostty_surface_mouse_pos(surface, Double(loc.x), Double(loc.y), Ghostty.Mods.none.cMods)
        case .changed:
            let translationY = gesture.translation(in: self).y
            let delta = translationY - lastScrollTranslationY
            lastScrollTranslationY = translationY
            guard delta != 0 else { return }

            if onTouchScroll?(delta) == true { return }

            // Convert points to surface pixels and feed as a precision scroll so
            // the content follows the finger. Positive y scrolls toward older
            // lines, which is what dragging the content downward should do.
            let scale = window?.screen.scale ?? UIScreen.main.scale
            let yOffset = Double(delta * scale)
            ghostty_surface_mouse_scroll(surface, 0, yOffset, Self.precisionScrollMods)
        default:
            break
        }
    }

    /// True while the running program has mouse reporting on. Such a program
    /// (codex, grok, vim with `mouse=a`) scrolls its own view, and libghostty
    /// sends it wheel reports instead of moving the viewport.
    var isMouseCaptured: Bool {
        guard let surface = ghosttySurface else { return false }
        return ghostty_surface_mouse_captured(surface)
    }

    /// `ghostty_input_scroll_mods_t` with only the precision bit set (bit 0).
    private static var precisionScrollMods: ghostty_input_scroll_mods_t { 1 }
}
