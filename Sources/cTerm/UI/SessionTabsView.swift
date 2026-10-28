import AppKit

protocol SessionTabsViewDelegate: AnyObject {
    func tabsView(_ tabsView: SessionTabsView, didSelect index: Int)
    func tabsView(_ tabsView: SessionTabsView, didClose index: Int)
    func tabsViewDidRequestNewTab(_ tabsView: SessionTabsView)
    func tabsViewDidRequestQuickConnect(_ tabsView: SessionTabsView)
    func tabsView(_ tabsView: SessionTabsView, didRequestReconnect index: Int)
    func tabsView(_ tabsView: SessionTabsView, didRequestCloseOthers index: Int)
    func tabsViewDidToggleSFTP(_ tabsView: SessionTabsView)
}

struct SessionTabItem {
    enum State {
        case connecting, connected, failed, disconnected
    }

    let id: UUID
    var title: String
    var state: State
}

/// Flat, integrated tabs that share the terminal's glass surface.
final class SessionTabsView: NSView {
    /// The SFTP panel toggle left of `+`, for the selected tab.
    enum SFTPButtonState {
        case hidden, inactive, active
    }

    /// Centre line of the icon buttons at the right of the title strip,
    /// shared with the SFTP panel's header so both rows line up.
    static let toolbarCenterY: CGFloat = 22
    /// Tabs are as tall as the icon buttons and share their centre line.
    private static let tabHeight: CGFloat = 30
    private static let stripHeight: CGFloat = 44
    private static let toolbarButtonSize: CGFloat = 30

    weak var delegate: SessionTabsViewDelegate?

    private(set) var items: [SessionTabItem] = []
    private var selectedIndex = 0
    private var theme: TerminalTheme
    private var hoveredIndex: Int?
    private var hoveredClose = false
    private var hoveredPlus = false
    private var hoveredSFTP = false
    private var sftpState: SFTPButtonState = .hidden
    private var sftpRect: NSRect = .zero
    /// Where the first tab starts. Larger while the sidebar is hidden, to
    /// clear the window buttons and the sidebar toggle.
    var leadingInset: CGFloat = 16 {
        didSet {
            guard leadingInset != oldValue else { return }
            needsLayout = true
            needsDisplay = true
        }
    }
    private var hoveredEmptyPill = false
    private var trackingAreaRef: NSTrackingArea?
    private var pulseTimer: Timer?
    private var pulseOn = true
    private var contextIndex: Int?
    private var tabRects: [NSRect] = []
    private var closeRects: [NSRect] = []
    private var plusRect: NSRect = .zero
    private var emptyPillRect: NSRect = .zero

    private var titleFont: NSFont { .systemFont(ofSize: 13, weight: .medium) }
    private var activeTitleFont: NSFont { .systemFont(ofSize: 13, weight: .semibold) }

