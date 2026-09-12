import Foundation

struct ScreenScrollInput {
    private(set) var isActive = false
    private var remainder = 0.0
    private var linesFromLive = 0

    mutating func scroll(points: Double, pointsPerLine: Double, historyLimit: Int) -> Data {
        guard points.isFinite, pointsPerLine.isFinite, pointsPerLine > 0, historyLimit >= 0 else { return Data() }
        guard isActive || points > 0 else { remainder = 0; return Data() }
        remainder = max(-128, min(128, remainder + points / pointsPerLine))
        var lines = Int(max(-128, min(128, remainder.rounded(.towardZero))))
        guard lines != 0 else { return Data() }
        remainder -= Double(lines)
        lines = lines > 0 ? min(lines, max(0, historyLimit - linesFromLive)) : max(lines, -linesFromLive)
        guard lines != 0 else { remainder = 0; return Data() }
        linesFromLive += lines
        isActive = true
        // Each batch re-enters copy mode; resize may have ended the previous one.
        var data = Data(ScreenProtocol.scrollEntry.utf8)
        data.append(Data(String(repeating: lines > 0 ? ScreenProtocol.scrollOlder : ScreenProtocol.scrollNewer,
                                count: abs(lines)).utf8))
        if linesFromLive == 0 { data.append(returnToLive()) }
        return data
    }

    mutating func returnToLive() -> Data {
        defer { self = ScreenScrollInput() }
        return isActive ? Data(ScreenProtocol.scrollExit.utf8) : Data()
    }
}

struct ScreenWindow: Identifiable, Equatable {
    let number: Int
    let title: String
    let flags: String
    var id: Int { number }
    var selected: Bool { flags.contains("*") }
    var bell: Bool { flags.contains("!") }
    var activity: Bool { flags.contains("@") }
}

struct ScreenSessionInfo: Identifiable, Equatable {
    let id: String
    let isDetached: Bool
}

struct ScreenError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum ScreenProtocol {
    // Use the standard Screen command prefix followed by a reserved token.
    // Unlike Escape, Ctrl-A already waits for a command key. Disable mapping
    // timeouts so fragmented SSH delivery cannot leak sequence tails.
    static let scrollEntry = "\u{1}\u{1f}gterm-scroll;0~"
    static let scrollOlder = "\u{1}\u{1f}gterm-scroll;1~"
    static let scrollNewer = "\u{1}\u{1f}gterm-scroll;2~"
    static let scrollExit = "\u{1}\u{1f}gterm-scroll;3~"

    static func scrollBindingCommands(session: String) throws -> [String] {
        let bindings: [(String, String, [String])] = [
            (scrollEntry, "copy", ["copy"]),
            (scrollOlder, "copy", ["stuff", "\u{19}"]),
            (scrollNewer, "copy", ["stuff", "\u{5}"]),
            (scrollExit, "redisplay", ["stuff", "\u{1b}"])
        ]
        return try bindings.flatMap { sequence, normal, copy in
            // Movement bytes exist only in Screen's copy-mode keymap. Normal
            // mode consumes the sequence even if a resize aborted copy mode.
            [try command(session: session, arguments: ["bindkey", "-t", sequence, normal]),
             try command(session: session, arguments: ["bindkey", "-m", "-t", sequence] + copy)]
        }
    }

    static func historyLimitCommand(session: String, window: Int) throws -> String {
        let snapshot = try command(session: session, window: window, arguments: ["hardcopy", "-h"])
        let info = try command(session: session, window: window, arguments: ["info"], query: true)
        return """
        set -eu
        gterm_history_dir=$(mktemp -d /tmp/gterm-history.XXXXXXXX)
        trap 'rm -f "$gterm_history_dir/buffer"; rmdir "$gterm_history_dir"' EXIT
        \(snapshot) "$gterm_history_dir/buffer"
        \(info)
        test -f "$gterm_history_dir/buffer" || { echo 'Screen did not write its history snapshot.' >&2; exit 1; }
        printf '\n%s' 'gterm-history-lines:'
        wc -l < "$gterm_history_dir/buffer"
        """
    }

