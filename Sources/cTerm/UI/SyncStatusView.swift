import AppKit

/// The sidebar's cloud sync line: 已同步 / 未同步 / 未开启云同步.
/// Clicking it syncs now, or opens Settings when sync is off.
final class SyncStatusView: NSView {
    var onClick: (() -> Void)?

    private let icon = NSImageView()
    private let titleLabel = UIFactory.label("", size: 13, weight: .medium, color: .labelColor)
    private let detailLabel = UIFactory.label("", size: 11, weight: .regular, color: .secondaryLabelColor, alignment: .right)
    private var theme: TerminalTheme
    private var status: CloudSyncStatus = .disabled
    private var hovering = false
    private var trackingAreaRef: NSTrackingArea?

    init(theme: TerminalTheme) {
        self.theme = theme
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.borderWidth = 1
        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        addSubview(icon)
        addSubview(titleLabel)
        addSubview(detailLabel)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 14),
            titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            detailLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8),
            detailLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            detailLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        setAccessibilityRole(.button)
        update(status: CloudSyncManager.shared.currentStatus)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func apply(theme: TerminalTheme) {
        self.theme = theme
        update(status: status)
    }

    /// The icon and colour for a sync state; the collapsed sidebar uses it too.
    static func symbol(for status: CloudSyncStatus, theme: TerminalTheme) -> (name: String, tint: NSColor) {
        switch status {
        case .disabled: return ("icloud.slash", theme.subtle)
        case .syncing: return ("arrow.triangle.2.circlepath.icloud", theme.accent)
        case .synced: return ("checkmark.icloud", theme.ansiColor(2))
        case .pending: return ("icloud", theme.ansiColor(3))
        case .failed: return ("exclamationmark.icloud", theme.ansiColor(1))
        }
    }

    /// Tooltip text for a sync state; the collapsed sidebar uses it too.
    static func toolTip(for status: CloudSyncStatus) -> String {
        let manager = CloudSyncManager.shared
        switch status {
        case .disabled:
            return "未开启云同步\n点击打开设置并开启 OneDrive 云同步"
        case .failed(let message):
            return "未同步：\(message)\n点击重试"
        default:
            let head = [status.title, status.detail].compactMap { $0 }.joined(separator: " · ")
            return [head, manager.filePath.map { "OneDrive：\($0)" }, "点击立即同步"]
                .compactMap { $0 }.joined(separator: "\n")
        }
    }

    func update(status: CloudSyncStatus) {
        self.status = status
        let (symbol, tint) = Self.symbol(for: status, theme: theme)
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: status.title)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .medium))
        icon.contentTintColor = tint
        titleLabel.stringValue = status.title
        titleLabel.textColor = status == .disabled ? theme.subtle : theme.tabText
        detailLabel.stringValue = status.detail ?? ""
        detailLabel.textColor = theme.subtle
        setAccessibilityLabel([status.title, status.detail].compactMap { $0 }.joined(separator: "，"))

        let manager = CloudSyncManager.shared
        switch status {
        case .disabled:
            toolTip = "点击打开设置并开启 OneDrive 云同步"
        case .failed(let message):
            toolTip = "\(message)\n点击重试"
        default:
            toolTip = [manager.filePath.map { "OneDrive：\($0)" }, "点击立即同步"]
                .compactMap { $0 }.joined(separator: "\n")
        }
        updateBackground()
    }

    private func updateBackground() {
        layer?.backgroundColor = (hovering ? theme.pillHoverFill : theme.pillFill).cgColor
        layer?.borderColor = theme.pillBorder.cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        updateBackground()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        updateBackground()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onClick?()
        }
    }

    override func mouseDown(with event: NSEvent) {}
}
