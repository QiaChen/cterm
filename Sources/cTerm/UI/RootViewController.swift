import AppKit

/// A lightweight split container. NSSplitViewController drives the whole window's
/// height from its children's fitting size in a translucent, full-size-content
/// window, which makes the window collapse. This container keeps the chrome on
/// explicit frames and lets the window own its size.
final class RootViewController: NSViewController {
    let sidebarVC: SidebarViewController
    let sessionHost: SessionHostViewController

    private let sidebarWidthKey = "cterm.sidebarWidth"
    private let sidebarCollapsedKey = "cterm.sidebarCollapsed"
    private(set) var isSidebarCollapsed: Bool
    private var sidebarWidth: CGFloat
    private var theme: TerminalTheme
    private var isAnimating = false
    private var animationTimer: Timer?
    /// Clips the rail so only the part the sliding sidebar has left is shown;
    /// the sidebar is translucent, so anything under it would show through.
    private let railClip = NSView()
    /// Top right of the sidebar when it is open, at the top of the icon rail
    /// (under the window buttons) when it is collapsed.
    private let sidebarButton = ChromeButton(shape: .circle, symbol: "sidebar.left", target: nil, action: nil)

    private static let buttonSize: CGFloat = 26
    /// The button stays inside the sidebar in both states, so the tabs keep
    /// their usual margin.
    private static let tabsInset: CGFloat = 16

    private var rail: SidebarRailView { sidebarVC.railView }

