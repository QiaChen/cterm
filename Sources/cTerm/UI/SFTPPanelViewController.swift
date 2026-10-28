import AppKit
import Citadel
import UniformTypeIdentifiers

/// The file browser beside a session's terminal. It borrows the session's SSH
/// connection for an SFTP channel, so there is no second login.
final class SFTPPanelViewController: NSViewController {
    private enum Status: Equatable {
        case offline(String)
        case connecting
        case loading
        case ready
        case failed(String)
    }

    private enum ConflictChoice {
        case replace, keepBoth, skip
    }

    private static let showHiddenKey = "cterm.sftpShowHidden"

    /// Opens an SFTP channel on the session's live connection.
    var openClient: (() async throws -> SFTPClient)?
    /// Runs a shell command on the session's connection (chmod, archives).
    var runCommand: ((String) async throws -> RemoteCommandResult)?
    /// Types `cd <path>` into the session's terminal.
    var onChangeDirectoryInTerminal: ((String) -> Void)?

    let queue = TransferQueue()
    /// Files open in a local editor, synced back on every save.
    let edits = RemoteEditManager()

    private var theme: TerminalTheme
    private var session: SFTPSession?
    private var connectTask: Task<Void, Never>?
    private var loadGeneration = 0
    private var allEntries: [RemoteEntry] = []
    private var entries: [RemoteEntry] = []
    private var currentPath: String?
    private var status: Status = .offline("SSH 会话未连接。")
    private var showHidden = UserDefaults.standard.bool(forKey: SFTPPanelViewController.showHiddenKey)
    private var reloadScheduled = false

