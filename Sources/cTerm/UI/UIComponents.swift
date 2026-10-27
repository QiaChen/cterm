import AppKit

enum UIFactory {
    static func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular,
                      color: NSColor, alignment: NSTextAlignment = .left) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.alignment = alignment
        field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    static func wrappingLabel(_ text: String, size: CGFloat = 12, weight: NSFont.Weight = .regular,
                              color: NSColor) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.isSelectable = false
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    static func button(_ title: String, target: AnyObject?, action: Selector?,
                       color: NSColor? = nil, textColor: NSColor? = nil) -> NSButton {
        let button = HandCursorButton(title: title, target: target, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.font = .systemFont(ofSize: 13, weight: .medium)
        button.translatesAutoresizingMaskIntoConstraints = false
        if let color {
            button.bezelColor = color
        }
        if let textColor {
            button.contentTintColor = textColor
        }
        return button
    }

    static func imageButton(symbol: String, size: CGFloat, color: NSColor, target: AnyObject?, action: Selector?) -> NSButton {
        let button = HandCursorButton()
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.imageScaling = .scaleProportionallyDown
        button.bezelStyle = .inline
        button.isBordered = false
        button.contentTintColor = color
        button.target = target
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: size + 10).isActive = true
        button.heightAnchor.constraint(equalToConstant: size + 10).isActive = true
        return button
    }

    static func separator(color: NSColor) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = color.cgColor
        view.translatesAutoresizingMaskIntoConstraints = false
        view.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return view
    }
}

final class ColorView: NSView {
    var color: NSColor {
        didSet { layer?.backgroundColor = color.cgColor }
    }

    init(color: NSColor) {
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = color.cgColor
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class HairlineView: NSView {
    var color: NSColor {
        didSet { layer?.backgroundColor = color.cgColor }
    }

    init(color: NSColor) {
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = color.cgColor
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 1).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

final class RoundedCardView: NSView {
    var fillColor: NSColor {
        didSet { layer?.backgroundColor = fillColor.cgColor }
    }
    var borderColor: NSColor {
        didSet { layer?.borderColor = borderColor.cgColor }
    }
    var cornerRadius: CGFloat {
        didSet { layer?.cornerRadius = cornerRadius }
    }

    init(fill: NSColor, border: NSColor, radius: CGFloat = 10) {
        self.fillColor = fill
        self.borderColor = border
        self.cornerRadius = radius
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = fill.cgColor
        layer?.borderColor = border.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = radius
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

final class SymbolBadgeView: NSView {
    private let imageView = NSImageView()

    init(symbol: String, background: NSColor, tint: NSColor, size: CGFloat = 34) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = size * 0.28
        layer?.backgroundColor = background.cgColor
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: size).isActive = true
        heightAnchor.constraint(equalToConstant: size).isActive = true

        let configuration = NSImage.SymbolConfiguration(pointSize: size * 0.5, weight: .medium)
        imageView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        imageView.contentTintColor = tint
        imageView.imageScaling = .scaleProportionallyDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: size * 0.52),
            imageView.heightAnchor.constraint(equalToConstant: size * 0.52)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func apply(background: NSColor, tint: NSColor, symbol: String? = nil, pointSize: CGFloat = 15) {
        layer?.backgroundColor = background.cgColor
        imageView.contentTintColor = tint
        if let symbol {
            let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
            imageView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration)
        }
    }
}

final class StatusDotView: NSView {
    enum Status {
        case connected, connecting, failed, idle
    }

    var status: Status = .idle {
        didSet { needsDisplay = true }
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 8, height: 8) }

    override func draw(_ dirtyRect: NSRect) {
        let color: NSColor
        switch status {
        case .connected: color = NSColor(srgbRed: 0.29, green: 0.78, blue: 0.42, alpha: 1)
        case .connecting: color = NSColor(srgbRed: 0.95, green: 0.66, blue: 0.22, alpha: 1)
        case .failed: color = NSColor(srgbRed: 0.95, green: 0.35, blue: 0.35, alpha: 1)
        case .idle: color = NSColor.secondaryLabelColor.withAlphaComponent(0.5)
        }
        color.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).fill()
    }
}

