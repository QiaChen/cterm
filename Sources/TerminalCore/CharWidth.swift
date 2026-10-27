import Foundation

/// Minimal, dependency free port of the `wcwidth` rules used by terminals.
/// Control and combining characters have width 0, East Asian wide characters
/// and most emoji have width 2, everything else has width 1.
public enum CharWidth {
    public static func width(_ scalar: Unicode.Scalar) -> Int {
        let value = scalar.value

        if value == 0 { return 0 }
        if value < 0x20 || (value >= 0x7F && value < 0xA0) { return 0 }

        // Combining marks and format characters attach to the previous cell.
        let properties = scalar.properties
        switch properties.generalCategory {
        case .nonspacingMark, .enclosingMark, .format:
            return 0
        default:
            break
        }

        if isZeroWidth(value) { return 0 }
        if properties.isEmojiPresentation { return 2 }
        if isWide(value) { return 2 }
        return 1
    }

    public static func width(_ text: String) -> Int {
        var total = 0
        for scalar in text.unicodeScalars {
            total += width(scalar)
        }
        return max(total, 0)
    }

    private static func isZeroWidth(_ value: UInt32) -> Bool {
        switch value {
        case 0x1160...0x11FF,      // Hangul Jamo medial/final
             0x200B...0x200F,      // zero width space, bidi marks
             0x202A...0x202E,      // bidi embedding
             0x2060...0x206F,      // word joiner, invisible operators
             0xFE00...0xFE0F,      // variation selectors
             0xFEFF,               // BOM / zero width no-break space
             0xE0100...0xE01EF:    // variation selectors supplement
            return true
        default:
            return false
        }
    }

    /// East Asian wide / full width ranges (based on Markus Kuhn's tables plus
    /// the emoji blocks). CJK is rendered two cells wide.
    private static func isWide(_ value: UInt32) -> Bool {
        switch value {
        case 0x1100...0x115F,      // Hangul Jamo initial
             0x2329...0x232A,      // angle brackets
             0x2E80...0x303E,      // CJK radicals, punctuation
             0x3041...0x33FF,      // Hiragana, Katakana, CJK compatibility
             0x3400...0x4DBF,      // CJK ext A
             0x4E00...0x9FFF,      // CJK unified ideographs
             0xA000...0xA4CF,      // Yi
             0xA960...0xA97F,      // Hangul Jamo ext A
             0xAC00...0xD7A3,      // Hangul syllables
             0xF900...0xFAFF,      // CJK compatibility ideographs
             0xFE10...0xFE19,      // vertical forms
             0xFE30...0xFE6F,      // CJK compatibility forms
             0xFF00...0xFF60,      // fullwidth forms
             0xFFE0...0xFFE6,      // fullwidth signs
             0x1B000...0x1B2FF,    // Kana supplements
             0x1F004, 0x1F0CF,
             0x1F18E, 0x1F191...0x1F19A,
             0x1F200...0x1F320,
             0x1F32D...0x1F335,
             0x1F337...0x1F37C,
             0x1F37E...0x1F393,
             0x1F3A0...0x1F3CA,
             0x1F3CF...0x1F3D3,
             0x1F3E0...0x1F3F0,
             0x1F3F4,
             0x1F3F8...0x1F43E,
             0x1F440,
             0x1F442...0x1F4FC,
             0x1F4FF...0x1F53D,
             0x1F54B...0x1F54E,
             0x1F550...0x1F567,
             0x1F57A,
             0x1F595...0x1F596,
             0x1F5A4,
             0x1F5FB...0x1F64F,
             0x1F680...0x1F6C5,
             0x1F6CC,
             0x1F6D0...0x1F6D2,
             0x1F6D5...0x1F6D7,
             0x1F6EB...0x1F6EC,
             0x1F6F4...0x1F6FC,
             0x1F7E0...0x1F7EB,
             0x1F90C...0x1F93A,
             0x1F93C...0x1F945,
             0x1F947...0x1F9FF,
             0x1FA70...0x1FAFF,
             0x20000...0x3FFFD:
            return true
        default:
            return false
        }
    }

    /// VT100 DEC Special Graphics (line drawing) character map, used when a
    /// charset is designated with `ESC ( 0`.
    public static func decSpecialGraphic(_ byte: UInt8) -> String? {
        switch byte {
        case 0x60: return "◆"
        case 0x61: return "▒"
        case 0x62: return "␉"
        case 0x63: return "␌"
        case 0x64: return "␍"
        case 0x65: return "␊"
        case 0x66: return "°"
        case 0x67: return "±"
        case 0x68: return "␤"
        case 0x69: return "␋"
        case 0x6A: return "┘"
        case 0x6B: return "┐"
        case 0x6C: return "┌"
        case 0x6D: return "└"
        case 0x6E: return "┼"
        case 0x6F: return "⎺"
        case 0x70: return "⎻"
        case 0x71: return "─"
        case 0x72: return "⎼"
        case 0x73: return "⎽"
        case 0x74: return "├"
        case 0x75: return "┤"
        case 0x76: return "┴"
        case 0x77: return "┬"
        case 0x78: return "│"
        case 0x79: return "≤"
        case 0x7A: return "≥"
        case 0x7B: return "π"
        case 0x7C: return "≠"
        case 0x7D: return "£"
        case 0x7E: return "·"
        default: return nil
        }
    }
}