    init(theme: TerminalTheme) {
        self.theme = theme
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: Self.stripHeight).isActive = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        pulseTimer?.invalidate()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.stripHeight)
    }

    override var isFlipped: Bool { true }

    func update(items: [SessionTabItem], selectedIndex: Int, theme: TerminalTheme,
                sftp: SFTPButtonState = .hidden) {
        self.items = items
        self.sftpState = sftp
        self.selectedIndex = min(max(0, selectedIndex), max(0, items.count - 1))
        self.theme = theme
        layer?.backgroundColor = NSColor.clear.cgColor
        updatePulseTimer()
        needsLayout = true
        needsDisplay = true
    }

    func apply(theme: TerminalTheme) {
        self.theme = theme
        layer?.backgroundColor = NSColor.clear.cgColor
        needsDisplay = true
    }

    private func updatePulseTimer() {
        let needsPulse = items.contains { $0.state == .connecting }
        if needsPulse, pulseTimer == nil {
            pulseOn = true
            let timer = Timer(timeInterval: 0.7, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.pulseOn.toggle()
                self.needsDisplay = true
            }
            RunLoop.main.add(timer, forMode: .common)
            pulseTimer = timer
        } else if !needsPulse {
            pulseTimer?.invalidate()
            pulseTimer = nil
            pulseOn = true
        }
    }

    override func layout() {
        super.layout()
        recalculateRects()
    }

    private func recalculateRects() {
        tabRects = []
        closeRects = []
        let size = Self.toolbarButtonSize
        plusRect = NSRect(x: bounds.width - 12 - size, y: Self.toolbarCenterY - size / 2, width: size, height: size)
        sftpRect = sftpState == .hidden ? .zero : plusRect.offsetBy(dx: -(size + 4), dy: 0)
        let tabY = Self.toolbarCenterY - Self.tabHeight / 2
        emptyPillRect = NSRect(x: leadingInset, y: tabY, width: 184, height: Self.tabHeight)

        guard !items.isEmpty else { return }
        let left = leadingInset
        let right = (sftpState == .hidden ? plusRect.minX : sftpRect.minX) - 12
        let available = max(0, right - left)
        guard available > 20 else { return }

        // Flat tabs, separated by a hairline gap instead of a capsule shape.
        let gap: CGFloat = 2
        var widths: [CGFloat] = items.map { item in
            let titleWidth = (item.title as NSString).size(withAttributes: [.font: titleFont]).width
            return min(210, max(104, ceil(titleWidth) + 54))
        }
        var total = widths.reduce(0, +) + CGFloat(items.count - 1) * gap
        if total > available {
            let width = max(82, (available - CGFloat(items.count - 1) * gap) / CGFloat(items.count))
            widths = Array(repeating: width, count: items.count)
            total = CGFloat(items.count) * width + CGFloat(items.count - 1) * gap
        }
        var x = left
        let y = tabY
        let height = Self.tabHeight
        for index in items.indices {
            let rect = NSRect(x: x, y: y, width: widths[index], height: height)
            tabRects.append(rect)
            closeRects.append(NSRect(
                x: rect.maxX - 23,
                y: rect.midY - 9,
                width: 18,
                height: 18
            ))
            x += widths[index] + gap
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.cgContext.clear(bounds)
        recalculateRects()

        if items.isEmpty {
            drawEmptyPill()
        } else {
            for (index, item) in items.enumerated() {
                guard index < tabRects.count else { break }
                drawTab(index: index, item: item)
            }
        }
        drawSFTPButton()
        drawPlusButton()
    }

    private func drawSFTPButton() {
        guard sftpState != .hidden else { return }
        let circle = NSBezierPath(ovalIn: sftpRect.insetBy(dx: 1, dy: 1))
        let active = sftpState == .active
        if active {
            theme.selectedPillFill.setFill()
            circle.fill()
            theme.selectedPillBorder.setStroke()
            circle.lineWidth = 1
            circle.stroke()
        } else if hoveredSFTP {
            theme.pillHoverFill.setFill()
            circle.fill()
            theme.pillBorder.setStroke()
            circle.lineWidth = 1
            circle.stroke()
        }
        let color = active ? theme.accent : (hoveredSFTP ? theme.tabText : theme.tabInactiveText)
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
            .applying(.init(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: "folder", accessibilityDescription: "SFTP 文件")?
            .withSymbolConfiguration(config) else { return }
        let size = image.size
        image.draw(in: NSRect(x: sftpRect.midX - size.width / 2, y: sftpRect.midY - size.height / 2,
                              width: size.width, height: size.height),
                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    private func drawTab(index: Int, item: SessionTabItem) {
        let rect = tabRects[index]
        let isSelected = index == selectedIndex
        let isHovered = hoveredIndex == index
        let shape = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)

        if isSelected {
            theme.tabActiveBackground.withAlphaComponent(theme.isDark ? 0.82 : 1.0).setFill()
            shape.fill()
            theme.pillBorder.setStroke()
            shape.lineWidth = 1
            shape.stroke()
        } else if isHovered {
            theme.pillHoverFill.setFill()
            shape.fill()
        }

        let dotRect = NSRect(x: rect.minX + 12, y: rect.midY - 3.5, width: 7, height: 7)
        drawStatus(item.state, in: dotRect)

        let titleColor = isSelected
            ? theme.tabText
            : (isHovered ? theme.tabText.withAlphaComponent(0.85) : theme.tabInactiveText)
        let showClose = isSelected || isHovered
        let titleRect = NSRect(
            x: rect.minX + 24,
            y: rect.midY - 8,
            width: max(8, rect.width - 24 - (showClose ? 28 : 8)),
            height: 17
        )
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: isSelected ? activeTitleFont : titleFont,
            .foregroundColor: titleColor,
            .paragraphStyle: paragraph
        ]
        (item.title as NSString).draw(in: titleRect, withAttributes: attributes)

        if showClose, index < closeRects.count {
            drawCloseButton(in: closeRects[index], hovered: isHovered && hoveredClose)
        }
    }

    private func drawStatus(_ state: SessionTabItem.State, in rect: NSRect) {
        let color: NSColor
        switch state {
        case .connected:
            color = NSColor(srgbRed: 0.31, green: 0.83, blue: 0.52, alpha: 1)
        case .connecting:
            color = NSColor(srgbRed: 0.98, green: 0.70, blue: 0.26, alpha: pulseOn ? 1 : 0.35)
        case .failed:
            color = NSColor(srgbRed: 0.97, green: 0.40, blue: 0.40, alpha: 1)
        case .disconnected:
            color = theme.subtle.withAlphaComponent(0.55)
        }
        color.setFill()
        NSBezierPath(ovalIn: rect).fill()
    }

    private func drawCloseButton(in rect: NSRect, hovered: Bool) {
        if hovered {
            theme.pillHoverFill.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
        }
        let color = hovered ? theme.tabText : theme.tabInactiveText
        color.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1.2
        path.lineCapStyle = .round
        path.move(to: NSPoint(x: rect.midX - 3.2, y: rect.midY - 3.2))
        path.line(to: NSPoint(x: rect.midX + 3.2, y: rect.midY + 3.2))
        path.move(to: NSPoint(x: rect.midX + 3.2, y: rect.midY - 3.2))
        path.line(to: NSPoint(x: rect.midX - 3.2, y: rect.midY + 3.2))
        path.stroke()
    }

    private func drawPlusButton() {
        if hoveredPlus {
            theme.pillHoverFill.setFill()
            NSBezierPath(ovalIn: plusRect.insetBy(dx: 1, dy: 1)).fill()
            theme.pillBorder.setStroke()
            let outline = NSBezierPath(ovalIn: plusRect.insetBy(dx: 1, dy: 1))
            outline.lineWidth = 1
            outline.stroke()
        }

        let color = hoveredPlus ? theme.tabText : theme.tabInactiveText
        color.setStroke()
        let cross = NSBezierPath()
        cross.lineWidth = 1.5
        cross.lineCapStyle = .round
        let center = NSPoint(x: plusRect.midX, y: plusRect.midY)
        cross.move(to: NSPoint(x: center.x - 6.5, y: center.y))
        cross.line(to: NSPoint(x: center.x + 6.5, y: center.y))
        cross.move(to: NSPoint(x: center.x, y: center.y - 6.5))
        cross.line(to: NSPoint(x: center.x, y: center.y + 6.5))
        cross.stroke()
    }

    private func drawEmptyPill() {
        if hoveredEmptyPill {
            theme.pillHoverFill.setFill()
            NSBezierPath(roundedRect: emptyPillRect, xRadius: 8, yRadius: 8).fill()
        }

        let color = hoveredEmptyPill ? theme.tabText : theme.tabInactiveText
        color.setStroke()
        let plus = NSBezierPath()
        plus.lineWidth = 1.3
        plus.lineCapStyle = .round
        let plusCenter = NSPoint(x: emptyPillRect.minX + 10, y: emptyPillRect.midY)
        plus.move(to: NSPoint(x: plusCenter.x - 4, y: plusCenter.y))
        plus.line(to: NSPoint(x: plusCenter.x + 4, y: plusCenter.y))
        plus.move(to: NSPoint(x: plusCenter.x, y: plusCenter.y - 4))
        plus.line(to: NSPoint(x: plusCenter.x, y: plusCenter.y + 4))
        plus.stroke()

        let text = "快速连接   ⌘N" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: color
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: NSPoint(x: emptyPillRect.minX + 22, y: emptyPillRect.midY - size.height / 2),
            withAttributes: attributes
        )
    }

    // MARK: - Tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        recalculateRects()
        let oldHovered = hoveredIndex
        let oldClose = hoveredClose
        let oldPlus = hoveredPlus
        let oldEmpty = hoveredEmptyPill
        let oldSFTP = hoveredSFTP

        hoveredPlus = plusRect.contains(point)
        hoveredSFTP = sftpState != .hidden && sftpRect.contains(point)
        hoveredEmptyPill = items.isEmpty && emptyPillRect.contains(point)
        hoveredIndex = nil
        hoveredClose = false
        if !items.isEmpty {
            for (index, rect) in tabRects.enumerated() where rect.contains(point) {
                hoveredIndex = index
                if index < closeRects.count, closeRects[index].contains(point) {
                    hoveredClose = true
                }
                break
            }
        }
        if hoveredPlus {
            toolTip = "新建本地终端（⌥⌘T）"
        } else if hoveredSFTP {
            toolTip = sftpState == .active ? "隐藏 SFTP 文件（⇧⌘B）" : "显示 SFTP 文件（⇧⌘B）"
        } else if hoveredEmptyPill {
            toolTip = "快速连接"
        } else {
            toolTip = nil
        }
        (hoveredIndex != nil || hoveredPlus || hoveredSFTP || hoveredEmptyPill
            ? NSCursor.pointingHand
            : NSCursor.arrow).set()
        if oldHovered != hoveredIndex || oldClose != hoveredClose || oldPlus != hoveredPlus
            || oldEmpty != hoveredEmptyPill || oldSFTP != hoveredSFTP {
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        hoveredIndex = nil
        hoveredClose = false
        hoveredPlus = false
        hoveredSFTP = false
        hoveredEmptyPill = false
        toolTip = nil
        NSCursor.arrow.set()
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        recalculateRects()

        if plusRect.contains(point) {
            delegate?.tabsViewDidRequestNewTab(self)
            return
        }
        if sftpState != .hidden, sftpRect.contains(point) {
            delegate?.tabsViewDidToggleSFTP(self)
            return
        }
        if items.isEmpty, emptyPillRect.contains(point) {
            delegate?.tabsViewDidRequestQuickConnect(self)
            return
        }
        for (index, rect) in tabRects.enumerated() where rect.contains(point) {
            if index < closeRects.count, closeRects[index].contains(point) {
                delegate?.tabsView(self, didClose: index)
            } else {
                delegate?.tabsView(self, didSelect: index)
            }
            return
        }
        if event.clickCount >= 2 {
            window?.performZoom(nil)
        } else {
            window?.performDrag(with: event)
        }
    }

    override func otherMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        for (index, rect) in tabRects.enumerated() where rect.contains(point) {
            delegate?.tabsView(self, didClose: index)
            return
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = tabRects.firstIndex(where: { $0.contains(point) }) else { return nil }
        contextIndex = index
        let menu = NSMenu()
        let reconnect = NSMenuItem(title: "重新连接", action: #selector(contextReconnect), keyEquivalent: "")
        reconnect.target = self
        menu.addItem(reconnect)
        menu.addItem(.separator())
        let close = NSMenuItem(title: "关闭标签", action: #selector(contextClose), keyEquivalent: "")
        close.target = self
        menu.addItem(close)
        let closeOthers = NSMenuItem(title: "关闭其他标签", action: #selector(contextCloseOthers), keyEquivalent: "")
        closeOthers.target = self
        closeOthers.isEnabled = items.count > 1
        menu.addItem(closeOthers)
        return menu
    }

    @objc private func contextReconnect() {
        guard let index = contextIndex else { return }
        delegate?.tabsView(self, didRequestReconnect: index)
    }

    @objc private func contextClose() {
        guard let index = contextIndex else { return }
        delegate?.tabsView(self, didClose: index)
    }

    @objc private func contextCloseOthers() {
        guard let index = contextIndex else { return }
        delegate?.tabsView(self, didRequestCloseOthers: index)
    }
}