    init(sidebar: SidebarViewController, sessionHost: SessionHostViewController, theme: TerminalTheme) {
        self.sidebarVC = sidebar
        self.sessionHost = sessionHost
        self.theme = theme
        let saved = UserDefaults.standard.double(forKey: sidebarWidthKey)
        self.sidebarWidth = saved > 0 ? saved : 250
        self.isSidebarCollapsed = UserDefaults.standard.bool(forKey: sidebarCollapsedKey)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1180, height: 760))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.clear.cgColor
        view = root

        addChild(sidebarVC)
        addChild(sessionHost)
        sidebarVC.view.translatesAutoresizingMaskIntoConstraints = true
        sessionHost.view.translatesAutoresizingMaskIntoConstraints = true
        // During the slide nothing may sit under the translucent sidebar (it
        // would show through) and nothing may be left uncovered (the window is
        // transparent, so the desktop would show). See applyFrames(collapse:).
        railClip.wantsLayer = true
        railClip.layer?.masksToBounds = true
        railClip.translatesAutoresizingMaskIntoConstraints = true
        rail.translatesAutoresizingMaskIntoConstraints = true
        railClip.addSubview(rail)
        root.addSubview(railClip)
        root.addSubview(sessionHost.view)
        root.addSubview(sidebarVC.view)

        sidebarButton.target = self
        sidebarButton.action = #selector(sidebarButtonPressed)
        sidebarButton.translatesAutoresizingMaskIntoConstraints = true
        root.addSubview(sidebarButton) // above both panes
        applyButtonTheme()
        layoutChrome()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        layoutChrome()
    }

    func apply(theme: TerminalTheme) {
        self.theme = theme
        sidebarVC.apply(theme: theme)
        sessionHost.apply(theme: theme)
        applyButtonTheme()
        view.needsLayout = true
    }

    private func applyButtonTheme() {
        sidebarButton.fillColor = .clear
        sidebarButton.hoverFillColor = theme.pillHoverFill
        sidebarButton.borderColor = .clear
        sidebarButton.titleColor = theme.subtle
        sidebarButton.toolTip = isSidebarCollapsed ? "显示侧边栏（⌃⌘S）" : "隐藏侧边栏（⌃⌘S）"
        sidebarButton.setAccessibilityLabel(isSidebarCollapsed ? "显示侧边栏" : "隐藏侧边栏")
        sidebarButton.needsDisplay = true
    }

    @objc private func sidebarButtonPressed() {
        toggleSidebar()
    }

    func toggleSidebar() {
        setSidebarVisible(isSidebarCollapsed, animated: true)
    }

    func setSidebarVisible(_ visible: Bool, animated: Bool = false) {
        guard visible == isSidebarCollapsed, !isAnimating else { return }
        isSidebarCollapsed = !visible
        UserDefaults.standard.set(isSidebarCollapsed, forKey: sidebarCollapsedKey)
        applyButtonTheme()
        guard animated, view.window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            layoutChrome()
            return
        }
        animateSidebar(collapsing: !visible)
    }

    /// Collapsing is quick; expanding brings content in, so it is a bit slower.
    private static let collapseDuration: TimeInterval = 0.26
    private static let expandDuration: TimeInterval = 0.34

    private func animateSidebar(collapsing: Bool) {
        // Frames are set directly on every display frame instead of through a
        // Core Animation property animation. The sidebar's frosted glass blurs
        // what is behind the window, and the window server moves that blur
        // only with real frame changes: under a layer animation the sliding
        // sidebar lost its blur and looked like a different, flat layer until
        // the slide ended. The sessions' edge also follows the sidebar's edge
        // (stopping at the rail), which no single property animation can do.
        isAnimating = true
        sidebarVC.view.isHidden = false
        railClip.isHidden = false
        let duration = collapsing ? Self.collapseDuration : Self.expandDuration
        let started = CACurrentMediaTime()
        applyFrames(collapse: collapsing ? 0 : 1)
        animationTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                let t = min(1, (CACurrentMediaTime() - started) / duration)
                let eased = Self.easeInOut(t)
                self.applyFrames(collapse: collapsing ? eased : 1 - eased)
                if t >= 1 {
                    timer.invalidate()
                    self.animationTimer = nil
                    self.isAnimating = false
                    self.layoutChrome()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    private static func easeInOut(_ t: Double) -> CGFloat {
        CGFloat(t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2)
    }

    /// Frames part way through the slide; `collapse` runs from 0 (open) to 1.
    /// The sidebar keeps its full width and slides left. The sessions start at
    /// its right edge, or at the rail once the edge passes it, so the two
    /// never overlap and never leave a gap; they keep the collapsed width
    /// throughout, moving instead of resizing, so the terminal is laid out
    /// (and the remote end told the size) once rather than every frame. The
    /// rail shows only where the sidebar has already gone.
    private func applyFrames(collapse: CGFloat) {
        let bounds = view.bounds
        let width = expandedWidth(for: bounds)
        let railWidth = SidebarRailView.width
        let edge = width * (1 - collapse)
        sidebarVC.view.frame = NSRect(x: edge - width, y: 0, width: width, height: bounds.height)
        let hostX = max(railWidth, edge)
        sessionHost.view.frame = NSRect(x: hostX, y: 0, width: bounds.width - railWidth, height: bounds.height)
        let clipX = min(edge, railWidth)
        railClip.frame = NSRect(x: clipX, y: 0, width: railWidth - clipX, height: bounds.height)
        rail.frame = NSRect(x: -clipX, y: 0, width: railWidth, height: bounds.height)
        let open = buttonFrame(collapsed: false, sidebarWidth: width, in: bounds)
        let closed = buttonFrame(collapsed: true, sidebarWidth: width, in: bounds)
        sidebarButton.frame = NSRect(
            x: open.minX + (closed.minX - open.minX) * collapse,
            y: open.minY + (closed.minY - open.minY) * collapse,
            width: open.width,
            height: open.height
        )
    }

    #if DEBUG
    /// Freezes the collapse animation at `progress` (0…1) for a snapshot.
    func layoutForSnapshot(collapseProgress progress: CGFloat) {
        isAnimating = true // hold the frames, as during a real slide
        sidebarVC.view.isHidden = false
        railClip.isHidden = false
        applyFrames(collapse: progress)
    }

    func endSnapshotFreeze() {
        isAnimating = false
        layoutChrome()
    }
    #endif

    private func buttonFrame(collapsed: Bool, sidebarWidth: CGFloat, in bounds: NSRect) -> NSRect {
        let size = Self.buttonSize
        if collapsed {
            // Centred in the rail, just below the window buttons.
            return NSRect(x: (SidebarRailView.width - size) / 2, y: bounds.height - 44 - size / 2,
                          width: size, height: size)
        }
        // In line with the window buttons, aligned with the header's + button.
        return NSRect(x: sidebarWidth - 14 - size, y: bounds.height - 14 - size / 2, width: size, height: size)
    }

    private func expandedWidth(for bounds: NSRect) -> CGFloat {
        let available = max(244, bounds.width - 520)
        return min(max(244, sidebarWidth), min(360, available))
    }

    private func layoutChrome() {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0, !isAnimating else { return }
        let expanded = expandedWidth(for: bounds)
        let width = isSidebarCollapsed ? SidebarRailView.width : expanded
        sidebarVC.view.isHidden = isSidebarCollapsed
        sidebarVC.view.frame = NSRect(x: 0, y: 0, width: expanded, height: bounds.height)
        railClip.isHidden = !isSidebarCollapsed
        railClip.frame = NSRect(x: 0, y: 0, width: SidebarRailView.width, height: bounds.height)
        rail.frame = railClip.bounds
        sessionHost.view.frame = NSRect(x: width, y: 0, width: max(0, bounds.width - width), height: bounds.height)
        sessionHost.tabsLeadingInset = Self.tabsInset
        sidebarButton.frame = buttonFrame(collapsed: isSidebarCollapsed, sidebarWidth: expanded, in: bounds)
        if !isSidebarCollapsed {
            UserDefaults.standard.set(width, forKey: sidebarWidthKey)
        }
    }
}