    static func historyLimit(_ info: String) throws -> Int {
        guard let range = info.range(of: #"\([0-9]+,[0-9]+\)/\([0-9]+,[0-9]+\)\+[0-9]+(?=\s|$)"#, options: .regularExpression),
              let capacityText = info[range].split(separator: "+").last,
              let capacity = Int(capacityText),
              let size = info[range].split(separator: "/").last?.split(separator: ")").first,
              let rowsText = size.split(separator: ",").last, let rows = Int(rowsText), rows > 0 else {
            throw ScreenError(message: "Screen returned an unsupported history size. Refresh the session and try again.")
        }
        let fields = info.components(separatedBy: "gterm-history-lines:")
        guard fields.count == 2, let total = Int(fields[1].trimmingCharacters(in: .whitespacesAndNewlines)),
              total >= rows else {
            throw ScreenError(message: "Screen returned an incomplete history snapshot. Try scrolling again.")
        }
        return min(capacity, total - rows)
    }

    static let windowFormat = "%n\u{1f}%f\u{1f}%t\u{1e}"
    static let firstWindowFormat = "%n\u{1f}%g\u{1f}%w\u{1e}"
    static let nextWindowFormat = windowFormat + "%+w\u{1e}"
    static let listCommand = "LC_ALL=C screen -ls"

    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func command(session: String, window: Int? = nil, arguments: [String], query: Bool = false) throws -> String {
        guard validSessionID(session), window.map({ $0 >= 0 }) ?? true else {
            throw ScreenError(message: "Invalid Screen session or window. Refresh the session list.")
        }
        let target = window.map { " -p " + quote(String($0)) } ?? ""
        return "LC_ALL=C screen -S " + quote(session) + target + (query ? " -Q " : " -X ") + arguments.map(quote).joined(separator: " ")
    }

    static func attachCommand(_ session: String) throws -> String {
        guard validSessionID(session) else { throw ScreenError(message: "Invalid Screen session. Refresh the session list.") }
        // Share an existing display without detaching other clients.
        return "exec screen -x " + quote(session)
    }

    static func validTitle(_ title: String) throws -> String {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " ._-"))
        guard !trimmed.isEmpty, trimmed.utf8.count <= 80,
              trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw ScreenError(message: "Use 1–80 bytes of letters, numbers, spaces, dots, underscores, or hyphens for a window name.")
        }
        return trimmed
    }

    static func sessions(_ text: String) throws -> [ScreenSessionInfo] {
        if text.contains("No Sockets found in ") { return [] }
        var result: [ScreenSessionInfo] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let pieces = line.split(whereSeparator: \.isWhitespace)
            guard let first = pieces.first, validSessionID(String(first)) else { continue }
            let detached = line.contains("(Detached)")
            guard detached || line.contains("(Attached)") else { continue }
            result.append(ScreenSessionInfo(id: String(first), isDetached: detached))
        }
        guard !result.isEmpty, Set(result.map(\.id)).count == result.count else {
            throw ScreenError(message: "Could not read Screen sessions. Check that GNU Screen is installed and accessible to this SSH user.")
        }
        return result
    }

    static func windows(_ text: String) throws -> [ScreenWindow] {
        let records = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\u{1e}")
        guard records.count > 1, records.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true else {
            throw malformedWindows()
        }
        var result: [ScreenWindow] = []
        for record in records.dropLast() {
            let fields = record.trimmingCharacters(in: .newlines).components(separatedBy: "\u{1f}")
            guard fields.count == 3, let number = Int(fields[0]), number >= 0,
                  !fields[2].unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  fields[1].allSatisfy({ "*-!@$&Z(L)> ".contains($0) }) else { throw malformedWindows() }
            result.append(ScreenWindow(number: number, title: fields[2], flags: fields[1]))
        }
        guard !result.isEmpty, Set(result.map(\.number)).count == result.count,
              result.filter(\.selected).count <= 1 else { throw malformedWindows() }
        return result.sorted { $0.number < $1.number }
    }

    static func firstWindow(_ text: String) throws -> (first: Int, selected: Int) {
        let record = text.trimmingCharacters(in: .newlines)
        guard record.hasSuffix("\u{1e}") else { throw malformedWindows() }
        let parts = record.dropLast().components(separatedBy: "\u{1f}")
        guard parts.count == 3, let current = Int(parts[0]), current >= 0 else { throw malformedWindows() }
        // Screen 4 does not support %g: it expands to the window number plus "g".
        // Screen 5 returns an empty string for windows outside a group.
        guard parts[1].isEmpty || parts[1] == "\(current)g" else {
            throw ScreenError(message: "Screen window groups are not supported. Select a window outside the group and refresh.")
        }
        guard
              let number = try leadingWindowNumber(parts[2]) else { throw malformedWindows() }
        return (first: number, selected: current)
    }

    static func windowAndNext(_ text: String) throws -> (window: ScreenWindow, next: Int?) {
        let parts = text.trimmingCharacters(in: .newlines).components(separatedBy: "\u{1e}")
        guard parts.count == 3, parts[2].isEmpty,
              let window = try windows(parts[0] + "\u{1e}").first else { throw malformedWindows() }
        return (window, try leadingWindowNumber(parts[1]))
    }

    private static func leadingWindowNumber(_ text: String) throws -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        let digits = trimmed.prefix { $0.isASCII && $0.isNumber }
        guard let number = Int(digits), let following = trimmed.dropFirst(digits.count).first,
              " *-!@$&Z(L)>".contains(following) else { throw malformedWindows() }
        return number
    }

    private static func validSessionID(_ value: String) -> Bool {
        guard let dot = value.firstIndex(of: "."), !value[..<dot].isEmpty,
              value[..<dot].allSatisfy(\.isNumber), value.index(after: dot) < value.endIndex,
              value.utf8.count <= 240 else { return false }
        return value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) && !CharacterSet.whitespaces.contains($0) }
    }

    private static func malformedWindows() -> ScreenError {
        ScreenError(message: "Screen returned an unsupported window list. Refresh or update GNU Screen on the host.")
    }
}