final class GradientBackgroundView: NSView {
    private let gradient = CAGradientLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = gradient
        gradient.startPoint = CGPoint(x: 0.2, y: 1)
        gradient.endPoint = CGPoint(x: 0.8, y: 0)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        gradient.frame = bounds
    }

    func apply(theme: TerminalTheme, accentStrength: CGFloat = 0.16) {
        let highlight = theme.accent.blended(withFraction: 0.7, of: theme.background)?.withAlphaComponent(0.55)
            ?? theme.background
        gradient.colors = [
            theme.background.cgColor,
            highlight.cgColor,
            theme.background.cgColor
        ]
        gradient.locations = [0, 0.48, 1]
        gradient.frame = bounds
    }
}

extension NSColor {
    func blended(withFraction fraction: CGFloat, of color: NSColor) -> NSColor? {
        guard let a = usingColorSpace(.sRGB), let b = color.usingColorSpace(.sRGB) else { return nil }
        return NSColor(
            srgbRed: a.redComponent * (1 - fraction) + b.redComponent * fraction,
            green: a.greenComponent * (1 - fraction) + b.greenComponent * fraction,
            blue: a.blueComponent * (1 - fraction) + b.blueComponent * fraction,
            alpha: a.alphaComponent * (1 - fraction) + b.alphaComponent * fraction
        )
    }
}

// MARK: - Window chrome helpers

final class VerticalGradientView: NSView {
    private let gradient = CAGradientLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = gradient
        gradient.startPoint = CGPoint(x: 0.5, y: 1)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        gradient.frame = bounds
    }

    func apply(top: NSColor, bottom: NSColor) {
        gradient.colors = [top.cgColor, bottom.cgColor]
        gradient.locations = [0, 1]
        gradient.frame = bounds
    }
}

/// A small view that lets the user drag the window by its custom chrome.
final class WindowDragView: NSView {
    override var acceptsFirstResponder: Bool { false }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            window?.performZoom(nil)
        } else {
            window?.performDrag(with: event)
        }
    }
}

/// A custom-drawn pill or circle button used in the sidebar and tab bar.
final class HandCursorButton: NSButton {
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

/// A checkbox whose title is a plain label. On macOS 26 a switch button draws
/// its own title in black in our dark dialogs, ignoring both the appearance and
/// an attributed title colour, so the box carries no title and a themed label
/// sits beside it. Clicking the label toggles the box like a native title.
final class ThemedCheckbox: NSView {
    private let box = HandCursorButton()
    private let label = NSTextField(labelWithString: "")

    var title: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    var state: NSControl.StateValue {
        get { box.state }
        set { box.state = newValue }
    }

    var titleColor: NSColor {
        get { label.textColor ?? .labelColor }
        set { label.textColor = newValue }
    }

    var font: NSFont? {
        get { label.font }
        set { label.font = newValue }
    }

    var contentTintColor: NSColor? {
        get { box.contentTintColor }
        set { box.contentTintColor = newValue }
    }

    var target: AnyObject? {
        get { box.target }
        set { box.target = newValue }
    }

    var action: Selector? {
        get { box.action }
        set { box.action = newValue }
    }

