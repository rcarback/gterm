import Foundation

enum TerminalTapMovement {
    static func horizontalSteps(tapX: Double, tapY: Double, cursorX: Double,
                                cursorBottom: Double, cellWidth: Double,
                                cellHeight: Double, columns: Int) -> Int? {
        guard [tapX, tapY, cursorX, cursorBottom, cellWidth, cellHeight].allSatisfy(\.isFinite),
              cellWidth > 0, cellHeight > 0, columns > 0, tapX >= 0,
              tapY >= cursorBottom - cellHeight, tapY < cursorBottom else { return nil }
        let steps = floor((tapX - (cursorX - cellWidth / 2)) / cellWidth)
        guard abs(steps) < Double(columns) else { return nil }
        return Int(steps)
    }
}
