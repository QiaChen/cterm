import AppKit
import UniformTypeIdentifiers

/// The transfer list pinned to the bottom of the SFTP panel. Hidden while
/// there is nothing to show.
final class TransferQueueView: NSView {
    private static let rowHeight: CGFloat = 46
    private static let headerHeight: CGFloat = 34
    private static let visibleRows = 4

    var onCancel: ((TransferItem) -> Void)?
    var onRemove: ((TransferItem) -> Void)?
    var onCancelAll: (() -> Void)?
    var onClearFinished: (() -> Void)?

    private var theme: TerminalTheme
    private let divider = NSView()
    private let titleLabel: NSTextField
    private let countBadge = RoundedCardView(fill: .clear, border: .clear, radius: 8)
    private let countLabel: NSTextField
    private let clearButton = HoverTextButton(title: "清除已完成")
    private let cancelAllButton = HoverTextButton(title: "全部取消")
    private let scrollView = NSScrollView()
    private let stack = NSStackView()
    private var rows: [UUID: TransferRowView] = [:]
    private var heightConstraint: NSLayoutConstraint!

    init(theme: TerminalTheme) {
        self.theme = theme
        titleLabel = UIFactory.label("传输", size: 12, weight: .semibold, color: theme.tabText)
        countLabel = UIFactory.label("", size: 10.5, weight: .semibold, color: theme.accent, alignment: .center)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        divider.wantsLayer = true
        divider.translatesAutoresizingMaskIntoConstraints = false
        countBadge.layer?.borderWidth = 0
        countBadge.addSubview(countLabel)
        clearButton.target = self
        clearButton.action = #selector(clearFinished)
        cancelAllButton.target = self
        cancelAllButton.action = #selector(cancelAll)
        let actions = NSStackView(views: [clearButton, cancelAllButton])
        actions.spacing = 2
        actions.translatesAutoresizingMaskIntoConstraints = false
        [divider, titleLabel, countBadge, actions].forEach(addSubview)

        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scrollView.documentView = document
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        heightConstraint = heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            heightConstraint,
            divider.topAnchor.constraint(equalTo: topAnchor),
            divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            titleLabel.centerYAnchor.constraint(equalTo: topAnchor, constant: Self.headerHeight / 2 + 1),
            countBadge.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 6),
            countBadge.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            countBadge.heightAnchor.constraint(equalToConstant: 16),
            countBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: 16),
            countLabel.leadingAnchor.constraint(equalTo: countBadge.leadingAnchor, constant: 5),
            countLabel.trailingAnchor.constraint(equalTo: countBadge.trailingAnchor, constant: -5),
            countLabel.centerYAnchor.constraint(equalTo: countBadge.centerYAnchor),
            actions.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            actions.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            actions.leadingAnchor.constraint(greaterThanOrEqualTo: countBadge.trailingAnchor, constant: 8),
            scrollView.topAnchor.constraint(equalTo: topAnchor, constant: Self.headerHeight),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            document.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        ])
        apply(theme: theme)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(items: [TransferItem]) {
        let ids = Set(items.map(\.id))
        for (id, row) in rows where !ids.contains(id) {
            row.removeFromSuperview()
            rows[id] = nil
        }
        // Newest first, so a fresh transfer is always in view.
        for (position, item) in items.reversed().enumerated() {
            let row: TransferRowView
            if let existing = rows[item.id] {
                row = existing
            } else {
                row = TransferRowView(item: item, theme: theme)
                row.onAction = { [weak self] item in
                    if item.isFinished { self?.onRemove?(item) } else { self?.onCancel?(item) }
                }
                rows[item.id] = row
                row.heightAnchor.constraint(equalToConstant: Self.rowHeight).isActive = true
            }
            if stack.arrangedSubviews.firstIndex(of: row) != position {
                row.removeFromSuperview()
                stack.insertArrangedSubview(row, at: min(position, stack.arrangedSubviews.count))
                row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
            row.refresh()
        }

        let active = items.filter { !$0.isFinished }.count
        countLabel.stringValue = "\(active)"
        countBadge.isHidden = active == 0
        cancelAllButton.isHidden = active == 0
        clearButton.isHidden = items.allSatisfy { !$0.isFinished }
        let visible = min(items.count, Self.visibleRows)
        heightConstraint.constant = items.isEmpty ? 0 : Self.headerHeight + CGFloat(visible) * Self.rowHeight + 6
        isHidden = items.isEmpty
    }

    func apply(theme: TerminalTheme) {
        self.theme = theme
        divider.layer?.backgroundColor = theme.sidebarDivider.cgColor
        titleLabel.textColor = theme.tabText
        countBadge.fillColor = theme.selectedPillFill
        countLabel.textColor = theme.accent
        for button in [clearButton, cancelAllButton] {
            button.apply(text: theme.tabInactiveText, hoverText: theme.tabText, hoverFill: theme.pillHoverFill)
        }
        rows.values.forEach { $0.apply(theme: theme) }
    }

    @objc private func clearFinished() { onClearFinished?() }
    @objc private func cancelAll() { onCancelAll?() }
}

