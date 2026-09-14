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

    /// The URL under `tapColumn`, or nil when the tap is not on one.
    ///
    /// - Parameters:
    ///   - visibleText: the whole viewport, read non-rectangularly so ghostty
    ///     has already joined soft-wrapped rows. A URL split across rows is
    ///     whole here even though no single row holds it.
    ///   - rowText: just the row under the tap, which is what gives the tap a
    ///     column to resolve against.
    static func url(visibleText: String, rowText: String, tapColumn: Int) -> URL? {
        guard let token = token(in: rowText, at: tapColumn) else { return nil }
        let rowMatches = matches(in: rowText)
        if let hit = rowMatches.first(where: { $0.start <= tapColumn && tapColumn <= $0.end }) {
            // A match touching either edge of the row may be one piece of a URL
            // that wrapped. The viewport copy carries the whole thing.
            let wrapped = hit.start == 0 || hit.end == Array(rowText).count - 1
            if wrapped,
               let whole = matches(in: visibleText).first(where: { $0.text.contains(hit.text) }),
               whole.text != hit.text {
                return url(from: whole.text)
            }
            return url(from: hit.text)
        }
        // No scheme on this row at all. The tap may be on the continuation of a
        // URL that began further up, which only ever starts at column zero.
        guard token.start == 0,
              let whole = matches(in: visibleText).first(where: { $0.text.contains(token.text) })
        else { return nil }
        return url(from: whole.text)
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
        for offset in 0..<scheme.count where Character(chars[index + offset].lowercased()) != scheme[offset] {
            return false
        }
        return true
    }

    /// The run of non-space characters covering `column`.
    private static func token(in row: String, at column: Int) -> (text: String, start: Int)? {
        let chars = Array(row)
        guard column >= 0, column < chars.count, !chars[column].isWhitespace else { return nil }
        var start = column
        var end = column
        while start > 0, !chars[start - 1].isWhitespace { start -= 1 }
        while end + 1 < chars.count, !chars[end + 1].isWhitespace { end += 1 }
        return (String(chars[start...end]), start)
    }

    private static func url(from candidate: String) -> URL? {
        URL(string: trimmed(candidate))
    }

    /// Drop trailing punctuation, and a closing parenthesis that has no opener
    /// inside the match — the "(https://example.com/a)" case.
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