    private let background = NSView()
    private let dragArea = WindowDragView()
    private let loadingSpinner = NSProgressIndicator()
    private var loadingIndicatorTimer: Timer?
    private var isShowingLoading = false
    private let titleLabel: NSTextField
    private var newFolderButton: HoverIconButton!
    private var refreshButton: HoverIconButton!
    private var moreButton: HoverIconButton!
    private var upButton: HoverIconButton!
    /// A slightly deeper band behind the title, toolbar and path, setting
    /// them apart from the file list.
    private let headerBackground = NSView()
    private let pathField = NSTextField()
    private let pathBackground = RoundedCardView(fill: .clear, border: .clear, radius: 7)
    private let topDivider = NSView()
    private let scrollView = NSScrollView()
    private let tableView = SFTPTableView()
    private let statusLabel: NSTextField
    private let retryButton = NSButton()
    private let transferView: TransferQueueView
    private var iconCache: [String: NSImage] = [:]

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    init(theme: TerminalTheme) {
        self.theme = theme
        titleLabel = UIFactory.label("文件", size: 14, weight: .semibold, color: theme.tabText)
        statusLabel = UIFactory.wrappingLabel("", size: 12, color: theme.subtle)
        transferView = TransferQueueView(theme: theme)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        view = root

        background.wantsLayer = true
        background.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(background)
        headerBackground.wantsLayer = true
        headerBackground.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(headerBackground)
        // The header sits in the window's title strip, so it drags the window
        // just like the empty part of the tab bar.
        dragArea.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(dragArea)

        loadingSpinner.style = .spinning
        loadingSpinner.controlSize = .regular
        loadingSpinner.isDisplayedWhenStopped = false
        loadingSpinner.translatesAutoresizingMaskIntoConstraints = false

        newFolderButton = toolbarButton("folder.badge.plus", tip: "新建文件夹…", action: #selector(newFolder(_:)))
        refreshButton = toolbarButton("arrow.clockwise", tip: "刷新", action: #selector(refresh(_:)))
        moreButton = toolbarButton("ellipsis", tip: "更多", action: #selector(showMoreMenu(_:)))
        upButton = toolbarButton("arrow.up", tip: "上级目录（⌘↑）", action: #selector(goUp(_:)), pointSize: 13)
        let tools = NSStackView(views: [newFolderButton, refreshButton, moreButton])
        tools.spacing = 4
        tools.translatesAutoresizingMaskIntoConstraints = false

        pathBackground.translatesAutoresizingMaskIntoConstraints = false
        pathField.isBordered = false
        pathField.drawsBackground = false
        pathField.focusRingType = .none
        pathField.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        pathField.lineBreakMode = .byTruncatingHead
        pathField.cell?.usesSingleLineMode = true
        pathField.placeholderString = "远程路径"
        pathField.target = self
        pathField.action = #selector(pathEntered(_:))
        pathField.translatesAutoresizingMaskIntoConstraints = false

        topDivider.wantsLayer = true
        topDivider.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: .init("name"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 26
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.backgroundColor = .clear
        tableView.style = .plain
        tableView.allowsMultipleSelection = true
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.focusRingType = .none
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(openClicked(_:))
        tableView.registerForDraggedTypes([.fileURL])
        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)
        tableView.draggingDestinationFeedbackStyle = .regular
        tableView.onOpen = { [weak self] in self?.openSelection() }
        tableView.onDelete = { [weak self] in self?.deleteSelection() }
        tableView.onParent = { [weak self] in self?.goUp(nil) }
        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu

        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        // Without this AppKit recomputes the insets and drops the top one.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 8, left: 0, bottom: 6, right: 0)
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.alignment = .center
        retryButton.title = "重试"
        retryButton.bezelStyle = .rounded
        retryButton.controlSize = .small
        retryButton.target = self
        retryButton.action = #selector(retry(_:))
        retryButton.translatesAutoresizingMaskIntoConstraints = false

        transferView.onCancel = { [weak self] item in self?.queue.cancel(item) }
        transferView.onRemove = { [weak self] item in self?.queue.remove(item) }
        transferView.onCancelAll = { [weak self] in self?.queue.cancelAll() }
        transferView.onClearFinished = { [weak self] in self?.queue.clearFinished() }
        queue.onChange = { [weak self] in
            guard let self else { return }
            self.transferView.update(items: self.queue.items)
        }
        edits.onChange = { [weak self] in
            self?.tableView.reloadData()
        }
        edits.resolveConflict = { [weak self] edit in
            await self?.askEditConflict(edit) ?? .discard
        }
        queue.onItemFinished = { [weak self] item in
            self?.transferFinished(item)
        }

        [titleLabel, tools, upButton, pathBackground, pathField, topDivider, scrollView,
         statusLabel, retryButton, loadingSpinner, transferView].forEach(root.addSubview)

        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            background.topAnchor.constraint(equalTo: root.topAnchor),
            background.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            headerBackground.topAnchor.constraint(equalTo: root.topAnchor),
            headerBackground.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            headerBackground.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            headerBackground.bottomAnchor.constraint(equalTo: topDivider.topAnchor),

            dragArea.topAnchor.constraint(equalTo: root.topAnchor),
            dragArea.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            dragArea.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            dragArea.heightAnchor.constraint(equalToConstant: 40),

            // Same height and centre line as the tab strip beside it.
            titleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            titleLabel.centerYAnchor.constraint(equalTo: tools.centerYAnchor),
            tools.centerYAnchor.constraint(equalTo: root.topAnchor, constant: SessionTabsView.toolbarCenterY),
            tools.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: tools.leadingAnchor, constant: -6),

            upButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 7),
            upButton.centerYAnchor.constraint(equalTo: pathBackground.centerYAnchor),
            pathBackground.topAnchor.constraint(equalTo: root.topAnchor, constant: 42),
            pathBackground.leadingAnchor.constraint(equalTo: upButton.trailingAnchor, constant: 4),
            pathBackground.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            pathBackground.heightAnchor.constraint(equalToConstant: 26),
            pathField.leadingAnchor.constraint(equalTo: pathBackground.leadingAnchor, constant: 8),
            pathField.trailingAnchor.constraint(equalTo: pathBackground.trailingAnchor, constant: -8),
            pathField.centerYAnchor.constraint(equalTo: pathBackground.centerYAnchor),

            topDivider.topAnchor.constraint(equalTo: pathBackground.bottomAnchor, constant: 8),
            topDivider.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            topDivider.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            topDivider.heightAnchor.constraint(equalToConstant: 1),

            scrollView.topAnchor.constraint(equalTo: topDivider.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: transferView.topAnchor),

            statusLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor, constant: -14),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -20),
            retryButton.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 10),
            retryButton.centerXAnchor.constraint(equalTo: statusLabel.centerXAnchor),
            loadingSpinner.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            loadingSpinner.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor, constant: -14),

            transferView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            transferView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            transferView.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])

        apply(theme: theme)
        render()
    }

    private func toolbarButton(_ symbol: String, tip: String, action: Selector,
                               pointSize: CGFloat = 16) -> HoverIconButton {
        let button = HoverIconButton(symbol: symbol, pointSize: pointSize, diameter: pointSize + 14,
                                     target: self, action: action)
        button.contentTintColor = theme.tabInactiveText
        button.toolTip = tip
        button.setAccessibilityLabel(tip)
        return button
    }

    // MARK: - Connection

    var isConnected: Bool { session?.isActive == true }
    var hasActiveTransfers: Bool { queue.activeCount > 0 }

    /// Opens the SFTP channel if the panel has none. Called when the panel is
    /// shown and whenever the session (re)connects while it is shown.
    func connectIfNeeded() {
        guard session == nil, connectTask == nil, let openClient else { return }
        status = .connecting
        render()
        connectTask = Task { [weak self] in
            do {
                let client = try await openClient()
                guard let self else {
                    try? await client.close()
                    return
                }
                self.connectTask = nil
                let session = SFTPSession(client: client)
                self.session = session
                self.queue.attach(session)
                let start: String
                if let current = self.currentPath {
                    start = current
                } else {
                    start = (try? await session.homeDirectory()) ?? "/"
                }
                self.load(start, fallback: "/")
            } catch {
                guard let self else { return }
                self.connectTask = nil
                self.status = .failed(SFTPErrorMessage.describe(error))
                self.render()
            }
        }
    }

    /// The SSH session went away; the SFTP channel went with it.
    func connectionDidEnd(reason: String = "SSH 会话已断开。") {
        connectTask?.cancel()
        connectTask = nil
        edits.stopAll()
        session?.close()
        session = nil
        queue.detach(reason: "连接已断开")
        loadGeneration += 1
        endLoadingIndicator()
        status = .offline(reason)
        render()
    }

    func shutdown() {
        queue.cancelAll()
        connectionDidEnd()
    }

    #if DEBUG
    func debugHoverButtons() {
        [newFolderButton, refreshButton, moreButton, upButton].forEach { $0?.debugSetHovering(true) }
    }

    func debugPermissions() {
        tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        editPermissions(nil)
    }

    func debugOpen(_ path: String) {
        load(path, reportErrors: true)
    }

    /// Starts editing a file without launching an editor, then saves a
    /// change to the working copy after a moment.
    func debugEdit(_ name: String) {
        // Also show the right-click outline on another row.
        if let row = entries.firstIndex(where: { $0.name == "KeyGenerator.png" }) {
            tableView.contextRow = row
        }
        guard let session, let entry = allEntries.first(where: { $0.name == name }) else { return }
        guard let edit = edits.edit(entry, sftp: session, queue: queue, open: { _ in }) else { return }
        Task {
            while edit.state == .downloading {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            try? await Task.sleep(nanoseconds: 600_000_000)
            try? Data("edited in cTerm\n".utf8).write(to: edit.localURL)
        }
    }

    /// Queues a mix of transfers so the transfer list can be inspected.
    func debugDemoTransfers(into folder: URL) {
        guard let currentPath else { return }
        for entry in entries.prefix(3) {
            queue.enqueueDownload(entry, to: folder.appendingPathComponent(entry.name))
        }
        let probe = folder.appendingPathComponent("deploy-notes.txt")
        try? Data(count: 2048).write(to: probe)
        queue.enqueueUpload(probe, to: RemotePath.join(currentPath, "deploy-notes.txt"))
        if let last = entries.last {
            let item = queue.enqueueDownload(last, to: folder.appendingPathComponent(last.name))
            queue.cancel(item)
        }
    }

    var debugLoadingState: String {
        "loading \(isShowingLoading), list alpha \(String(format: "%.2f", scrollView.alphaValue)), "
            + "path \(pathField.stringValue), rows \(entries.count)"
    }
    #endif

    // MARK: - Listing

    private func load(_ path: String, fallback: String? = nil, selecting name: String? = nil,
                      reportErrors: Bool = false) {
        guard let session else { return }
        loadGeneration += 1
        let generation = loadGeneration
        if allEntries.isEmpty || currentPath != path {
            status = .loading
            render()
        }
        beginLoadingIndicator(showing: path)
        Task { [weak self] in
            do {
                let resolved = try await session.realPath(path)
                let list = try await session.list(resolved)
                guard let self, generation == self.loadGeneration else { return }
                self.endLoadingIndicator()
                let changedDirectory = self.currentPath != resolved
                self.currentPath = resolved
                self.allEntries = list
                self.status = .ready
                self.applyFilter(preserveSelection: !changedDirectory, selecting: name)
                if changedDirectory { self.tableView.scrollRowToVisible(0) }
            } catch {
                guard let self, generation == self.loadGeneration else { return }
                self.endLoadingIndicator()
                if let fallback, fallback != path {
                    self.load(fallback)
                    return
                }
                let message = SFTPErrorMessage.describe(error)
                if reportErrors, self.currentPath != nil {
                    // Keep the folder on screen; only the jump failed.
                    self.status = .ready
                    self.render()
                    self.showError("无法打开“\(path)”", message)
                } else {
                    self.status = session.isActive ? .failed(message) : .offline(message)
                    self.render()
                }
            }
        }
    }

    /// Dims the list and spins while a folder loads. Fast loads finish before
    /// the short delay, so a quick refresh doesn't flash.
    private func beginLoadingIndicator(showing path: String) {
        guard isViewLoaded else { return }
        if !path.hasPrefix(".") { pathField.stringValue = path }
        loadingIndicatorTimer?.invalidate()
        let timer = Timer(timeInterval: 0.12, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isShowingLoading = true
                self.loadingSpinner.startAnimation(nil)
                if self.scrollView.alphaValue > 0 { self.scrollView.alphaValue = 0.35 }
            }
        }
        // No tolerance: a coalesced timer would show the spinner too late.
        timer.tolerance = 0
        RunLoop.main.add(timer, forMode: .common)
        loadingIndicatorTimer = timer
    }

    private func endLoadingIndicator() {
        loadingIndicatorTimer?.invalidate()
        loadingIndicatorTimer = nil
        isShowingLoading = false
        guard isViewLoaded else { return }
        loadingSpinner.stopAnimation(nil)
    }

    private func applyFilter(preserveSelection: Bool, selecting name: String? = nil) {
        let selected = preserveSelection ? Set(selectedEntries.map(\.name)) : []
        entries = showHidden ? allEntries : allEntries.filter { !$0.name.hasPrefix(".") }
        tableView.reloadData()
        var rows = IndexSet()
        for (index, entry) in entries.enumerated()
        where selected.contains(entry.name) || entry.name == name {
            rows.insert(index)
        }
        tableView.selectRowIndexes(rows, byExtendingSelection: false)
        if let first = rows.first { tableView.scrollRowToVisible(first) }
        render()
    }

    private func reloadSoon() {
        guard !reloadScheduled else { return }
        reloadScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.reloadScheduled = false
            if let path = self.currentPath { self.load(path) }
        }
    }

    private func render() {
        guard isViewLoaded else { return }
        pathField.stringValue = currentPath ?? ""
        let ready = session != nil
        [newFolderButton, refreshButton, moreButton, upButton].forEach { $0?.isEnabled = ready }
        pathField.isEnabled = ready

        var message: String?
        var showsRetry = false
        switch status {
        case .offline(let text):
            message = text
        case .connecting:
            message = "正在打开 SFTP…"
        case .loading:
            message = nil
        case .ready:
            message = entries.isEmpty ? "此文件夹为空\n可以把文件从访达拖到这里上传" : nil
        case .failed(let text):
            message = text
            showsRetry = true
        }
        let blocking: Bool
        switch status {
        case .ready, .loading: blocking = false
        default: blocking = true
        }
        if status != .loading { scrollView.alphaValue = blocking ? 0 : 1 }
        statusLabel.stringValue = message ?? ""
        statusLabel.isHidden = message == nil
        retryButton.isHidden = !showsRetry
    }

    // MARK: - Theme

    func apply(theme: TerminalTheme) {
        self.theme = theme
        guard isViewLoaded else { return }
        background.layer?.backgroundColor = (theme.isDark
            ? NSColor.white.withAlphaComponent(0.02)
            : NSColor.black.withAlphaComponent(0.015)).cgColor
        titleLabel.textColor = theme.tabText
        statusLabel.textColor = theme.subtle
        headerBackground.layer?.backgroundColor = (theme.isDark
            ? NSColor.black.withAlphaComponent(0.14)
            : NSColor.black.withAlphaComponent(0.035)).cgColor
        for button in [newFolderButton, refreshButton, moreButton, upButton] {
            button?.contentTintColor = theme.tabInactiveText
            button?.hoverFill = theme.pillHoverFill
        }
        pathBackground.fillColor = theme.pillFill
        pathBackground.borderColor = theme.pillBorder
        pathField.textColor = theme.tabText
        topDivider.layer?.backgroundColor = theme.sidebarDivider.cgColor
        tableView.selectionFill = theme.selectedPillFill
        tableView.contextOutline = theme.selectedPillBorder
        transferView.apply(theme: theme)
        tableView.reloadData()
    }

    // MARK: - Selection helpers

    private var selectedEntries: [RemoteEntry] {
        tableView.selectedRowIndexes.compactMap { $0 < entries.count ? entries[$0] : nil }
    }

    /// The rows a context menu acts on: the selection if the click was on it,
    /// otherwise just the clicked row.
    private var targetEntries: [RemoteEntry] {
        let clicked = tableView.contextRow
        if clicked >= 0, clicked < entries.count, !tableView.selectedRowIndexes.contains(clicked) {
            return [entries[clicked]]
        }
        return selectedEntries
    }

    private func icon(for entry: RemoteEntry) -> NSImage {
        let key = entry.isDirectory ? "/" : (entry.name as NSString).pathExtension.lowercased()
        if let cached = iconCache[key] { return cached }
        let type: UTType = entry.isDirectory
            ? .folder
            : (UTType(filenameExtension: key) ?? .data)
        let image = NSWorkspace.shared.icon(for: type)
        iconCache[key] = image
        return image
    }

    // MARK: - Actions

    @objc private func retry(_ sender: Any?) {
        connectIfNeeded()
    }

    /// Less frequent actions live behind "…" to keep the header quiet.
    @objc private func showMoreMenu(_ sender: Any?) {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector, state: NSControl.StateValue = .off) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.state = state
            menu.addItem(item)
        }
        add("上传文件…", #selector(uploadFiles(_:)))
        menu.addItem(.separator())
        add("显示隐藏文件", #selector(toggleHidden(_:)), state: showHidden ? .on : .off)
        menu.addItem(.separator())
        add("在终端中前往当前目录", #selector(cdCurrentInTerminal(_:)))
        add("复制当前路径", #selector(copyCurrentPath(_:)))
        let below = moreButton.isFlipped ? moreButton.bounds.height + 4 : -4
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: below), in: moreButton)
    }

    @objc private func cdCurrentInTerminal(_ sender: Any?) {
        guard let currentPath else { return }
        onChangeDirectoryInTerminal?(currentPath)
    }

    @objc private func copyCurrentPath(_ sender: Any?) {
        guard let currentPath else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(currentPath, forType: .string)
    }

    @objc private func refresh(_ sender: Any?) {
        guard let currentPath else { return }
        load(currentPath, reportErrors: true)
    }

    @objc private func toggleHidden(_ sender: Any?) {
        showHidden.toggle()
        UserDefaults.standard.set(showHidden, forKey: Self.showHiddenKey)
        applyFilter(preserveSelection: true)
    }

    @objc private func goUp(_ sender: Any?) {
        guard let currentPath, currentPath != "/" else { return }
        load(RemotePath.parent(of: currentPath), selecting: RemotePath.name(of: currentPath), reportErrors: true)
    }

    @objc private func pathEntered(_ sender: Any?) {
        var path = pathField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else {
            render()
            return
        }
        if path == "~" || path.hasPrefix("~/") {
            path = "." + path.dropFirst()
        } else if !path.hasPrefix("/"), let currentPath {
            path = RemotePath.join(currentPath, path)
        }
        load(path, reportErrors: true)
        view.window?.makeFirstResponder(tableView)
    }

    @objc private func openClicked(_ sender: Any?) {
        guard tableView.clickedRow >= 0 else { return }
        openSelection()
    }

    private func openSelection() {
        let selection = selectedEntries
        if selection.count == 1, let entry = selection.first, entry.isDirectory {
            load(entry.path, reportErrors: true)
        } else if !selection.isEmpty {
            download(selection, to: nil)
        }
    }

    @objc private func uploadFiles(_ sender: Any?) {
        guard let window = view.window, let currentPath else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "上传"
        panel.message = "上传到 \(currentPath)"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self else { return }
            self.upload(panel.urls, into: currentPath)
        }
    }

    @objc private func newFolder(_ sender: Any?) {
        guard let currentPath else { return }
        promptName(title: "新建文件夹", message: "在 \(currentPath) 中创建", initial: "未命名文件夹",
                   confirm: "创建") { [weak self] name in
            guard let self, let name, let session = self.session else { return }
            Task {
                do {
                    try await session.makeDirectory(RemotePath.join(currentPath, name))
                    self.load(currentPath, selecting: name)
                } catch {
                    self.showError("无法创建文件夹", SFTPErrorMessage.describe(error))
                }
            }
        }
    }

    @objc private func downloadToDownloads(_ sender: Any?) {
        download(targetEntries, to: nil)
    }

    @objc private func downloadToFolder(_ sender: Any?) {
        let targets = targetEntries
        guard !targets.isEmpty, let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "下载到这里"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let folder = panel.url else { return }
            self?.download(targets, to: folder)
        }
    }

    @objc private func openFolder(_ sender: Any?) {
        guard let entry = targetEntries.first, entry.isDirectory else { return }
        load(entry.path, reportErrors: true)
    }

    @objc private func cdInTerminal(_ sender: Any?) {
        let target = targetEntries.first
        let path: String?
        if let target {
            path = target.isDirectory ? target.path : RemotePath.parent(of: target.path)
        } else {
            path = currentPath
        }
        guard let path else { return }
        onChangeDirectoryInTerminal?(path)
    }

    @objc private func copyPath(_ sender: Any?) {
        let paths = targetEntries.map(\.path)
        let text = paths.isEmpty ? (currentPath ?? "") : paths.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func renameEntry(_ sender: Any?) {
        guard let entry = targetEntries.first, let currentPath else { return }
        promptName(title: "重命名", message: "“\(entry.name)”的新名称", initial: entry.name,
                   confirm: "重命名") { [weak self] name in
            guard let self, let name, name != entry.name, let session = self.session else { return }
            Task {
                do {
                    let target = RemotePath.join(RemotePath.parent(of: entry.path), name)
                    if await session.exists(target) {
                        self.showError("无法重命名", "“\(name)”已存在。")
                        return
                    }
                    try await session.rename(entry.path, to: target)
                    self.load(currentPath, selecting: name)
                } catch {
                    self.showError("无法重命名“\(entry.name)”", SFTPErrorMessage.describe(error))
                }
            }
        }
    }

    @objc private func deleteEntries(_ sender: Any?) {
        confirmDelete(targetEntries)
    }

    private func deleteSelection() {
        confirmDelete(selectedEntries)
    }

    private func confirmDelete(_ targets: [RemoteEntry]) {
        guard !targets.isEmpty, let window = view.window, let session else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = targets.count == 1
            ? "删除“\(targets[0].name)”？"
            : "删除选中的 \(targets.count) 项？"
        let hasFolder = targets.contains { $0.isDirectory && !$0.isSymlink }
        alert.informativeText = hasFolder
            ? "文件夹及其中的所有内容会从服务器上永久删除，无法撤销。"
            : "将从服务器上永久删除，无法撤销。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            Task {
                var failures: [String] = []
                for entry in targets {
                    do {
                        try await session.remove(entry)
                    } catch {
                        failures.append("\(entry.name)：\(SFTPErrorMessage.describe(error))")
                    }
                }
                if let currentPath = self.currentPath { self.load(currentPath) }
                if !failures.isEmpty {
                    self.showError("有 \(failures.count) 项未能删除", failures.prefix(5).joined(separator: "\n"))
                }
            }
        }
    }

    // MARK: - Commands

    private func addArchiveItems(to menu: NSMenu, for targets: [RemoteEntry]) {
        if targets.count == 1, !targets[0].isDirectory, let archive = ArchiveFormat.detect(targets[0].name) {
            let here = NSMenuItem(title: "解压到此处", action: #selector(extractHere(_:)), keyEquivalent: "")
            here.target = self
            menu.addItem(here)
            if !archive.format.isSingleFile {
                let folder = NSMenuItem(title: "解压到“\(archive.stem)/”", action: #selector(extractToFolder(_:)),
                                        keyEquivalent: "")
                folder.target = self
                menu.addItem(folder)
            }
        }
        let title = targets.count == 1 ? "压缩为“\(targets[0].name).zip”" : "压缩 \(targets.count) 项为 zip"
        let zip = NSMenuItem(title: title, action: #selector(compressToZip(_:)), keyEquivalent: "")
        zip.target = self
        menu.addItem(zip)
    }

    /// Runs a command with the list dimmed, then reloads the folder.
    private func run(_ command: String, failureTitle: String, selecting name: String? = nil) {
        guard let runCommand, let currentPath else { return }
        beginLoadingIndicator(showing: currentPath)
        Task {
            do {
                let result = try await runCommand(command)
                self.endLoadingIndicator()
                if !result.succeeded {
                    self.showError(failureTitle, result.failureMessage)
                }
            } catch {
                self.endLoadingIndicator()
                self.showError(failureTitle, SFTPErrorMessage.describe(error))
            }
            self.load(currentPath, selecting: name)
        }
    }

    @objc private func extractHere(_ sender: Any?) {
        extract(intoOwnFolder: false)
    }

    @objc private func extractToFolder(_ sender: Any?) {
        extract(intoOwnFolder: true)
    }

    private func extract(intoOwnFolder: Bool) {
        guard let entry = targetEntries.first, let archive = ArchiveFormat.detect(entry.name) else { return }
        let directory = RemotePath.parent(of: entry.path)
        let taken = Set(allEntries.map(\.name))
        // Never write into an existing folder or over an existing file.
        let fresh = SFTPPanelViewController.uniqueName(archive.stem, taken: taken)
        let destination = intoOwnFolder ? RemotePath.join(directory, fresh) : directory
        let command = RemoteCommands.extract(entry.path, format: archive.format, into: destination, output: fresh)
        run(command, failureTitle: "无法解压“\(entry.name)”",
            selecting: intoOwnFolder || archive.format.isSingleFile ? fresh : nil)
    }

    @objc private func compressToZip(_ sender: Any?) {
        let targets = targetEntries
        guard !targets.isEmpty, let currentPath else { return }
        let base = targets.count == 1 ? targets[0].name + ".zip" : "归档.zip"
        let name = SFTPPanelViewController.uniqueName(base, taken: Set(allEntries.map(\.name)))
        run(RemoteCommands.zip(targets.map(\.name), in: currentPath, into: name),
            failureTitle: "无法压缩", selecting: name)
    }

    @objc private func editPermissions(_ sender: Any?) {
        let targets = targetEntries
        guard !targets.isEmpty, let window = view.window else { return }
        let editor = PermissionsEditor(mode: (targets[0].permissions ?? 0o644) & 0o777,
                                       offerRecursive: targets.contains { $0.isDirectory && !$0.isSymlink })
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = targets.count == 1 ? "“\(targets[0].name)”的权限" : "\(targets.count) 项的权限"
        alert.informativeText = targets.count == 1 ? "" : "将统一设置为下面的权限。"
        alert.accessoryView = editor
        alert.addButton(withTitle: "应用")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let command = RemoteCommands.chmod(targets.map(\.path), mode: editor.mode,
                                               recursive: editor.isRecursive)
            self.run(command, failureTitle: "无法修改权限",
                     selecting: targets.count == 1 ? targets[0].name : nil)
        }
    }

    // MARK: - Editing

    private func addEditItems(to menu: NSMenu, for entry: RemoteEntry) {
        let edit = NSMenuItem(title: "编辑", action: #selector(editEntry(_:)), keyEquivalent: "")
        edit.target = self
        edit.representedObject = entry.path
        if let app = EditorApps.preferredApp(forFileNamed: entry.name) {
            edit.toolTip = "用 \(EditorApps.displayName(app)) 打开，保存后自动上传"
        }
        menu.addItem(edit)

        let editWith = NSMenuItem(title: "编辑方式", action: nil, keyEquivalent: "")
        let apps = NSMenu()
        for app in EditorApps.candidates(forFileNamed: entry.name).prefix(12) {
            let item = NSMenuItem(title: EditorApps.displayName(app), action: #selector(editWithApp(_:)), keyEquivalent: "")
            item.target = self
            item.image = EditorApps.icon(app)
            item.representedObject = [entry.path, app.path]
            apps.addItem(item)
        }
        apps.addItem(.separator())
        let other = NSMenuItem(title: "选择其他应用…", action: #selector(editWithOtherApp(_:)), keyEquivalent: "")
        other.target = self
        other.representedObject = entry.path
        apps.addItem(other)
        editWith.submenu = apps
        menu.addItem(editWith)

        if edits.session(for: entry.path) != nil {
            let stop = NSMenuItem(title: "停止编辑", action: #selector(stopEditing(_:)), keyEquivalent: "")
            stop.target = self
            stop.representedObject = entry.path
            menu.addItem(stop)
        }
        menu.addItem(.separator())
    }

    private func entry(at path: String) -> RemoteEntry? {
        allEntries.first { $0.path == path }
    }

    @objc private func editEntry(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String, let entry = entry(at: path) else { return }
        startEditing(entry, with: nil)
    }

    @objc private func editWithApp(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2,
              let entry = entry(at: pair[0]) else { return }
        let app = URL(fileURLWithPath: pair[1])
        EditorApps.remember(app, forFileNamed: entry.name)
        startEditing(entry, with: app)
    }

    @objc private func editWithOtherApp(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String, let entry = entry(at: path),
              let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.prompt = "选取"
        panel.message = "选择用来编辑“\(entry.name)”的应用"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let app = panel.url else { return }
            EditorApps.remember(app, forFileNamed: entry.name)
            self?.startEditing(entry, with: app)
        }
    }

    private func startEditing(_ entry: RemoteEntry, with app: URL?) {
        guard let session else { return }
        let started = edits.edit(entry, sftp: session, queue: queue) { local in
            EditorApps.open(local, with: app)
        }
        if started == nil {
            showError("无法编辑“\(entry.name)”", "无法在本机创建临时副本。")
        }
    }

    @objc private func stopEditing(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String, let edit = edits.session(for: path) else { return }
        guard edit.hasUnsyncedChanges, let window = view.window else {
            edits.stop(edit)
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "“\(edit.name)”还有没同步的修改"
        alert.informativeText = "停止编辑前可以先把最后一次保存上传到服务器。"
        alert.addButton(withTitle: "上传后停止")
        alert.addButton(withTitle: "不上传，直接停止")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                edit.syncIfChanged()
                self.stopWhenSynced(edit)
            case .alertSecondButtonReturn:
                self.edits.stop(edit, keepWorkingCopy: true)
            default:
                break
            }
        }
    }

    /// Stops once the final upload lands; keeps editing if it fails.
    private func stopWhenSynced(_ edit: RemoteEditSession) {
        Task {
            while edit.state == .syncing {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if !edit.hasUnsyncedChanges { edits.stop(edit) }
        }
    }

    private func askEditConflict(_ edit: RemoteEditSession) async -> RemoteEditSession.ConflictChoice {
        guard let window = view.window else { return .discard }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "“\(edit.name)”在服务器上已被修改"
        alert.informativeText = "你打开编辑之后，服务器上的这个文件被其他人或程序改过。覆盖会丢掉那些改动。"
        alert.addButton(withTitle: "覆盖")
        alert.addButton(withTitle: "另存一份")
        alert.addButton(withTitle: "放弃这次上传")
        let response = await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
        switch response {
        case .alertFirstButtonReturn: return .overwrite
        case .alertSecondButtonReturn: return .saveCopy
        default: return .discard
        }
    }

    // MARK: - Transfers

    private func download(_ targets: [RemoteEntry], to folder: URL?) {
        guard session != nil else { return }
        let destination = folder
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        for entry in targets {
            queue.enqueueDownload(entry, to: Self.uniqueLocalURL(in: destination, name: entry.name))
        }
    }

    private func transferFinished(_ item: TransferItem) {
        guard item.state == .completed else { return }
        switch item.direction {
        case .upload:
            if RemotePath.parent(of: item.remotePath) == currentPath { reloadSoon() }
        case .download:
            // Makes the Downloads stack in the Dock bounce, as Safari does.
            DistributedNotificationCenter.default().post(
                name: .init("com.apple.DownloadFileFinished"),
                object: item.localURL.resolvingSymlinksInPath().path
            )
        }
    }

    /// Uploads local files or folders into a remote folder, asking what to do
    /// about names that are already taken.
    private func upload(_ urls: [URL], into directory: String) {
        guard let session, !urls.isEmpty else { return }
        Task {
            let existing: Set<String>
            if directory == currentPath {
                existing = Set(allEntries.map(\.name))
            } else {
                existing = Set(((try? await session.list(directory)) ?? []).map(\.name))
            }
            var taken = existing
            var remembered: ConflictChoice?
            for url in urls {
                var name = url.lastPathComponent
                if taken.contains(name) {
                    let choice: ConflictChoice
                    if let remembered {
                        choice = remembered
                    } else {
                        let answer = await askConflict(name: name, isLast: url == urls.last)
                        choice = answer.choice
                        if answer.applyToAll { remembered = answer.choice }
                    }
                    switch choice {
                    case .skip: continue
                    case .replace: break
                    case .keepBoth: name = Self.uniqueName(name, taken: taken)
                    }
                }
                taken.insert(name)
                queue.enqueueUpload(url, to: RemotePath.join(directory, name))
            }
        }
    }

    private func askConflict(name: String, isLast: Bool) async -> (choice: ConflictChoice, applyToAll: Bool) {
        guard let window = view.window else { return (.skip, false) }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "“\(name)”已存在"
        alert.informativeText = "服务器上的这个文件夹中已有同名项目。替换会覆盖它的内容。"
        alert.addButton(withTitle: "替换")
        alert.addButton(withTitle: "保留两者")
        alert.addButton(withTitle: "跳过")
        if !isLast {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "对其余冲突执行相同操作"
        }
        let response = await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
        let applyToAll = alert.suppressionButton?.state == .on
        switch response {
        case .alertFirstButtonReturn: return (.replace, applyToAll)
        case .alertSecondButtonReturn: return (.keepBoth, applyToAll)
        default: return (.skip, applyToAll)
        }
    }

    /// "name.ext" → "name 2.ext", "name 3.ext", … as Finder names copies.
    static func uniqueName(_ name: String, taken: Set<String>) -> String {
        guard taken.contains(name) else { return name }
        let ext = (name as NSString).pathExtension
        let stem = ext.isEmpty || name.hasPrefix(".") && !name.dropFirst().contains(".")
            ? name
            : (name as NSString).deletingPathExtension
        let suffix = stem == name ? "" : "." + ext
        var index = 2
        while taken.contains("\(stem) \(index)\(suffix)") { index += 1 }
        return "\(stem) \(index)\(suffix)"
    }

    static func uniqueLocalURL(in folder: URL, name: String) -> URL {
        let existing = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
        return folder.appendingPathComponent(uniqueName(name, taken: existing))
    }

    // MARK: - Dialogs

    private func promptName(title: String, message: String, initial: String, confirm: String,
                            completion: @escaping (String?) -> Void) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "取消")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = initial
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else {
                completion(nil)
                return
            }
            let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            completion(value.isEmpty || value.contains("/") ? nil : value)
        }
        // Select the name without its extension, as Finder does.
        let stem = (initial as NSString).deletingPathExtension
        field.currentEditor()?.selectedRange = NSRange(location: 0, length: (stem.isEmpty ? initial : stem).utf16.count)
    }

    private func showError(_ title: String, _ message: String) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.beginSheetModal(for: window)
    }
}