/// A small text button that picks up a pill fill on hover.
final class HoverTextButton: NSButton {
    private var textColor: NSColor = .secondaryLabelColor
    private var hoverTextColor: NSColor = .labelColor
    private var hoverFill: NSColor = .clear
    private var hovering = false
    private var trackingAreaRef: NSTrackingArea?

    init(title: String) {
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = 6
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 22).isActive = true
        redraw()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override var intrinsicContentSize: NSSize {
        let size = attributedTitle.size()
        return NSSize(width: ceil(size.width) + 16, height: 22)
    }

    func apply(text: NSColor, hoverText: NSColor, hoverFill: NSColor) {
        textColor = text
        hoverTextColor = hoverText
        self.hoverFill = hoverFill
        redraw()
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
        redraw()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        redraw()
    }

    private func redraw() {
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
            .foregroundColor: hovering ? hoverTextColor : textColor
        ])
        layer?.backgroundColor = (hovering ? hoverFill : .clear).cgColor
        invalidateIntrinsicContentSize()
    }
}

private final class TransferRowView: NSView {
    let item: TransferItem
    var onAction: ((TransferItem) -> Void)?

    private var theme: TerminalTheme
    private let hoverBackground = NSView()
    private let fileIcon = NSImageView()
    private let directionBadge = NSImageView()
    private let nameLabel: NSTextField
    private let detailLabel: NSTextField
    private let progress = TransferProgressBar()
    private let statusIcon = NSImageView()
    private let actionButton: HoverIconButton
    private var hovering = false
    private var trackingAreaRef: NSTrackingArea?

    init(item: TransferItem, theme: TerminalTheme) {
        self.item = item
        self.theme = theme
        nameLabel = UIFactory.label(item.name, size: 12.5, weight: .medium, color: theme.tabText)
        detailLabel = UIFactory.label("", size: 11, color: theme.subtle)
        actionButton = HoverIconButton(symbol: "xmark", pointSize: 10, diameter: 22, target: nil, action: nil)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        hoverBackground.wantsLayer = true
        hoverBackground.layer?.cornerRadius = 8
        hoverBackground.translatesAutoresizingMaskIntoConstraints = false

        let type: UTType = item.isDirectory
            ? .folder
            : (UTType(filenameExtension: (item.name as NSString).pathExtension) ?? .data)
        fileIcon.image = NSWorkspace.shared.icon(for: type)
        fileIcon.imageScaling = .scaleProportionallyUpOrDown
        fileIcon.translatesAutoresizingMaskIntoConstraints = false

        // A small arrow on the icon says which way the file is going.
        directionBadge.image = NSImage(systemSymbolName: item.direction == .upload ? "arrow.up.circle.fill" : "arrow.down.circle.fill",
                                       accessibilityDescription: item.direction == .upload ? "上传" : "下载")
        directionBadge.symbolConfiguration = .init(pointSize: 10, weight: .bold)
        directionBadge.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.heightAnchor.constraint(equalToConstant: 3).isActive = true

        let text = NSStackView(views: [nameLabel, detailLabel, progress])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.setCustomSpacing(5, after: detailLabel)
        text.translatesAutoresizingMaskIntoConstraints = false

        statusIcon.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
        statusIcon.translatesAutoresizingMaskIntoConstraints = false
        actionButton.target = self
        actionButton.action = #selector(performAction)

        [hoverBackground, fileIcon, directionBadge, text, statusIcon, actionButton].forEach(addSubview)
        NSLayoutConstraint.activate([
            hoverBackground.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            hoverBackground.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            hoverBackground.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            hoverBackground.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),

            fileIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            fileIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            fileIcon.widthAnchor.constraint(equalToConstant: 26),
            fileIcon.heightAnchor.constraint(equalToConstant: 26),
            directionBadge.trailingAnchor.constraint(equalTo: fileIcon.trailingAnchor, constant: 3),
            directionBadge.bottomAnchor.constraint(equalTo: fileIcon.bottomAnchor, constant: 2),

            text.leadingAnchor.constraint(equalTo: fileIcon.trailingAnchor, constant: 10),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.trailingAnchor.constraint(equalTo: actionButton.leadingAnchor, constant: -6),
            progress.widthAnchor.constraint(equalTo: text.widthAnchor),

            actionButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            actionButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusIcon.centerXAnchor.constraint(equalTo: actionButton.centerXAnchor),
            statusIcon.centerYAnchor.constraint(equalTo: actionButton.centerYAnchor)
        ])
        apply(theme: theme)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var successColor: NSColor { theme.palette[2] }
    private var failureColor: NSColor { theme.palette[1] }

