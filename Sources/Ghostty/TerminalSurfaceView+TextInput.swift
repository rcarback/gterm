import UIKit
import GhosttyKit

/// The remote program owns committed text. A short virtual prefix lets UIKit
/// observe a decreasing cursor position on delete and keep IME key repeat active.
/// Only marked text is real local content; the prefix is never sent remotely.
final class TerminalInputContext {
    var prefixLength = 64
    var marked: String?
    var selection = NSRange(location: 64, length: 0)
    var text: NSString { (String(repeating: " ", count: prefixLength) + (marked ?? "")) as NSString }
}

final class TerminalInputPosition: UITextPosition {
    let offset: Int
    init(_ offset: Int) { self.offset = offset; super.init() }
}

final class TerminalInputRange: UITextRange {
    let range: NSRange
    init(_ range: NSRange) { self.range = range; super.init() }
    override var start: UITextPosition { TerminalInputPosition(range.location) }
    override var end: UITextPosition { TerminalInputPosition(NSMaxRange(range)) }
    override var isEmpty: Bool { range.length == 0 }
}

extension TerminalSurfaceView: UITextInput {
    var beginningOfDocument: UITextPosition { TerminalInputPosition(0) }
    var endOfDocument: UITextPosition { TerminalInputPosition(inputContext.text.length) }
    var selectedTextRange: UITextRange? {
        get { TerminalInputRange(inputContext.selection) }
        set {
            guard let range = validInputRange(newValue) else { return }
            guard inputContext.marked == nil || range.location >= inputContext.prefixLength else { return }
            inputContext.selection = range
        }
    }
    var markedTextRange: UITextRange? {
        guard let marked = inputContext.marked else { return nil }
        return TerminalInputRange(NSRange(location: inputContext.prefixLength, length: marked.utf16.count))
    }

    func text(in range: UITextRange) -> String? {
        guard let range = validInputRange(range) else { return nil }
        return inputContext.text.substring(with: range)
    }

    func replace(_ range: UITextRange, withText text: String) {
        guard let range = validInputRange(range) else { return }
        if inputContext.marked != nil, range.location >= inputContext.prefixLength {
            let updated = inputContext.text.replacingCharacters(in: range, with: text)
            setMarkedText(String(updated.dropFirst(inputContext.prefixLength)),
                          selectedRange: NSRange(location: range.location - inputContext.prefixLength + text.utf16.count, length: 0))
        } else {
            if range.length > 0 { sendKey(.backspace) }
            insertText(text)
        }
    }