    init(title: String, target: AnyObject? = nil, action: Selector? = nil) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        box.setButtonType(.switch)
        box.title = ""
        box.target = target
        box.action = action
        box.translatesAutoresizingMaskIntoConstraints = false
        label.stringValue = title
        label.font = .systemFont(ofSize: 12)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(labelClicked)))
        addSubview(box)
        addSubview(label)
        NSLayoutConstraint.activate([
            box.leadingAnchor.constraint(equalTo: leadingAnchor),
            box.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: box.trailingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(greaterThanOrEqualTo: box.heightAnchor),
            heightAnchor.constraint(greaterThanOrEqualTo: label.heightAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    @objc private func labelClicked() {
        box.performClick(nil)
    }
}

final class HandPopUpButton: NSPopUpButton {
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

final class HandSlider: NSSlider {
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

final class ChromeButton: NSButton {
    enum Shape {
        case circle
        case pill
    }

    let shape: Shape
    var fillColor: NSColor {
        didSet { needsDisplay = true }
    }
    var hoverFillColor: NSColor {
        didSet { needsDisplay = true }
    }
    var borderColor: NSColor {
        didSet { needsDisplay = true }
    }
    var titleColor: NSColor {
        didSet { needsDisplay = true }
    }
    var secondaryTitleColor: NSColor {
        didSet { needsDisplay = true }
    }
    var symbolName: String?
    var trailingText: String?
    private var hovering = false
    private var trackingAreaRef: NSTrackingArea?

    init(shape: Shape, title: String = "", symbol: String? = nil, trailing: String? = nil,
         target: AnyObject?, action: Selector?) {
        self.shape = shape
        self.symbolName = symbol
        self.trailingText = trailing
        fillColor = .clear
        hoverFillColor = .clear
        borderColor = .clear
        titleColor = .labelColor
        secondaryTitleColor = .secondaryLabelColor
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        isBordered = false
        focusRingType = .none
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityLabel(title.isEmpty ? (symbol ?? "button") : title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path: NSBezierPath
        switch shape {
        case .circle:
            path = NSBezierPath(ovalIn: rect)
        case .pill:
            path = NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9)
        }
        (hovering ? hoverFillColor : fillColor).setFill()
        path.fill()
        if borderColor.alphaComponent > 0 {
            borderColor.setStroke()
            path.lineWidth = 1
            path.stroke()
        }

        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        var contentWidth: CGFloat = 0
        let symbolImage: NSImage? = {
            guard let symbolName else { return nil }
            let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [hovering ? titleColor : titleColor.withAlphaComponent(0.9)]))
            return NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration)
        }()
        if let symbolImage { contentWidth += symbolImage.size.width + (title.isEmpty ? 0 : 6) }
        let titleWidth = (title as NSString).size(withAttributes: [.font: font]).width
        contentWidth += titleWidth
        if let trailingText {
            let trailingFont = NSFont.systemFont(ofSize: 11, weight: .medium)
            contentWidth += 10 + (trailingText as NSString).size(withAttributes: [.font: trailingFont]).width
        }

        var x: CGFloat
        switch shape {
        case .circle:
            x = (bounds.width - contentWidth) / 2
        case .pill:
            if trailingText == nil {
                x = (bounds.width - contentWidth) / 2
            } else {
                x = 12
            }
        }
        if let symbolImage {
            let y = (bounds.height - symbolImage.size.height) / 2
            symbolImage.draw(in: NSRect(x: x, y: y, width: symbolImage.size.width, height: symbolImage.size.height))
            x += symbolImage.size.width + (title.isEmpty ? 0 : 6)
        }
        if !title.isEmpty {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: titleColor
            ]
            let size = (title as NSString).size(withAttributes: attributes)
            (title as NSString).draw(
                at: NSPoint(x: x, y: (bounds.height - size.height) / 2),
                withAttributes: attributes
            )
        }
        if let trailingText {
            let trailingFont = NSFont.systemFont(ofSize: 11, weight: .medium)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: trailingFont,
                .foregroundColor: secondaryTitleColor
            ]
            let size = (trailingText as NSString).size(withAttributes: attributes)
            (trailingText as NSString).draw(
                at: NSPoint(x: bounds.width - 12 - size.width, y: (bounds.height - size.height) / 2),
                withAttributes: attributes
            )
        }
    }
}

// MARK: - Frosted glass

/// The tint layer carries a soft top reflection, a radial bloom and a hairline
/// rim. Every gradient fades to clear inside its own rect, so no hard band
/// shows where a gradient's rect ends.
final class FrostedTintView: NSView {
    private var topColor: NSColor = .clear
    private var bottomColor: NSColor = .clear
    private var isDark = true
    override var isOpaque: Bool { false }

