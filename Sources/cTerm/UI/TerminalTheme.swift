import AppKit
import TerminalCore

struct TerminalTheme {
    let id: String
    let name: String
    let isDark: Bool

    let background: NSColor
    let foreground: NSColor
    let cursor: NSColor
    let selection: NSColor
    let subtle: NSColor
    let accent: NSColor
    let border: NSColor

    let tabBarBackground: NSColor
    let tabActiveBackground: NSColor
    let tabInactiveBackground: NSColor
    let tabText: NSColor
    let tabInactiveText: NSColor

    let palette: [NSColor]
    let boldUsesBright: Bool

    // MARK: - Application chrome

    var chromeTop: NSColor {
        isDark ? background.blended(withFraction: 0.10, of: accent) ?? background : tabBarBackground
    }

    var sidebarTop: NSColor {
        isDark ? background.blended(withFraction: 0.24, of: accent) ?? background : background.blended(withFraction: 0.10, of: accent) ?? background
    }

    var sidebarBottom: NSColor {
        isDark ? background.blended(withFraction: 0.55, of: .black) ?? background : background.blended(withFraction: 0.06, of: .black) ?? background
    }

    var sidebarDivider: NSColor {
        isDark ? NSColor.white.withAlphaComponent(0.07) : NSColor.black.withAlphaComponent(0.08)
    }

    var pillFill: NSColor {
        isDark ? NSColor.white.withAlphaComponent(0.055) : NSColor.black.withAlphaComponent(0.045)
    }

    var pillHoverFill: NSColor {
        isDark ? NSColor.white.withAlphaComponent(0.10) : NSColor.black.withAlphaComponent(0.08)
    }

    var pillBorder: NSColor {
        isDark ? NSColor.white.withAlphaComponent(0.075) : NSColor.black.withAlphaComponent(0.06)
    }

    var selectedPillFill: NSColor {
        isDark ? accent.withAlphaComponent(0.18) : accent.withAlphaComponent(0.14)
    }

    var selectedPillBorder: NSColor {
        isDark ? accent.withAlphaComponent(0.32) : accent.withAlphaComponent(0.30)
    }

    private static func rgb(_ value: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: alpha
        )
    }

    func ansiColor(_ index: UInt8, override: TermRGB? = nil) -> NSColor {
        if let override {
            return NSColor(
                srgbRed: CGFloat(override.r) / 255,
                green: CGFloat(override.g) / 255,
                blue: CGFloat(override.b) / 255,
                alpha: 1
            )
        }
        if index < 16 {
            return palette[Int(index)]
        }
        if index < 232 {
            let n = Int(index) - 16
            let steps: [CGFloat] = [0, 95, 135, 175, 215, 255]
            return NSColor(
                srgbRed: steps[n / 36] / 255,
                green: steps[(n / 6) % 6] / 255,
                blue: steps[n % 6] / 255,
                alpha: 1
            )
        }
        let level = CGFloat(8 + (Int(index) - 232) * 10) / 255
        return NSColor(srgbRed: level, green: level, blue: level, alpha: 1)
    }

    static let midnight = TerminalTheme(
        id: "midnight",
        name: "深蓝",
        isDark: true,
        background: rgb(0x07131F),
        foreground: rgb(0xDCE7F3),
        cursor: rgb(0x5AB0FF),
        selection: rgb(0x1E4D7A, alpha: 0.82),
        subtle: rgb(0x8EA6BD),
        accent: rgb(0x4C9AFF),
        border: rgb(0x1C3146),
        tabBarBackground: rgb(0x07131F),
        tabActiveBackground: rgb(0x112A40),
        tabInactiveBackground: rgb(0x0A1A28),
        tabText: rgb(0xEAF3FC),
        tabInactiveText: rgb(0x91A8BE),
        palette: [
            rgb(0x0A1520), rgb(0xFF7373), rgb(0x7EE787), rgb(0xE3B341),
            rgb(0x6CB6FF), rgb(0xD2A8FF), rgb(0x5AD4DD), rgb(0xD6E2EE),
            rgb(0x4A5A6B), rgb(0xFF9191), rgb(0xA5F0A9), rgb(0xF2CC60),
            rgb(0x93C5FD), rgb(0xE0C2FF), rgb(0x7DE9F0), rgb(0xF4F9FF)
        ],
        boldUsesBright: true
    )

    static let paper = TerminalTheme(
        id: "paper",
        name: "浅色",
        isDark: false,
        background: rgb(0xFFFFFF),
        foreground: rgb(0x22262B),
        cursor: rgb(0x1F6FEB),
        selection: rgb(0xCFE2FF, alpha: 0.9),
        subtle: rgb(0x6B7280),
        accent: rgb(0x0969DA),
        border: rgb(0xE7E7E9),
        tabBarBackground: rgb(0xFFFFFF),
        tabActiveBackground: rgb(0xF5F6F7),
        tabInactiveBackground: rgb(0xFFFFFF),
        tabText: rgb(0x1F2328),
        tabInactiveText: rgb(0x6E7781),
        palette: [
            rgb(0x24292F), rgb(0xCF222E), rgb(0x116329), rgb(0x953800),
            rgb(0x0969DA), rgb(0x8250DF), rgb(0x1B7C83), rgb(0x6E7781),
            rgb(0x57606A), rgb(0xA40E26), rgb(0x1A7F37), rgb(0x9A6700),
            rgb(0x218BFF), rgb(0xA475F9), rgb(0x3192AA), rgb(0x8C959F)
        ],
        boldUsesBright: false
    )

    static let all: [TerminalTheme] = [.midnight, .paper]

    static func named(_ id: String) -> TerminalTheme {
        all.first(where: { $0.id == id }) ?? .midnight
    }
}

enum AppearancePreferences {
    static let defaults = UserDefaults.standard
    private static let fontSizeKey = "cterm.fontSize"
    private static let themeKey = "cterm.theme"
    private static let followsSystemKey = "cterm.followSystemAppearance"

    static var fontSize: CGFloat {
        get {
            let value = defaults.double(forKey: fontSizeKey)
            return value > 0 ? CGFloat(min(max(value, 10), 24)) : 13
        }
        set {
            defaults.set(Double(min(max(newValue, 10), 24)), forKey: fontSizeKey)
            NotificationCenter.default.post(name: .ctermFontSizeDidChange, object: nil)
        }
    }

    /// Off by default: the app starts in the dark theme. Turning it on in
    /// Settings or the View menu follows the macOS appearance; choosing a theme
    /// turns it off again.
    static var followsSystemAppearance: Bool {
        get {
            if defaults.object(forKey: followsSystemKey) == nil { return false }
            return defaults.bool(forKey: followsSystemKey)
        }
        set {
            defaults.set(newValue, forKey: followsSystemKey)
            NotificationCenter.default.post(name: .ctermThemeDidChange, object: theme)
        }
    }

    static var systemTheme: TerminalTheme {
        let match = NSApplication.shared.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        return match == .darkAqua ? .midnight : .paper
    }

    static var theme: TerminalTheme {
        get {
            if followsSystemAppearance { return systemTheme }
            return TerminalTheme.named(defaults.string(forKey: themeKey) ?? "midnight")
        }
        set {
            defaults.set(newValue.id, forKey: themeKey)
            defaults.set(false, forKey: followsSystemKey)
            NotificationCenter.default.post(name: .ctermThemeDidChange, object: newValue)
        }
    }
}

extension Notification.Name {
    static let ctermThemeDidChange = Notification.Name("cterm.themeDidChange")
    static let ctermFontSizeDidChange = Notification.Name("cterm.fontSizeDidChange")
}
