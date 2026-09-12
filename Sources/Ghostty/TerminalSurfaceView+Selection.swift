import UIKit
import GhosttyKit

/// Hold-to-select, with Copy and Paste in the menu UIKit puts over the
/// selection. A hold that lands on blank space has no word to select, so it
/// raises the edit menu on its own — that is how Paste stays reachable at an
/// empty prompt.
extension TerminalSurfaceView: UIGestureRecognizerDelegate, UIEditMenuInteractionDelegate {
    func setupSelectionGestures() {
        let longPress = UILongPressGestureRecognizer(
            target: self, action: #selector(handleSelectionLongPress(_:))
        )
        longPress.minimumPressDuration = 0.4
        longPress.delegate = self
        addGestureRecognizer(longPress)
        selectionLongPress = longPress
        let menu = UIEditMenuInteraction(delegate: self)
        addInteraction(menu)
        pasteMenu = menu
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let selectionView, let touched = touch.view else { return true }
        return !touched.isDescendant(of: selectionView)
    }

    @objc private func handleSelectionLongPress(_ gesture: UILongPressGestureRecognizer) {
        if gesture.state == .began {
            let point = gesture.location(in: self)
            beginSelection(at: point)
            if selectionView == nil { presentPasteMenu(at: point) }
        }
        if gesture.state == .ended { selectionView?.select(nil) }
    }

    /// Offer Paste where there is nothing to select. Scrolling stays enabled:
    /// the menu dismisses itself as soon as the user pans.
    func presentPasteMenu(at point: CGPoint) {
        guard window != nil, ghosttySurface != nil, UIPasteboard.general.hasStrings else { return }
        // UIKit sources the menu's actions from the first responder, so the
        // menu is empty unless the terminal holds focus.
        if !isFirstResponder { _ = becomeFirstResponder() }
        pasteMenu?.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: point))
    }

    /// UIKit builds the menu from the responder chain, which reaches the
    /// `paste(_:)` below. Going through the standard action (rather than a
    /// hand-rolled one) is what stops iOS asking "Allow Paste?" every time.
    func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        menuFor configuration: UIEditMenuConfiguration,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        UIMenu(children: suggestedActions)
    }

    /// `hasStrings` rather than reading the clipboard: a read here would fire
    /// the system paste prompt merely to decide whether to show the menu item.
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)) { return UIPasteboard.general.hasStrings }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        pasteClipboard()
    }

    func pasteClipboard() {
        guard let clip = UIPasteboard.general.string else { return }
        pasteText(clip)
    }

    /// Write text to the terminal as a paste. `sendText` applies bracketed
    /// paste when the running program asked for it (DECSET 2004).
    func pasteText(_ text: String) {
        guard !text.isEmpty else { return }
        sendText(text)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func beginSelection(at point: CGPoint) {
        guard let surface = ghosttySurface else { return }
        endSelection()
        let size = ghostty_surface_size(surface)
        guard size.columns > 0, size.rows > 0 else { return }
        let scale = window?.screen.scale ?? UIScreen.main.scale
        var rows: [String] = []
        var origin = CGPoint.zero
        for row in 0..<size.rows {
            let range = ghostty_selection_s(
                top_left: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT, x: 0, y: UInt32(row)),
                bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT,
                                            x: UInt32(size.columns - 1), y: UInt32(row)),
                rectangle: true
            )
            var text = ghostty_text_s()
            guard ghostty_surface_read_text(surface, range, &text) else { return }
            defer { ghostty_surface_free_text(surface, &text) }
            if row == 0 {
                origin = CGPoint(x: max(0, text.tl_px_x), y: max(0, text.tl_px_y))
            }
            let line = text.text.map {
                String(decoding: UnsafeRawBufferPointer(start: $0, count: Int(text.text_len)), as: UTF8.self)
            } ?? ""
            rows.append(line.trimmingCharacters(in: .newlines))
        }
        let selection = TerminalSelectionView(
            frame: bounds, rows: rows,
            cellSize: CGSize(width: CGFloat(size.cell_width_px) / scale, height: CGFloat(size.cell_height_px) / scale),
            origin: origin
        )
        selection.onFinish = { [weak self] in self?.endSelection() }
        selection.onPaste = { [weak self] text in self?.pasteText(text) }
        selection.readSelection = { [weak self] start, end in
            guard let surface = self?.ghosttySurface else { return nil }
            let range = ghostty_selection_s(
                top_left: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT,
                                         x: UInt32(min(start.x, CGFloat(size.columns - 1))), y: UInt32(start.y)),
                bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT,
                                             x: UInt32(min(end.x, CGFloat(size.columns - 1))), y: UInt32(end.y)),
                rectangle: false
            )
            var text = ghostty_text_s()
            guard ghostty_surface_read_text(surface, range, &text) else { return nil }
            defer { ghostty_surface_free_text(surface, &text) }
            return text.text.map {
                String(decoding: UnsafeRawBufferPointer(start: $0, count: Int(text.text_len)), as: UTF8.self)
            }
        }
        selection.isContentCurrent = { [weak selection] in
            guard let selection, let (start, end) = selection.selectedCells else { return true }
            for row in Int(start.y)...Int(end.y) {
                let current = selection.readSelection?(CGPoint(x: 0, y: row),
                    CGPoint(x: Int(size.columns) - 1, y: row))
                if current?.trimmingCharacters(in: .newlines) != rows[row] { return false }
            }
            return true
        }
        selectionView = selection
        addSubview(selection)
        scrollPan?.isEnabled = false
        selection.selectWord(at: point)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    /// Geometry is frozen while a selection is up (see `layoutSubviews`), so
    /// ask for the layout pass that applies whatever size it settled on.
    func endSelection() {
        let wasSelecting = selectionView != nil
        selectionView?.removeFromSuperview()
        selectionView = nil
        scrollPan?.isEnabled = true
        if wasSelecting { setNeedsLayout() }
    }

}
