import UIKit
import GhosttyKit

/// Tap handling. By default this is tap-to-open-URL: libghostty detects links
/// (auto-detected URLs and OSC 8 hyperlinks) and opens the one under the cursor
/// on a left-click release, but only treats a cell as "over a link" when the
/// mouse modifiers match `ctrlOrSuper` — which is `super` (⌘) on Apple
/// platforms. iOS has no hover, so a single tap synthesizes a super-modified
/// move + click at the tapped point; if a link is there, libghostty fires the
/// OPEN_URL action (handled in `Ghostty.App.action`), which we route to the
/// in-app browser. A tap on a non-link falls back to horizontal cursor
/// movement on the active cursor row.
///
/// When `attachHerdr` is on, the same tap is instead an unmodified left
/// press+release so Herdr's mouse-native TUI can receive the click.
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
        let loc = gesture.location(in: self)
        // Resolve the link from the grid text before anything else can consume
        // the tap. Screen's copy mode swallows taps through `onTap`, and a
        // program that turns on mouse reporting stops libghostty tracking links
        // at all, so neither path can be relied on. Reading text sends nothing
        // to the remote, which is what makes it safe to try first.
        if let url = urlUnderTap(loc, surface: surface) {
            openURL(url)
            return
        }
        if onTap?() == true { return }
        // A tap is also the affordance for re-summoning a dismissed keyboard.
        showKeyboardIfNeeded()
        switch HerdrSupport.tapDecision(attachHerdr: attachHerdr, x: Double(loc.x), y: Double(loc.y)) {
        case .mouseLeftClick(let x, let y):
            // Unmodified left press+release at the tap so Herdr (and other
            // mouse-mode programs) receive a real click.
            let mods = Ghostty.Mods.none.cMods
            ghostty_surface_mouse_pos(surface, x, y, mods)
            _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, mods)
            _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, mods)
        case .existingGestures:
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

    /// The URL under a tap, read from the grid rather than from libghostty's
    /// hover state. The viewport is read non-rectangularly so ghostty joins
    /// soft-wrapped rows, which is what lets a tap on a continuation row open
    /// the whole address.
    private func urlUnderTap(_ loc: CGPoint, surface: ghostty_surface_t) -> URL? {
        let size = ghostty_surface_size(surface)
        guard size.columns > 0, size.rows > 0, size.cell_width_px > 0, size.cell_height_px > 0 else {
            return nil
        }
        let scale = Double(window?.screen.scale ?? UIScreen.main.scale)
        let column = Int(floor(Double(loc.x) / (Double(size.cell_width_px) / scale)))
        let row = Int(floor(Double(loc.y) / (Double(size.cell_height_px) / scale)))
        guard column >= 0, row >= 0, row < Int(size.rows) else { return nil }
        let range = ghostty_selection_s(
            top_left: ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT, x: 0, y: UInt32(row)
            ),
            bottom_right: ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT,
                x: UInt32(size.columns - 1), y: UInt32(row)
            ),
            rectangle: true
        )
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, range, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        let rowText = text.text.map {
            String(decoding: UnsafeRawBufferPointer(start: $0, count: Int(text.text_len)), as: UTF8.self)
        } ?? ""
        return TerminalLinkFinder.url(
            visibleText: readVisibleText(),
            rowText: rowText.trimmingCharacters(in: .newlines),
            tapColumn: column
        )
    }
}
