import AppKit
import Combine
import SwiftUI

enum OpenReason { case hover, hotkey, programmatic }

/// A short-lived banner that grows out of the closed island (new song, charging, activity).
struct Peek: Equatable {
    enum Kind { case music, charging, activity, info }
    let id = UUID()
    var kind: Kind
    var symbol: String? = nil
    var title: String
    var subtitle: String? = nil
    var tint: Color = .white
    var progress: Double? = nil
}

enum CompactKind: Equatable { case none, music, activity }

/// Owns the two panels (the menu-bar cat and the island), the 60 fps tick,
/// hover/hotkey logic and every service.
final class IslandController: ObservableObject {
    @Published private(set) var geometry = NotchGeometry.detect()
    @Published private(set) var isOpen = false
    @Published private(set) var peek: Peek?
    @Published private(set) var focusToken = 0
    var pendingFocus = false
    /// Cursor position in island-panel coordinates (read by the peeking cat's eyes).
    private(set) var islandMouse: CGPoint = .zero

    let settings = AppSettings.shared
    let cat = CatEngine()
    let media = NowPlayingService()
    let apps = AppShelf()
    let claude = ClaudeSession()
    let battery = BatteryMonitor()
    let activities = ActivityCenter()
    let terminals = TerminalTabs()
    let transcript = TranscriptStore()

    private(set) var panel: NotchPanel!       // the island
    private(set) var catPanel: NotchPanel!    // the cat strip under the menu bar
    private var backdrop: BackdropPanel!
    private(set) var surfacePanel: SurfacePanel!   // Liquid Glass, behind the island       // dims/blurs the screen while the island is open
    private var timer: Timer?
    private var lastTick = CACurrentMediaTime()
    private var openReason: OpenReason = .hover
    private var hoverIslandTime = 0.0, hoverCatTime = 0.0, outsideTime = 0.0
    /// You clicked or typed in the island since it opened — then it stays open when the cursor
    /// leaves (a plain hover-open closes as soon as you move away).
    private var engaged = false
    private var mouseMonitor: Any?
    private var previousApp: NSRunningApplication?
    private var activatedApp = false
    private var bag = Set<AnyCancellable>()
    private var peekHide: DispatchWorkItem?
    private var keyMonitor: Any?

    let spring = Animation.spring(response: 0.42, dampingFraction: 0.8)
    var dock: IslandDock { settings.dock }
    /// Notch centre in the top panels' coordinates (both are 680 wide, centred on the notch).
    /// Notch centre in the cat strip's coordinates (680 wide, centred on the notch).
    var centerX: CGFloat { Metrics.topCatPanelSize.width / 2 }
    /// Notch centre in the island panel's coordinates (notch dock).
    var islandCenterX: CGFloat { Metrics.panelSize(.notch).width / 2 }
    var hasTerminals: Bool { !terminals.tabs.isEmpty }
    /// A pinned tab is selected: the island grows to show its conversation.
    var showsTranscript: Bool { terminals.selected != nil }
    var panelSize: CGSize { Metrics.panelSize(dock) }
    var expandedWidth: CGFloat { Metrics.expandedWidth(dock, rail: hasTerminals) }
    var headerHeight: CGFloat { dock == .notch ? geometry.notchHeight : Metrics.edgeHeaderHeight }
    var expandedHeight: CGFloat {
        Metrics.expandedHeight(dock, header: headerHeight, answer: claude.hasAnswer, terminals: hasTerminals,
                               terminalCount: terminals.tabs.count, transcript: showsTranscript)
    }

    // MARK: - Lifecycle