    func refresh() {
        let bytes = ByteCountFormatter.transferString
        progress.fraction = item.fraction
        progress.isHidden = item.state != .running
        detailLabel.textColor = theme.subtle
        toolTip = nil
        var status: (symbol: String, color: NSColor)?

        switch item.state {
        case .queued:
            detailLabel.stringValue = "等待中"
        case .running:
            var text = item.totalBytes > 0
                ? "\(bytes(item.transferredBytes)) / \(bytes(item.totalBytes))"
                : bytes(item.transferredBytes)
            if item.bytesPerSecond > 0 {
                text += " · \(bytes(UInt64(item.bytesPerSecond)))/s"
            }
            detailLabel.stringValue = text
        case .completed:
            let verb = item.isEditSync ? "已同步回服务器" : (item.direction == .upload ? "已上传" : "已下载")
            detailLabel.stringValue = "\(verb) · \(bytes(item.totalBytes))"
            status = ("checkmark.circle.fill", successColor)
            if item.direction == .download { toolTip = "双击在访达中显示" }
        case .failed(let message):
            detailLabel.stringValue = message.hasSuffix("。") ? String(message.dropLast()) : message
            detailLabel.textColor = failureColor
            status = ("exclamationmark.circle.fill", failureColor)
            toolTip = message
        case .cancelled:
            detailLabel.stringValue = "已取消"
            status = ("minus.circle.fill", theme.subtle.withAlphaComponent(0.7))
        }

        if let status {
            statusIcon.image = NSImage(systemSymbolName: status.symbol, accessibilityDescription: nil)
            statusIcon.contentTintColor = status.color
        }
        // A running transfer always offers cancel; a finished one shows its
        // result and turns into a remove button on hover.
        let showsButton = !item.isFinished || hovering
        actionButton.isHidden = !showsButton
        actionButton.toolTip = item.isFinished ? "从列表移除" : "取消"
        statusIcon.isHidden = showsButton || status == nil
        hoverBackground.layer?.backgroundColor = (hovering ? theme.pillHoverFill : .clear).cgColor
    }

    func apply(theme: TerminalTheme) {
        self.theme = theme
        nameLabel.textColor = theme.tabText
        directionBadge.contentTintColor = theme.accent
        actionButton.contentTintColor = theme.tabInactiveText
        actionButton.hoverFill = theme.pillHoverFill
        progress.trackColor = theme.pillFill
        progress.fillColor = theme.accent
        refresh()
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
        refresh()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        refresh()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, item.direction == .download, item.state == .completed {
            NSWorkspace.shared.activateFileViewerSelecting([item.localURL])
        }
    }

    @objc private func performAction() {
        onAction?(item)
    }
}

private final class TransferProgressBar: NSView {
    var fraction: Double = 0 { didSet { needsDisplay = true } }
    var trackColor: NSColor = .quaternaryLabelColor { didSet { needsDisplay = true } }
    var fillColor: NSColor = .controlAccentColor { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        trackColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        guard fraction > 0 else { return }
        var filled = bounds
        filled.size.width = max(bounds.height, bounds.width * CGFloat(fraction))
        fillColor.setFill()
        NSBezierPath(roundedRect: filled, xRadius: radius, yRadius: radius).fill()
    }
}
