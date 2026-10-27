import Foundation

/// A 24 bit color as used by true color (SGR 38;2;r;g;b) escape sequences.
public struct TermRGB: Equatable, Hashable, Sendable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }
}

/// A terminal color: either the theme default, one of the 256 indexed colors,
/// or a direct 24 bit color.
public enum TermColor: Equatable, Hashable, Sendable {
    case `default`
    case indexed(UInt8)
    case rgb(TermRGB)

    public static let black = TermColor.indexed(0)
    public static let red = TermColor.indexed(1)
    public static let green = TermColor.indexed(2)
    public static let yellow = TermColor.indexed(3)
    public static let blue = TermColor.indexed(4)
    public static let magenta = TermColor.indexed(5)
    public static let cyan = TermColor.indexed(6)
    public static let white = TermColor.indexed(7)
}

/// Visual attributes of a cell.
public struct CellAttributes: OptionSet, Hashable, Sendable {
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    public static let bold = CellAttributes(rawValue: 1 << 0)
    public static let dim = CellAttributes(rawValue: 1 << 1)
    public static let italic = CellAttributes(rawValue: 1 << 2)
    public static let underline = CellAttributes(rawValue: 1 << 3)
    public static let blink = CellAttributes(rawValue: 1 << 4)
    public static let inverse = CellAttributes(rawValue: 1 << 5)
    public static let hidden = CellAttributes(rawValue: 1 << 6)
    public static let strikethrough = CellAttributes(rawValue: 1 << 7)
    public static let doubleUnderline = CellAttributes(rawValue: 1 << 8)
}

/// One terminal cell. A double width character occupies two cells: the first
/// one carries the text, the second one is a continuation cell (`width == 0`).
public struct Cell: Equatable, Sendable {
    public var text: String
    public var fg: TermColor
    public var bg: TermColor
    public var attributes: CellAttributes
    /// 1 for a normal cell, 2 for a wide character, 0 for its continuation.
    public var width: UInt8

    public init(
        text: String = " ",
        fg: TermColor = .default,
        bg: TermColor = .default,
        attributes: CellAttributes = [],
        width: UInt8 = 1
    ) {
        self.text = text
        self.fg = fg
        self.bg = bg
        self.attributes = attributes
        self.width = width
    }

    public var isContinuation: Bool { width == 0 }

    /// A blank cell that can be reused when clearing.
    public static let blank = Cell()

    public func isVisuallyBlank(defaultBackground: TermColor = .default) -> Bool {
        (text.isEmpty || text == " ") && bg == defaultBackground && attributes.isEmpty
    }
}

/// A row of cells plus wrap metadata. `wrapped` is true when the next row is a
/// continuation of this one because the terminal auto-wrapped. It lets us copy
/// and search logical lines correctly.
public struct TermLine: Sendable {
    public var cells: [Cell]
    public var wrapped: Bool

    public init(cells: [Cell], wrapped: Bool = false) {
        self.cells = cells
        self.wrapped = wrapped
    }

    public init(columns: Int, blank: Cell = .blank) {
        cells = Array(repeating: blank, count: max(1, columns))
        wrapped = false
    }

    public func trimmedText() -> String {
        var end = cells.count
        while end > 0 {
            let cell = cells[end - 1]
            if cell.isContinuation {
                end -= 1
                continue
            }
            if cell.text == " " && cell.bg == .default && cell.attributes.isEmpty {
                end -= 1
            } else {
                break
            }
        }
        guard end > 0 else { return "" }
        var result = ""
        result.reserveCapacity(end)
        for index in 0..<end {
            let cell = cells[index]
            if !cell.isContinuation {
                result += cell.text
            }
        }
        return result
    }

    public func text() -> String {
        var result = ""
        result.reserveCapacity(cells.count)
        for cell in cells where !cell.isContinuation {
            result += cell.text
        }
        return result
    }
}