    func start() {
        backdrop = BackdropPanel(frame: geometry.screenFrame)
        backdrop.setStrength(settings.backdropStrength)

        // Cat strip: below the island so the cat walks *behind* it.
        let cp = NotchPanel(frame: catPanelFrame())
        cp.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        let catHost = FirstMouseHostingView(rootView: CatRootView(engine: cat, settings: settings))
        catHost.sizingOptions = []
        catHost.frame = NSRect(origin: .zero, size: catPanelFrame().size)
        catHost.autoresizingMask = [.width, .height]
        cp.contentView = catHost
        cp.setFrame(catPanelFrame(), display: false)
        cp.orderFrontRegardless()
        catPanel = cp

        // Liquid Glass surface, in a window that never becomes key (see SurfacePanel).
        let sp = SurfacePanel(frame: panelFrame())
        let glassHost = NSHostingView(rootView: IslandGlassRootView(c: self, settings: settings,
                                                                     claude: claude, terminals: terminals))
        glassHost.sizingOptions = []
        glassHost.frame = NSRect(origin: .zero, size: panelSize)
        glassHost.autoresizingMask = [.width, .height]
        sp.contentView = glassHost
        sp.setFrame(panelFrame(), display: false)
        sp.orderFrontRegardless()
        surfacePanel = sp

        let p = NotchPanel(frame: panelFrame())
        let root = IslandRootView(c: self, media: media, activities: activities, claude: claude,
                                  settings: settings, battery: battery, apps: apps, terminals: terminals)
        let host = FirstMouseHostingView(rootView: root)
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: panelSize)
        host.autoresizingMask = [.width, .height]
        p.contentView = host
        p.setFrame(panelFrame(), display: false)
        p.orderFrontRegardless()
        panel = p
        sp.order(.below, relativeTo: p.windowNumber)
        // Keep the glass window glued to the island window.
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            NotificationCenter.default.addObserver(forName: name, object: p, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.surfacePanel.setFrame(self.panel.frame, display: true)
            }
        }

        layoutCat()
        wire()

        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func catPanelFrame(dock: IslandDock? = nil) -> NSRect {
        let g = geometry
        switch dock ?? self.dock {
        case .notch:
            let s = Metrics.topCatPanelSize
            return NSRect(x: g.notchCenterX - s.width / 2, y: g.screenFrame.maxY - s.height,
                          width: s.width, height: s.height)
        case .left:
            // The whole left strip of the screen: floor at the bottom, wall on the left.
            let sf = g.screenFrame
            return NSRect(x: sf.minX, y: sf.minY, width: Metrics.leftCatWorldWidth, height: sf.height)
        }
    }

    private func panelFrame(dock: IslandDock? = nil, edgePosition: Double? = nil) -> NSRect {
        let g = geometry
        let s = Metrics.panelSize(dock ?? self.dock)
        switch dock ?? self.dock {
        case .notch:
            return NSRect(x: g.notchCenterX - s.width / 2, y: g.screenFrame.maxY - s.height,
                          width: s.width, height: s.height)
        case .left:
            let vf = g.visibleFrame, sf = g.screenFrame
            let centerY = vf.maxY - CGFloat(edgePosition ?? settings.edgePosition) * vf.height
            let y = min(max(centerY - s.height / 2, sf.minY), sf.maxY - s.height)
            return NSRect(x: sf.minX, y: y, width: s.width, height: s.height)
        }
    }

    private func layoutCat(range: Double? = nil, size: Double? = nil) {
        let g = geometry
        cat.species = settings.pet
        let catH = min(max(g.notchHeight * CGFloat(size ?? settings.catSize) * settings.pet.sizeFactor, 16), 70)
        switch dock {
        case .notch:
            // Feet rest on the bottom edge of the menu bar; a big cat stands a little below it
            // so its ears never get clipped by the top of the screen.
            let ground = max(g.notchHeight - 1, catH * 0.97)
            cat.configureMenuBar(centerX: centerX, notchHalf: g.notchWidth / 2,
                                 range: CGFloat(range ?? settings.walkRange), groundY: ground, catHeight: catH)
        case .left:
            // In the cat strip's coordinates (top of screen = 0): the handle sits at the island's
            // vertical centre, the floor is the bottom of the screen.
            let island = panelFrame()
            let handleY = g.screenFrame.maxY - island.midY
            cat.configureLeftEdge(width: Metrics.leftCatWorldWidth,
                                  floorY: g.screenFrame.height - 1,
                                  handle: CGPoint(x: 3, y: handleY),
                                  catHeight: catH)
        }
    }

    private func wire() {
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.screenChanged() }
            .store(in: &bag)
        NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification, object: panel)
            .sink { [weak self] _ in
                guard let self, self.isOpen else { return }
                self.close()
            }
            .store(in: &bag)
        settings.$walkRange.dropFirst()
            .sink { [weak self] v in self?.layoutCat(range: v) }
            .store(in: &bag)
        settings.$catSize.dropFirst()
            .sink { [weak self] v in self?.layoutCat(size: v) }
            .store(in: &bag)
        settings.$showCat
            .sink { [weak self] v in self?.cat.enabled = v }
            .store(in: &bag)
        settings.$pet.dropFirst().removeDuplicates()
            .sink { [weak self] p in
                guard let self else { return }
                self.cat.species = p
                DispatchQueue.main.async { self.layoutCat() }
            }
            .store(in: &bag)
        settings.$dock.dropFirst().removeDuplicates()
            .sink { [weak self] _ in
                guard let self else { return }
                self.close()
                // @Published fires *before* the new value is stored. Resizing the windows right
                // here makes SwiftUI redraw synchronously with the OLD dock (leaving a stray
                // left-edge handle in the top window), so move everything after the change lands.
                DispatchQueue.main.async {
                    self.panel.setFrame(self.panelFrame(), display: true)
                    self.catPanel.setFrame(self.catPanelFrame(), display: true)
                    self.layoutCat()
                    self.objectWillChange.send()
                }
            }
            .store(in: &bag)
        settings.$edgePosition.dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                DispatchQueue.main.async {
                    self.panel.setFrame(self.panelFrame(), display: true)
                    self.layoutCat()
                }
            }
            .store(in: &bag)
        media.$track
            .map { $0?.isPlaying == true }
            .removeDuplicates()
            .sink { [weak self] playing in self?.cat.musicPlaying = playing }
            .store(in: &bag)
        media.onTrackChange = { [weak self] t in
            guard let self else { return }
            self.cat.surprise()
            self.showPeek(Peek(kind: .music, title: t.title, subtitle: t.artist, tint: self.media.tint))
        }
        battery.$isPluggedIn.removeDuplicates().dropFirst()
            .sink { [weak self] plugged in
                guard let self, plugged else { return }
                DispatchQueue.main.async {
                    self.showPeek(Peek(kind: .charging, symbol: "bolt.fill", title: "Charging · \(self.battery.level)%",
                                       subtitle: self.battery.chargeDetail, tint: Color(hex: 0x4CD97B),
                                       progress: Double(self.battery.level) / 100))
                }
            }
            .store(in: &bag)
        activities.onEvent = { [weak self] a in
            self?.showPeek(Peek(kind: .activity, symbol: a.symbol, title: a.title, subtitle: a.subtitle,
                                tint: a.tint, progress: a.progress))
        }
        terminals.onStateChange = { [weak self] tab, state in self?.claudeStateChanged(tab, state) }
        transcript.screenProvider = { [weak self] tab, done in
            guard let self else { return done(nil) }
            self.terminals.screenText(of: tab, completion: done)
        }
        // Load the selected tab's conversation only while the island is open.
        Publishers.CombineLatest(terminals.$selectedID, $isOpen)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in self?.syncTranscript() }
            .store(in: &bag)
        settings.$theme.dropFirst()
            .sink { [weak self] t in self?.activities.retint(t.accent) }
            .store(in: &bag)
        settings.$backdropStrength.dropFirst()
            .sink { [weak self] v in self?.backdrop.setStrength(v) }
            .store(in: &bag)
        settings.$dimBehindIsland.dropFirst()
            .sink { [weak self] on in
                guard let self, self.isOpen else { return }
                self.backdrop.show(on, below: self.catPanel)
            }
            .store(in: &bag)
        // Re-layout the island when tabs are pinned/unpinned (the rail changes its size).
        terminals.$tabs.map(\.count).removeDuplicates().dropFirst()
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &bag)
        // Any click inside the island means you're using it: keep it open when the cursor leaves.
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] e in
            if let self, self.isOpen, e.window === self.panel { self.engaged = true }
            return e
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            self?.handleKey(e) ?? e
        }
    }

    private func syncTranscript() {
        if isOpen, let tab = terminals.selected { transcript.show(tab) } else { transcript.hide() }
    }

    private func screenChanged() {
        geometry = NotchGeometry.detect()
        backdrop.setFrame(geometry.screenFrame, display: true)
        panel.setFrame(panelFrame(), display: true)
        catPanel.setFrame(catPanelFrame(), display: true)
        layoutCat()
    }

    // MARK: - Tick

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = min(now - lastTick, 0.05)
        lastTick = now
        let m = NSEvent.mouseLocation
        let islandLocal = local(m, in: panel.frame)
        let catLocal = local(m, in: catPanel.frame)
        islandMouse = islandLocal
        if isOpen { trackOpen(islandLocal, dt) } else { trackClosed(islandLocal, catLocal, dt) }
        if settings.showCat {
            if dock == .notch {
                // The cat shouldn't loiter where the island hides it.
                let half = closedSize().width / 2
                cat.hiddenBand = (centerX - half)...(centerX + half)
            }
            cat.update(dt: dt, mouse: catLocal)
        }
    }

    private func local(_ m: NSPoint, in f: NSRect) -> CGPoint {
        CGPoint(x: m.x - f.minX, y: f.maxY - m.y)
    }

    /// Where the closed island is, in island-panel coordinates.
    private func closedRect() -> CGRect {
        let s = closedSize()
        switch dock {
        case .notch:
            return CGRect(x: islandCenterX - s.width / 2, y: 0, width: s.width, height: s.height + 2)
        case .left:
            // Generous hover zone: slam the cursor into the screen edge near the handle.
            let h = panelSize.height
            return CGRect(x: 0, y: h / 2 - s.height / 2 - 14, width: s.width + 8, height: s.height + 28)
        }
    }

    private func openRect() -> CGRect {
        let H = expandedHeight
        switch dock {
        case .notch:
            return CGRect(x: islandCenterX - expandedWidth / 2 - 14, y: 0, width: expandedWidth + 28, height: H + 14)
        case .left:
            let h = panelSize.height
            return CGRect(x: 0, y: h / 2 - H / 2 - 24, width: expandedWidth + 16, height: H + 48)
        }
    }

    private func trackClosed(_ mouse: CGPoint, _ catMouse: CGPoint, _ dt: Double) {
        if closedRect().contains(mouse) {
            hoverIslandTime += dt
            if hoverIslandTime > 0.12 { open(.hover) }
        } else {
            hoverIslandTime = 0
        }
        if settings.showCat, cat.isHoverable, cat.hitRect.insetBy(dx: -3, dy: -3).contains(catMouse) {
            hoverCatTime += dt
            if hoverCatTime > 0.08 {
                hoverCatTime = 0
                // Opening from the cat counts as an explicit open: it shouldn't vanish when
                // the cursor isn't over a left-docked island yet.
                let reason: OpenReason = dock == .notch ? .hover : .programmatic
                cat.hopIntoNotch { [weak self] in self?.open(reason, focus: false) }
            }
        } else {
            hoverCatTime = 0
        }
    }

    private func trackOpen(_ mouse: CGPoint, _ dt: Double) {
        if openRect().contains(mouse) {
            outsideTime = 0
        } else if openReason == .hover && !engaged {
            outsideTime += dt
            if outsideTime > 0.35 { close() }
        }
    }

    // MARK: - Shape

    var compactKind: CompactKind {
        if activities.primary != nil { return .activity }
        if media.track?.isPlaying == true { return .music }
        return .none
    }

    /// True when the closed island has nothing to show.
    var isIdle: Bool { compactKind == .none && peek == nil }

    func closedSize() -> CGSize {
        let g = geometry
        switch dock {
        case .notch:
            var w = g.notchWidth
            var h = g.notchHeight
            if g.hasNotch && isIdle {
                // Tuck fully behind the hardware notch so nothing peeks out.
                return CGSize(width: w - 6, height: h - 2)
            }
            if compactKind != .none { w += 2 * Metrics.wing(g) }
            if peek != nil { w = max(w, 360); h += 42 }
            return CGSize(width: w, height: h)
        case .left:
            if peek != nil { return CGSize(width: 300, height: 60) }
            if compactKind != .none { return CGSize(width: 40, height: 92) }
            return CGSize(width: 7, height: 64)
        }
    }

    // MARK: - Open / close

    func open(_ reason: OpenReason, focus: Bool = true) {
        if isOpen {
            if reason != .hover && focus { focusClaude() }
            return
        }
        openReason = reason
        outsideTime = 0
        hoverIslandTime = 0
        peekHide?.cancel()
        panel.ignoresMouseEvents = false
        cat.slipInside()
        terminals.islandOpen = true
        terminals.poll()
        withAnimation(spring) {
            peek = nil
            isOpen = true
        }
        if settings.dimBehindIsland {
            backdrop.setStrength(settings.backdropStrength)
            backdrop.show(true, below: catPanel)
        }
        engaged = false
        if reason == .hover {
            // Take keyboard focus while you're over the island so ⌘↑/⌘↓, Esc and ⌘1–9 work
            // straight away. It's a non-activating panel: your app stays the active app, and
            // focus goes back to it when the island closes.
            panel.makeKey()
        }
        if reason != .hover {
            cat.greet()
            if focus { focusClaude() }
        }
    }

    func close() {
        guard isOpen else { return }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) { isOpen = false }
        backdrop.show(false, below: nil)
        terminals.islandOpen = false
        panel.ignoresMouseEvents = true
        outsideTime = 0
        if panel.isKeyWindow {
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
        if activatedApp {
            activatedApp = false
            previousApp?.activate()
            previousApp = nil
        }
        if cat.isInside {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.cat.popOut() }
        }
    }

    func toggleFromHotkey() { isOpen ? close() : open(.hotkey) }

    private func focusClaude() {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp = front
            activatedApp = true
        }
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        pendingFocus = true
        focusToken += 1
    }

    private func handleKey(_ e: NSEvent) -> NSEvent? {
        guard isOpen else { return e }
        if e.keyCode == 53 { close(); return nil }   // Esc
        let isArrowSwitch = e.modifierFlags.contains(.command) && (e.keyCode == 125 || e.keyCode == 126)
        if !isArrowSwitch { engaged = true }
        // ⌘↓ / ⌘↑ switch between pinned terminal tabs.
        let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
        if mods == .command, e.keyCode == 125 || e.keyCode == 126, !terminals.tabs.isEmpty {
            withAnimation(.easeOut(duration: 0.15)) { terminals.selectAdjacent(e.keyCode == 125 ? 1 : -1) }
            return nil
        }
        if e.modifierFlags.contains(.command), let ch = e.charactersIgnoringModifiers,
           let n = Int(ch), (1...9).contains(n) {
            if apps.launch(at: n - 1) { close() }
            return nil
        }
        return e
    }

    // MARK: - Actions

    func launch(_ app: PinnedApp) {
        apps.launch(app)
        close()
    }

    func addApps() {
        close()
        apps.chooseApp()
    }

    func openSettings() {
        close()
        SettingsWindowController.shared.show(controller: self)
    }

    func showPeek(_ p: Peek, duration: TimeInterval = 3.2) {
        guard !isOpen else { return }
        peekHide?.cancel()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.78)) { peek = p }
        let work = DispatchWorkItem { [weak self] in
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { self?.peek = nil }
        }
        peekHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    // MARK: - URL scheme (notchi://)

    func handle(url: URL) {
        guard url.scheme == "notchi" else { return }
        var q: [String: String] = [:]
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.forEach { q[$0.name] = $0.value ?? "" }
        switch url.host ?? "" {
        case "push", "activity": activities.push(q)
        case "end": if let id = q["id"] { activities.end(id: id) }
        case "open": open(.programmatic)
        case "ask":
            open(.programmatic)
            if let question = q["q"], !question.isEmpty { claude.ask(question) }
        case "tab":
            // notchi://tab?action=add|remove&tty=/dev/ttys003&iterm=<uuid>&app=iTerm2&name=…
            let tty = q["tty"] ?? "", iterm = q["iterm"].flatMap { $0.isEmpty ? nil : $0 }
            if q["action"] == "remove" {
                terminals.remove(tty: tty, itermID: iterm)
            } else if let tab = terminals.add(tty: tty, itermID: iterm, app: q["app"] ?? "iTerm2", name: q["name"]) {
                showPeek(Peek(kind: .info, symbol: "terminal.fill", title: "Pinned \(tab.displayName)",
                              subtitle: "\(terminals.tabs.count) of \(TerminalTabs.maxTabs) terminal tabs",
                              tint: .islandAccent))
            } else {
                showPeek(Peek(kind: .info, symbol: "exclamationmark.triangle.fill", title: "All \(TerminalTabs.maxTabs) tab slots are full",
                              subtitle: "Remove one from the island first", tint: Color(hex: 0xFFB340)))
            }
        case "dock":
            // notchi://dock?to=left|top
            settings.dock = q["to"] == "left" ? .left : .notch
        case "claude":
            // From Claude Code hooks: notchi://claude?event=working|attention|done|end&tty=…&iterm=…&msg=…
            terminals.claudeEvent(q["event"] ?? "", tty: q["tty"], itermID: q["iterm"], message: q["msg"])
        default: break
        }
    }

    // MARK: - Claude in terminal tabs

    private func claudeStateChanged(_ tab: TermTab, _ state: ClaudeState) {
        let id = "claude-\(tab.id.uuidString)"
        switch state {
        case .working:
            activities.push(["id": id, "title": tab.displayName, "subtitle": "Claude is working…",
                             "state": "running", "icon": "sparkle", "tint": "accent", "ttl": "14400", "quiet": "1"])
        case .attention:
            activities.push(["id": id, "title": tab.displayName, "subtitle": "Claude needs your OK",
                             "state": "attention", "icon": "hand.raised.fill", "tint": "orange", "ttl": "1800"])
            if settings.claudeSound { NSSound(named: NSSound.Name("Ping"))?.play() }
            cat.surprise()
        case .done(_, let took):
            let t = took > 0 ? " · \(StatusDetail.fmt(took))" : ""
            activities.push(["id": id, "title": tab.displayName, "subtitle": "Claude finished\(t)",
                             "state": "done", "icon": "checkmark.circle.fill", "tint": "green", "ttl": "12"])
            if settings.claudeSound { NSSound(named: NSSound.Name("Glass"))?.play() }
            cat.surprise()
        case .idle, .closed:
            activities.end(id: id)
        }
    }
}