// MARK: - Table

extension SFTPPanelViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        entries.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: SFTPEntryCell.identifier, owner: self) as? SFTPEntryCell)
            ?? SFTPEntryCell()
        let entry = entries[row]
        var size = ""
        if !entry.isDirectory, let bytes = entry.size {
            size = ByteCountFormatter.transferString(bytes)
        }
        cell.configure(name: entry.name, detail: size, icon: icon(for: entry),
                       isLink: entry.isSymlink, edit: edits.session(for: entry.path)?.state, theme: theme)
        var tip = entry.name
        if let modified = entry.modified { tip += "\n修改于 \(dateFormatter.string(from: modified))" }
        if let permissions = entry.permissions { tip += "\n权限 \(String(permissions & 0o7777, radix: 8))" }
        cell.toolTip = tip
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = SFTPRowView(fill: self.tableView.selectionFill, outline: self.tableView.contextOutline)
        view.showsContextOutline = row == self.tableView.contextRow
        return view
    }

    // Drag out to Finder: each row promises its file, downloaded on drop.
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard session != nil, row < entries.count else { return nil }
        let entry = entries[row]
        let type = entry.isDirectory ? UTType.folder : (UTType(filenameExtension: (entry.name as NSString).pathExtension) ?? .data)
        let provider = NSFilePromiseProvider(fileType: type.identifier, delegate: self)
        provider.userInfo = entry.path
        return provider
    }

    // Drop from Finder: upload into the folder under the pointer, or here.
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard session != nil, (info.draggingSource as? NSTableView) !== tableView,
              info.draggingPasteboard.canReadObject(forClasses: [NSURL.self],
                                                    options: [.urlReadingFileURLsOnly: true]) else {
            return []
        }
        if dropOperation == .on, row < entries.count, entries[row].isDirectory {
            return .copy
        }
        tableView.setDropRow(-1, dropOperation: .on)
        return .copy
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let currentPath,
              let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                             options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return false }
        let directory = row >= 0 && row < entries.count && entries[row].isDirectory
            ? entries[row].path
            : currentPath
        upload(urls, into: directory)
        return true
    }
}

