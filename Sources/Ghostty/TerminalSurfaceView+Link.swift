import UIKit
import GhosttyKit

/// Tap-to-open-URL support. libghostty detects links (auto-detected URLs and
/// OSC 8 hyperlinks) and opens the one under the cursor on a left-click release,
/// but only treats a cell as "over a link" when the mouse modifiers match
/// `ctrlOrSuper` — which is `super` (⌘) on Apple platforms. iOS has no hover, so
/// a single tap synthesizes a super-modified move + click at the tapped point;
/// if a link is there, libghostty fires the OPEN_URL action (handled in
/// `Ghostty.App.action`), which we route to the in-app browser. A tap on a
/// non-link falls back to horizontal cursor movement on the active cursor row.
extension TerminalSurfaceView {
    func setupLinkTapGesture() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleLinkTap(_:)))
        tap.numberOfTapsRequired = 1
        tap.numberOfTouchesRequired = 1
        tap.delegate = self
        if let selectionLongPress { tap.require(toFail: selectionLongPress) }
        addGestureRecognizer(tap)
    }

    @objc private func handleLinkTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, let surface = ghosttySurface else { return }
        if onTap?() == true { return }
        // A tap is also the affordance for re-summoning a dismissed keyboard.
        showKeyboardIfNeeded()
        let loc = gesture.location(in: self)
        let superMods = GHOSTTY_MODS_SUPER
        // Move with super so the cell registers as over_link, then click it.
        ghostty_surface_mouse_pos(surface, Double(loc.x), Double(loc.y), superMods)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, superMods)
        let handled = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, superMods)
        // Clear the hover modifiers so the link highlight doesn't stick.
        ghostty_surface_mouse_pos(surface, Double(loc.x), Double(loc.y), Ghostty.Mods.none.cMods)
        guard !handled, !ghostty_surface_mouse_captured(surface), canTapToMoveCursor?() ?? true else { return }
        var cursorX = 0.0, cursorBottom = 0.0, width = 0.0, height = 0.0
        ghostty_surface_ime_point(surface, &cursorX, &cursorBottom, &width, &height)
        let size = ghostty_surface_size(surface)
        let scale = window?.screen.scale ?? UIScreen.main.scale
        guard let steps = TerminalTapMovement.horizontalSteps(
            tapX: Double(loc.x), tapY: Double(loc.y), cursorX: cursorX,
            cursorBottom: cursorBottom, cellWidth: Double(size.cell_width_px) / Double(scale),
            cellHeight: height, columns: Int(size.columns)
        ) else { return }
        for _ in 0..<abs(steps) { sendKey(steps < 0 ? .left : .right) }
    }
}
