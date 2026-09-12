import UIKit

/// A transparent text layer lets UIKit own selection handles and the Copy menu
/// while Ghostty continues to draw the terminal underneath it.
///
/// The text storage mirrors the grid and must stay immutable — `selectedRange`
/// is mapped back to cell coordinates, so an edit would desync that mapping.
/// Paste therefore never touches this view: it hands the clipboard to `onPaste`,
/// which writes it to the terminal instead.
final class TerminalSelectionView: UITextView, UITextViewDelegate {
    var onFinish: (() -> Void)?
    var readSelection: ((CGPoint, CGPoint) -> String?)?
    var isContentCurrent: (() -> Bool)?

    /// Sends clipboard text to the terminal. Set by the surface view.
    var onPaste: ((String) -> Void)?
    private var selectionReady = false
    private let cellSize: CGSize

    init(frame: CGRect, rows: [String], cellSize: CGSize, origin: CGPoint) {
        self.cellSize = cellSize
        super.init(frame: frame, textContainer: nil)
        backgroundColor = .clear
        isOpaque = false
        isEditable = false
        isSelectable = true
        isScrollEnabled = false
        inputView = UIView(frame: .zero)
        inputAccessoryView = UIView(frame: .zero)
        inputAssistantItem.leadingBarButtonGroups = []
        inputAssistantItem.trailingBarButtonGroups = []
        dataDetectorTypes = []
        contentInsetAdjustmentBehavior = .never
        textContainerInset = UIEdgeInsets(top: origin.y, left: origin.x, bottom: 0, right: 0)
        textContainer.lineFragmentPadding = 0
        textContainer.lineBreakMode = .byClipping
        let font = UIFont.monospacedSystemFont(ofSize: cellSize.height * 0.7, weight: .regular)
        let glyphWidth = ("M" as NSString).size(withAttributes: [.font: font]).width
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = cellSize.height
        paragraph.maximumLineHeight = cellSize.height
        paragraph.lineBreakMode = .byClipping
        attributedText = NSAttributedString(string: rows.joined(separator: "\n"), attributes: [
            .font: font,
            .foregroundColor: UIColor.clear,
            .kern: cellSize.width - glyphWidth,
            .paragraphStyle: paragraph,
        ])
        // Ghostty returns the baseline in view points. Match TextKit's baseline
        // rather than treating that value as a top inset or scaling it again.
        layoutManager.ensureLayout(for: textContainer)
        if layoutManager.numberOfGlyphs > 0 {
            textContainerInset.top = origin.y - layoutManager.location(forGlyphAt: 0).y
        }
        accessibilityIdentifier = "terminal.selection"
        delegate = self
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func selectWord(at point: CGPoint) {
        guard let position = closestPosition(to: point), let range = tokenizer.rangeEnclosingPosition(
            position, with: .word, inDirection: UITextDirection(rawValue: UITextStorageDirection.forward.rawValue)
        ), !range.isEmpty else { onFinish?(); return }
        selectedTextRange = range
        _ = becomeFirstResponder()
        selectionReady = true
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        if selectionReady && (selectedRange.length == 0 || isContentCurrent?() == false) { onFinish?() }
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        // UIKit disables Paste on a non-editable text view, so offer it here:
        // the target is the terminal, not the text storage.
        if action == #selector(paste(_:)) { return UIPasteboard.general.hasStrings }
        if action == #selector(copy(_:)) || action == #selector(selectAll(_:)) {
            return super.canPerformAction(action, withSender: sender)
        }
        return false
    }

    override func copy(_ sender: Any?) {
        guard isContentCurrent?() != false else { onFinish?(); return }
        guard let selected = selectedTerminalText(), !selected.isEmpty else { return }
        UIPasteboard.general.string = selected
        onFinish?()
    }

    /// Writes the clipboard to the terminal at its cursor, not into this view.
    /// The selection is dismissed either way so the grid is visible again.
    override func paste(_ sender: Any?) {
        defer { onFinish?() }
        guard let clip = UIPasteboard.general.string, !clip.isEmpty else { return }
        onPaste?(clip)
    }

    func selectedTerminalText() -> String? {
        guard let (start, end) = selectedCells else { return nil }
        return readSelection?(start, end)
    }

    var selectedCells: (CGPoint, CGPoint)? {
        guard selectedRange.length > 0 else { return nil }
        return (cell(at: selectedRange.location), cell(at: NSMaxRange(selectedRange) - 1))
    }

    private func cell(at index: Int) -> CGPoint {
        let prefix = (text as NSString).substring(to: index)
        let row = prefix.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
        let glyph = layoutManager.glyphIndexForCharacter(at: index)
        let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
        return CGPoint(x: max(0, floor(rect.minX / cellSize.width)), y: CGFloat(row))
    }
}