extension SFTPPanelViewController: NSFilePromiseProviderDelegate {
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        RemotePath.name(of: filePromiseProvider.userInfo as? String ?? "file")
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        // Promises are fulfilled on the provider's operation queue, which
        // defaults to the main queue.
        MainActor.assumeIsolated {
            guard let path = filePromiseProvider.userInfo as? String,
                  let entry = allEntries.first(where: { $0.path == path }) else {
                completionHandler(CocoaError(.fileNoSuchFile))
                return
            }
            queue.enqueueDownload(entry, to: url, completion: completionHandler)
        }
    }
}

// MARK: - Context menu

extension SFTPPanelViewController: NSMenuDelegate {
    func menuDidClose(_ menu: NSMenu) {
        // Actions run after the menu closes; clear the outline once they have.
        DispatchQueue.main.async { [weak self] in
            self?.tableView.contextRow = -1
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard session != nil else { return }
        let targets = targetEntries
        func add(_ title: String, _ action: Selector, enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = enabled
            menu.addItem(item)
        }
        if !targets.isEmpty {
            if targets.count == 1, targets[0].isDirectory {
                add("打开", #selector(openFolder(_:)))
            }
            if targets.count == 1, !targets[0].isDirectory {
                addEditItems(to: menu, for: targets[0])
            }
            add(targets.count == 1 ? "下载到“下载”文件夹" : "下载 \(targets.count) 项到“下载”文件夹",
                #selector(downloadToDownloads(_:)))
            add("下载到…", #selector(downloadToFolder(_:)))
            menu.addItem(.separator())
            if targets.count == 1 {
                add("在终端中前往此处", #selector(cdInTerminal(_:)))
            }
            add(targets.count == 1 ? "复制路径" : "复制 \(targets.count) 个路径", #selector(copyPath(_:)))
            menu.addItem(.separator())
            if runCommand != nil {
                addArchiveItems(to: menu, for: targets)
                menu.addItem(.separator())
            }
            add("重命名…", #selector(renameEntry(_:)), enabled: targets.count == 1)
            if runCommand != nil {
                add("权限…", #selector(editPermissions(_:)))
            }
            add("删除…", #selector(deleteEntries(_:)))
            menu.addItem(.separator())
        } else {
            add("在终端中前往此处", #selector(cdInTerminal(_:)))
            add("复制路径", #selector(copyPath(_:)))
            menu.addItem(.separator())
        }
        add("上传文件…", #selector(uploadFiles(_:)))
        add("新建文件夹…", #selector(newFolder(_:)))
        add("刷新", #selector(refresh(_:)))
        let hidden = NSMenuItem(title: "显示隐藏文件", action: #selector(toggleHidden(_:)), keyEquivalent: "")
        hidden.target = self
        hidden.state = showHidden ? .on : .off
        menu.addItem(hidden)
    }
}

// MARK: - Views

final class SFTPTableView: NSTableView {
    var onOpen: (() -> Void)?
    var onDelete: (() -> Void)?
    var onParent: (() -> Void)?
    var selectionFill: NSColor = .selectedContentBackgroundColor
    var contextOutline: NSColor = .keyboardFocusIndicatorColor
    /// The row a context menu is open for. AppKit's own highlight for it is
    /// a hard white rectangle; this one matches the rounded selection.
    var contextRow = -1 {
        didSet {
            guard contextRow != oldValue else { return }
            for row in [oldValue, contextRow] where row >= 0 && row < numberOfRows {
                (rowView(atRow: row, makeIfNecessary: false) as? SFTPRowView)?.showsContextOutline = row == contextRow
            }
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        // Not calling super skips AppKit's rectangle around the clicked row.
        contextRow = row(at: convert(event.locationInWindow, from: nil))
        return menu
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case 36, 76: // Return, Enter
            onOpen?()
        case 51, 117: // Delete, Forward Delete
            onDelete?()
        case 125 where flags.contains(.command): // ⌘↓ opens, as in Finder
            onOpen?()
        case 126 where flags.contains(.command): // ⌘↑
            onParent?()
        default:
            super.keyDown(with: event)
        }
    }
}

private final class SFTPRowView: NSTableRowView {
    private let fill: NSColor
    private let outline: NSColor
    var showsContextOutline = false {
        didSet { needsDisplay = true }
    }

    init(fill: NSColor, outline: NSColor) {
        self.fill = fill
        self.outline = outline
        super.init(frame: .zero)
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard showsContextOutline else { return }
        outline.setStroke()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 6.75, dy: 0.75), xRadius: 6, yRadius: 6)
        path.lineWidth = 1.5
        path.stroke()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func drawSelection(in dirtyRect: NSRect) {
        fill.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 0), xRadius: 6, yRadius: 6).fill()
    }

    override var isEmphasized: Bool {
        get { false }
        set {}
    }
}

private final class SFTPEntryCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("SFTPEntryCell")

    private let icon = NSImageView()
    private let linkBadge = NSImageView()
    private let nameLabel = UIFactory.label("", size: 12.5, color: .labelColor)
    private let detailLabel = UIFactory.label("", size: 11, color: .secondaryLabelColor, alignment: .right)
    /// "编辑中" pill shown while the file is open in a local editor.
    private let editTag = RoundedCardView(fill: .clear, border: .clear, radius: 8)
    private let editIcon = NSImageView()
    private let editLabel = UIFactory.label("", size: 10.5, weight: .medium, color: .labelColor)

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown
        linkBadge.translatesAutoresizingMaskIntoConstraints = false
        linkBadge.image = NSImage(systemSymbolName: "arrow.turn.up.right", accessibilityDescription: "链接")
        linkBadge.symbolConfiguration = .init(pointSize: 8, weight: .bold)
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        detailLabel.setContentHuggingPriority(.required, for: .horizontal)
        editTag.layer?.borderWidth = 0
        editIcon.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)
        editIcon.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        editIcon.translatesAutoresizingMaskIntoConstraints = false
        editTag.addSubview(editIcon)
        editTag.addSubview(editLabel)
        editTag.setContentCompressionResistancePriority(.required, for: .horizontal)
        // A stack drops the tag's space entirely while it is hidden.
        let title = NSStackView(views: [nameLabel, editTag])
        title.orientation = .horizontal
        title.spacing = 6
        title.translatesAutoresizingMaskIntoConstraints = false
        [icon, linkBadge, title, detailLabel].forEach(addSubview)
        textField = nameLabel
        imageView = icon
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            linkBadge.trailingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 2),
            linkBadge.bottomAnchor.constraint(equalTo: icon.bottomAnchor, constant: 1),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            editTag.heightAnchor.constraint(equalToConstant: 17),
            editIcon.leadingAnchor.constraint(equalTo: editTag.leadingAnchor, constant: 6),
            editIcon.centerYAnchor.constraint(equalTo: editTag.centerYAnchor),
            editLabel.leadingAnchor.constraint(equalTo: editIcon.trailingAnchor, constant: 3),
            editLabel.trailingAnchor.constraint(equalTo: editTag.trailingAnchor, constant: -7),
            editLabel.centerYAnchor.constraint(equalTo: editTag.centerYAnchor),
            detailLabel.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 8),
            detailLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            detailLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(name: String, detail: String, icon image: NSImage, isLink: Bool,
                   edit: RemoteEditSession.State?, theme: TerminalTheme) {
        icon.image = image
        editTag.isHidden = edit == nil
        if let edit {
            let tint: NSColor
            switch edit {
            case .downloading:
                editLabel.stringValue = "打开中"
                tint = theme.accent
            case .editing:
                editLabel.stringValue = "编辑中"
                tint = theme.accent
            case .syncing:
                editLabel.stringValue = "同步中"
                tint = theme.accent
            case .failed(let message):
                editLabel.stringValue = "未同步"
                tint = theme.palette[1]
                editTag.toolTip = message
            }
            if case .failed = edit {} else { editTag.toolTip = "保存后会自动上传到服务器" }
            editTag.fillColor = tint.withAlphaComponent(theme.isDark ? 0.2 : 0.12)
            editLabel.textColor = tint
            editIcon.contentTintColor = tint
        }
        nameLabel.stringValue = name
        nameLabel.textColor = theme.tabText
        detailLabel.stringValue = detail
        detailLabel.textColor = theme.subtle
        linkBadge.isHidden = !isLink
        linkBadge.contentTintColor = theme.tabText
    }
}
