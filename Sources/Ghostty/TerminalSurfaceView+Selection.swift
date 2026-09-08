import UIKit
import GhosttyKit

extension TerminalSurfaceView: UIGestureRecognizerDelegate {
    func setupSelectionGestures() {
        let longPress = UILongPressGestureRecognizer(
            target: self, action: #selector(handleSelectionLongPress(_:))
        )
        longPress.minimumPressDuration = 0.4
        longPress.delegate = self
        addGestureRecognizer(longPress)
        selectionLongPress = longPress
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let selectionView, let touched = touch.view else { return true }
        return !touched.isDescendant(of: selectionView)
    }

    @objc private func handleSelectionLongPress(_ gesture: UILongPressGestureRecognizer) {
        if gesture.state == .began { beginSelection(at: gesture.location(in: self)) }
        if gesture.state == .ended { selectionView?.select(nil) }
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

    func endSelection() {
        selectionView?.removeFromSuperview()
        selectionView = nil
        scrollPan?.isEnabled = true
    }

}