    func apply(top: NSColor, bottom: NSColor, isDark: Bool) {
        topColor = top
        bottomColor = bottom
        self.isDark = isDark
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if let gradient = NSGradient(starting: topColor, ending: bottomColor) {
            gradient.draw(in: bounds, angle: -90)
        }

        let sheenHeight = bounds.height * 0.55
        if let sheen = NSGradient(colors: [
            NSColor.white.withAlphaComponent(isDark ? 0.055 : 0.10),
            NSColor.clear
        ]) {
            sheen.draw(
                in: NSRect(x: 0, y: bounds.height - sheenHeight, width: bounds.width, height: sheenHeight),
                angle: -90
            )
        }

        // A smooth radial highlight gives the pane depth; deliberately no
        // grain/noise so the surface stays clean.
        if let bloom = NSGradient(colors: [
            NSColor.white.withAlphaComponent(isDark ? 0.05 : 0.08),
            NSColor.clear
        ]) {
            bloom.draw(in: bounds, relativeCenterPosition: NSPoint(x: -0.35, y: 0.35))
        }

        if isDark, let vignette = NSGradient(colors: [
            NSColor.clear,
            NSColor.black.withAlphaComponent(0.03)
        ]) {
            vignette.draw(in: bounds, relativeCenterPosition: .zero)
        }

        // A hairline top reflection + bottom shade gives the pane an edge.
        NSColor.white.withAlphaComponent(isDark ? 0.06 : 0.24).setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        NSColor.black.withAlphaComponent(isDark ? 0.03 : 0.04).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

}

final class GlassBackgroundView: NSView {
    private let effect = NSVisualEffectView()
    private let tint = FrostedTintView()
    private var material: NSVisualEffectView.Material = .hudWindow

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        effect.material = material
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effect)

        tint.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tint)

        NSLayoutConstraint.activate([
            effect.leadingAnchor.constraint(equalTo: leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: trailingAnchor),
            effect.topAnchor.constraint(equalTo: topAnchor),
            effect.bottomAnchor.constraint(equalTo: bottomAnchor),
            tint.leadingAnchor.constraint(equalTo: leadingAnchor),
            tint.trailingAnchor.constraint(equalTo: trailingAnchor),
            tint.topAnchor.constraint(equalTo: topAnchor),
            tint.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The backdrop is purely decorative. It is a sibling behind interactive
    /// views, so it must never intercept clicks.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func apply(theme: TerminalTheme, material: NSVisualEffectView.Material,
               topAlpha: CGFloat, bottomAlpha: CGFloat, accentGlow: Bool = false) {
        self.material = material
        effect.material = material
        // Both themes blur the desktop behind the window; the tint on top only
        // tints it, so the light theme reads as frosted glass, not flat white.
        effect.blendingMode = .behindWindow
        effect.alphaValue = 1
        // The accent-glow variant is the sidebar's: a bluer top fading to a
        // deeper bottom, so it reads as a separate pane from the content glass.
        let top = (accentGlow ? theme.sidebarTop : theme.background).withAlphaComponent(topAlpha)
        let bottom = (accentGlow ? theme.sidebarBottom : theme.background).withAlphaComponent(bottomAlpha)
        tint.apply(top: top, bottom: bottom, isDark: theme.isDark)
        needsDisplay = true
    }

    /// Adds a glass backdrop behind every other subview of a dialog's root view.
    static func installDialogBackdrop(in root: NSView) -> GlassBackgroundView {
        let glass = GlassBackgroundView()
        root.addSubview(glass, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            glass.topAnchor.constraint(equalTo: root.topAnchor),
            glass.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        return glass
    }

    /// Dialogs carry form text, so their tint is a little denser than the chrome.
    func applyDialog(theme: TerminalTheme) {
        apply(
            theme: theme,
            material: .popover,
            topAlpha: theme.isDark ? 0.62 : 0.30,
            bottomAlpha: theme.isDark ? 0.76 : 0.40
        )
    }
}

extension NSWindow {
    /// Lets a behind-window blur show through; an opaque window background
    /// would cover it.
    func makeGlassBacked() {
        backgroundColor = .clear
        isOpaque = false
    }
}