    func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        inputContext.marked = markedText.flatMap { $0.isEmpty ? nil : $0 }
        let length = markedText?.utf16.count ?? 0
        let start = max(0, min(selectedRange.location, length))
        inputContext.selection = NSRange(location: inputContext.prefixLength + start,
                                         length: max(0, min(selectedRange.length, length - start)))
        updateInputPreedit()
    }

    func unmarkText() {
        let text = inputContext.marked ?? ""
        resetInputContext()
        if !text.isEmpty { insertText(text) }
    }

    func resetInputContext() {
        inputContext.marked = nil
        inputContext.prefixLength = 64
        inputContext.selection = NSRange(location: inputContext.prefixLength, length: 0)
        updateInputPreedit()
    }

    func consumeInputContext() {
        inputContext.prefixLength = max(1, inputContext.prefixLength - 1)
        inputContext.selection = NSRange(location: inputContext.prefixLength, length: 0)
        if inputContext.prefixLength == 1 {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.inputContext.prefixLength == 1, self.inputContext.marked == nil else { return }
                self.inputDelegate?.textWillChange(self)
                self.inputDelegate?.selectionWillChange(self)
                self.resetInputContext()
                self.inputDelegate?.selectionDidChange(self)
                self.inputDelegate?.textDidChange(self)
            }
        }
    }

    func deleteMarkedInput() -> Bool {
        guard let marked = inputContext.marked else { return false }
        let selection = inputContext.selection
        let range: NSRange
        if selection.length > 0 {
            range = NSRange(location: selection.location - inputContext.prefixLength, length: selection.length)
        } else if selection.location > inputContext.prefixLength {
            range = (marked as NSString).rangeOfComposedCharacterSequence(at: selection.location - inputContext.prefixLength - 1)
        } else {
            return true
        }
        let updated = (marked as NSString).replacingCharacters(in: range, with: "")
        setMarkedText(updated, selectedRange: NSRange(location: range.location, length: 0))
        return true
    }

    private func updateInputPreedit() {
        guard let surface = ghosttySurface else { return }
        if let marked = inputContext.marked, !marked.isEmpty {
            marked.withCString { ghostty_surface_preedit(surface, $0, UInt(marked.utf8.count)) }
        } else {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }

    private func validInputRange(_ range: UITextRange?) -> NSRange? {
        guard let range = (range as? TerminalInputRange)?.range,
              range.location >= 0, range.location <= inputContext.text.length,
              range.length >= 0, range.length <= inputContext.text.length - range.location else { return nil }
        return range
    }

    func textRange(from fromPosition: UITextPosition, to toPosition: UITextPosition) -> UITextRange? {
        guard let from = fromPosition as? TerminalInputPosition,
              let to = toPosition as? TerminalInputPosition else { return nil }
        let range = TerminalInputRange(NSRange(location: min(from.offset, to.offset), length: abs(to.offset - from.offset)))
        return validInputRange(range) == nil ? nil : range
    }

    func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
        guard let position = position as? TerminalInputPosition else { return nil }
        let (value, overflow) = position.offset.addingReportingOverflow(offset)
        guard !overflow, value >= 0, value <= inputContext.text.length else { return nil }
        return TerminalInputPosition(value)
    }

    func position(from position: UITextPosition, in direction: UITextLayoutDirection, offset: Int) -> UITextPosition? {
        guard offset != Int.min else { return nil }
        return self.position(from: position, offset: direction == .left || direction == .up ? -offset : offset)
    }

    func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult {
        let delta = offset(from: position, to: other)
        return delta == 0 ? .orderedSame : delta > 0 ? .orderedAscending : .orderedDescending
    }

    func offset(from: UITextPosition, to toPosition: UITextPosition) -> Int {
        guard let from = from as? TerminalInputPosition, let to = toPosition as? TerminalInputPosition else { return 0 }
        return to.offset - from.offset
    }

    func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection) -> UITextPosition? {
        guard validInputRange(range) != nil else { return nil }
        return direction == .left || direction == .up ? range.start : range.end
    }

    func characterRange(byExtending position: UITextPosition, in direction: UITextLayoutDirection) -> UITextRange? {
        guard let next = self.position(from: position, in: direction, offset: 1) else { return nil }
        return textRange(from: position, to: next)
    }

    func baseWritingDirection(for position: UITextPosition, in direction: UITextStorageDirection) -> NSWritingDirection {
        .leftToRight
    }
    func setBaseWritingDirection(_ writingDirection: NSWritingDirection, for range: UITextRange) {
        // The remote terminal controls writing direction and layout.
    }
    func firstRect(for range: UITextRange) -> CGRect { caretRect(for: range.start) }
    func caretRect(for position: UITextPosition) -> CGRect {
        guard let surface = ghosttySurface else { return .zero }
        var x = 0.0, bottom = 0.0, width = 0.0, height = 0.0
        ghostty_surface_ime_point(surface, &x, &bottom, &width, &height)
        return CGRect(x: x, y: bottom - height, width: max(1, width), height: max(1, height))
    }
    func selectionRects(for range: UITextRange) -> [UITextSelectionRect] { [] }
    func closestPosition(to point: CGPoint) -> UITextPosition? { selectedTextRange?.end }
    func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? { range.end }
    func characterRange(at point: CGPoint) -> UITextRange? { selectedTextRange }
}
