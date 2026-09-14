import Foundation

/// Finds the URL under a tapped terminal cell by reading the grid text instead
/// of asking libghostty what the mouse is over.
///
/// libghostty only tracks links while the mouse hovers them, and it skips that
/// tracking entirely unless `mouse_event == .none` (see `mouseRefreshLinks` in
/// `ghostty/src/Surface.zig`). A full-screen program that enables mouse
/// reporting therefore suppresses link detection, and Screen's copy mode never
/// delivers a hover at all. Reading the text needs no mouse round-trip, so it
/// works in both cases — and because it sends nothing to the remote, it is safe
/// to run before the tap is offered to anything else.
///
/// Rows are joined when one reaches its last column. That is the only wrap
/// signal left once text is on the grid: a terminal soft wrap and a program
/// that re-wraps text itself, as GNU Screen does when it redraws, are
/// indistinguishable afterwards, and both fill the row they continue from.
///
/// Foundation only, so the whole search is covered by fast unit tests.
enum TerminalLinkFinder {
    /// Schemes libghostty highlights, from `ghostty/src/config/url.zig`.
    private static let schemes = [
        "https://", "http://", "mailto:", "ftp://", "file:", "ssh://",
        "git://", "tel:", "magnet:", "ipfs://", "ipns://", "gemini://",
        "gopher://", "news:",
    ]

    private static let bodyCharacters = Set(
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~:/?#[]@!$&'()*+,;=%"
    )

    /// Far more often sentence punctuation than part of the address.
    private static let trailingNoise = Set(".,;:!?'\"")

    /// The URL covering `tapColumn` on `tapRow`, or nil when the tap is not on
    /// one.
    ///
    /// - Parameters:
    ///   - rows: the viewport, one entry per row, each read across the full
    ///     width so a column index means the same thing in every row.
    ///   - columns: the grid width, which is what makes a row count as filled.
    static func url(rows: [String], columns: Int, tapRow: Int, tapColumn: Int) -> URL? {
        guard columns > 0, tapRow >= 0, tapRow < rows.count, tapColumn >= 0, tapColumn < columns
        else { return nil }
        let tapped = content(rows[tapRow])
        guard tapColumn < tapped.count, !Array(tapped)[tapColumn].isWhitespace else { return nil }

        // Walk out over every row that continues into the next one.
        var first = tapRow
        while first > 0, fills(rows[first - 1], columns: columns) { first -= 1 }
        var last = tapRow
        while last < rows.count - 1, fills(rows[last], columns: columns) { last += 1 }

        var joined = ""
        var offset = 0
        for row in first...last {
            if row == tapRow { offset = joined.count + tapColumn }
            joined += content(rows[row])
        }
        guard let hit = matches(in: joined).first(where: { $0.start <= offset && offset <= $0.end })
        else { return nil }
        return URL(string: trimmed(hit.text))
    }

    /// A row continues into the next one when its text reaches the last column.
    private static func fills(_ row: String, columns: Int) -> Bool {
        content(row).count >= columns
    }

    /// Row text without the trailing blanks a full-width read pads it with.
    private static func content(_ row: String) -> String {
        var text = row
        while let last = text.last, last.isWhitespace { text.removeLast() }
        return text
    }

    private struct Match {
        let text: String
        let start: Int
        let end: Int
    }

    /// Every scheme-led run of URL characters in one line.
    private static func matches(in line: String) -> [Match] {
        let chars = Array(line)
        var found: [Match] = []
        var index = 0
        while index < chars.count {
            guard let scheme = schemes.first(where: { starts(chars, at: index, with: $0) }) else {
                index += 1
                continue
            }
            var end = index + scheme.count
            while end < chars.count, bodyCharacters.contains(chars[end]) { end += 1 }
            found.append(Match(text: String(chars[index..<end]), start: index, end: end - 1))
            index = end
        }
        return found
    }

    private static func starts(_ chars: [Character], at index: Int, with scheme: String) -> Bool {
        let scheme = Array(scheme)
        guard index + scheme.count <= chars.count else { return false }
        for offset in 0..<scheme.count
        where Character(chars[index + offset].lowercased()) != scheme[offset] {
            return false
        }
        return true
    }

    private static func trimmed(_ candidate: String) -> String {
        var text = candidate
        while let last = text.last {
            if trailingNoise.contains(last) {
                text.removeLast()
                continue
            }
            if last == ")",
               text.filter({ $0 == "(" }).count < text.filter({ $0 == ")" }).count {
                text.removeLast()
                continue
            }
            break
        }
        return text
    }
}
