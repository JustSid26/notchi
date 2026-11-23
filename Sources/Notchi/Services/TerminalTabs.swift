import AppKit
import CoreServices
import Foundation
import SwiftUI

/// A terminal tab pinned to the island (added with `island tab add`, or from the island's + menu).
struct TermTab: Identifiable, Codable, Equatable {
    var id = UUID()
    /// e.g. "/dev/ttys003" (may be empty when unknown).
    var tty: String
    /// iTerm2 session unique id (from $ITERM_SESSION_ID).
    var itermID: String?
    /// "iTerm2" or "Terminal".
    var app: String
    var customName: String?
    var liveName: String = ""
    /// Unprocessed terminal title (e.g. "✳ Repo check (claude)") — used to tell if Claude runs there.
    var rawName: String?

    var displayName: String {
        if let customName, !customName.isEmpty { return customName }
        if !liveName.isEmpty { return liveName }
        return tty.isEmpty ? app : (tty as NSString).lastPathComponent
    }
}

/// What Claude Code is doing in a tab, as reported by its hooks.
enum ClaudeState: Equatable {
    case idle
    case working(since: Date)
    case attention(since: Date)
    case done(at: Date, took: TimeInterval)
    case closed

    var isWorking: Bool { if case .working = self { return true }; return false }
}

/// An open terminal session we could pin.
struct OpenSession: Identifiable, Equatable {
    var id: String { itermID ?? tty }
    let itermID: String?
    let tty: String
    let name: String
    let app: String
    var raw: String = ""
}

final class TerminalTabs: ObservableObject {
    static let maxTabs = 10

    @Published private(set) var tabs: [TermTab] = []
    @Published private(set) var states: [UUID: ClaudeState] = [:]
    @Published var selectedID: UUID?
    @Published private(set) var openSessions: [OpenSession] = []
    @Published private(set) var sentFlash: String?
    /// Why we couldn't read iTerm2 (shown in the picker), e.g. a missing Automation permission.
    @Published private(set) var accessProblem: String?
    @Published private(set) var permissionDenied = false
    @Published private(set) var itermRunning = false
    /// iTerm2 session id → its tab colour (via the Python API, see ItermColorBridge).
    @Published private(set) var tabColors: [String: Color] = [:]
    @Published private(set) var colorProblem: String?
    private var lastColorFetch = Date.distantPast
    private var fetchingColors = false

    /// Called when Claude's state in a pinned tab changes (start, needs you, finished…).
    var onStateChange: ((TermTab, ClaudeState) -> Void)?
    /// The island polls tab names only while it matters.
    var islandOpen = false

    private var workStart: [UUID: Date] = [:]
    /// Tabs whose Claude Code hooks have reported in (so we know Claude is running there).
    private var claudeSeen: Set<UUID> = []
    private let queue = DispatchQueue(label: "notchi.terminals")
    private var timer: Timer?
    private let key = "terminalTabs"
    private static let itermBundle = "com.googlecode.iterm2"
    private static let terminalBundle = "com.apple.Terminal"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode([TermTab].self, from: data) {
            tabs = saved
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in self?.poll() }
        poll()
    }

    var selected: TermTab? { tabs.first { $0.id == selectedID } }
    var isFull: Bool { tabs.count >= Self.maxTabs }
    func state(of tab: TermTab) -> ClaudeState { states[tab.id] ?? .idle }

    /// Open sessions that aren't pinned yet (for the + menu).
    var addableSessions: [OpenSession] {
        openSessions.filter { s in index(tty: s.tty, itermID: s.itermID) == nil }
    }

    // MARK: - Registry

    @discardableResult
    func add(tty: String, itermID: String?, app: String, name: String?) -> TermTab? {
        let name = name?.trimmingCharacters(in: .whitespaces)
        if let i = index(tty: tty, itermID: itermID) {
            if let name, !name.isEmpty { tabs[i].customName = name; save() }
            return tabs[i]
        }
        guard !isFull else { return nil }
        let live = openSessions.first { s in
            (itermID != nil && s.itermID == itermID) || (!tty.isEmpty && s.tty == tty)
        }?.name ?? ""
        let tab = TermTab(tty: tty, itermID: itermID?.isEmpty == true ? nil : itermID, app: app,
                          customName: name?.isEmpty == false ? name : nil, liveName: live)
        tabs.append(tab)
        save()
        poll()
        return tab
    }

    func add(_ s: OpenSession) { add(tty: s.tty, itermID: s.itermID, app: s.app, name: nil) }

    func isPinned(_ s: OpenSession) -> Bool { index(tty: s.tty, itermID: s.itermID) != nil }

    /// Checklist toggle: pin if not pinned (when there's room), unpin if pinned.
    func togglePin(_ s: OpenSession) {
        if let i = index(tty: s.tty, itermID: s.itermID) { remove(tabs[i]) } else { add(s) }
    }

    func remove(_ tab: TermTab) {
        tabs.removeAll { $0.id == tab.id }
        states[tab.id] = nil
        workStart[tab.id] = nil
        if selectedID == tab.id { selectedID = nil }
        save()
        onStateChange?(tab, .idle)
    }

    func remove(tty: String?, itermID: String?) {
        if let i = index(tty: tty, itermID: itermID) { remove(tabs[i]) }
    }

    func color(for tab: TermTab) -> Color? { tab.itermID.flatMap { tabColors[$0] } }
    func color(for s: OpenSession) -> Color? { s.itermID.flatMap { tabColors[$0] } }

    /// Drag-to-reorder: move `id` to where `target` is.
    func move(_ id: UUID, to target: UUID) {
        guard id != target, let from = tabs.firstIndex(where: { $0.id == id }),
              let to = tabs.firstIndex(where: { $0.id == target }) else { return }
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: to)
        save()
    }

    /// Refresh tab colours (throttled; the Python bridge takes ~half a second).
    func refreshColors(force: Bool = false) {
        guard ItermColorBridge.isInstalled else { if colorProblem != "setup" { colorProblem = "setup" }; return }
        guard ItermColorBridge.apiEnabled else { if colorProblem != "api" { colorProblem = "api" }; return }
        guard !fetchingColors, force || Date().timeIntervalSince(lastColorFetch) > 12 else { return }
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: Self.itermBundle).isEmpty else { return }
        fetchingColors = true
        lastColorFetch = Date()
        queue.async { [weak self] in
            var err: NSDictionary?
            let cookie = NSAppleScript(source: "tell application \"iTerm2\" to request cookie and key for app named \"Notchi\"")?
                .executeAndReturnError(&err).stringValue
            var colors: [String: Color]?
            var problem: String?
            if let cookie {
                do { colors = try ItermColorBridge.fetchColors(cookieAndKey: cookie) } catch { problem = error.localizedDescription }
            } else {
                problem = "iTerm2 didn't hand out an API key"
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.fetchingColors = false
                if let colors { if colors != self.tabColors { self.tabColors = colors }; self.colorProblem = nil }
                if let problem {
                    self.colorProblem = problem
                    Self.debugLog("colors: \(problem)")
                }
            }
        }
    }

    func toggleSelect(_ tab: TermTab) {
        selectedID = selectedID == tab.id ? nil : tab.id
    }

    /// ⌘↓ / ⌘↑: step through the pinned tabs (wrapping around). With nothing selected,
    /// ⌘↓ starts at the top and ⌘↑ at the bottom.
    func selectAdjacent(_ step: Int) {
        guard !tabs.isEmpty else { return }
        guard let current = selectedID, let i = tabs.firstIndex(where: { $0.id == current }) else {
            selectedID = step > 0 ? tabs.first?.id : tabs.last?.id
            return
        }
        let n = tabs.count
        selectedID = tabs[((i + step) % n + n) % n].id
    }

    private func index(tty: String?, itermID: String?) -> Int? {
        if let itermID, !itermID.isEmpty, let i = tabs.firstIndex(where: { $0.itermID == itermID }) { return i }
        if let tty, !tty.isEmpty, let i = tabs.firstIndex(where: { $0.tty == tty }) { return i }
        return nil
    }

    private func save() {
        if let data = try? JSONEncoder().encode(tabs) { UserDefaults.standard.set(data, forKey: key) }
    }

    // MARK: - Claude Code hook events

    /// `event` is one of: working, attention, done, end.
    func claudeEvent(_ event: String, tty: String?, itermID: String?, message: String?) {
        guard let i = index(tty: tty, itermID: itermID) else { return }
        let tab = tabs[i]
        if event == "end" { claudeSeen.remove(tab.id) } else { claudeSeen.insert(tab.id) }
        let now = Date()
        let new: ClaudeState
        switch event {
        case "working":
            if workStart[tab.id] == nil { workStart[tab.id] = now }
            if state(of: tab).isWorking { return }
            new = .working(since: workStart[tab.id] ?? now)
        case "attention":
            // Only permission prompts — not the "waiting for your input" idle nudge.
            let m = (message ?? "").lowercased()
            guard m.contains("permission") || m.contains("approv") || m.contains("needs your") else { return }
            new = .attention(since: now)
        case "done":
            // Hooks and the title watcher can both report the finish — only announce it once.
            if case .done = state(of: tab) { return }
            let took = workStart[tab.id].map { now.timeIntervalSince($0) } ?? 0
            workStart[tab.id] = nil
            new = .done(at: now, took: took)
        case "end":
            workStart[tab.id] = nil
            new = .idle
        default:
            return
        }
        states[tab.id] = new
        onStateChange?(tab, new)
    }

    // MARK: - Talking to the terminal

    /// Types `prompt` into the tab's Claude session and presses Return.
    func send(_ prompt: String, to tab: TermTab) {
        let text = prompt
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        if let reason = blockReason(for: tab) {
            flash(reason)
            return
        }
        let lit = Self.literal(text)
        let script: String
        if tab.app == "Terminal" {
            script = """
            tell application "Terminal"
              repeat with w in windows
                repeat with t in tabs of w
                  if tty of t is \(Self.literal(tab.tty)) then
                    do script \(lit) in t
                    return "ok"
                  end if
                end repeat
              end repeat
              return "missing"
            end tell
            """
        } else {
            script = """
            tell application "iTerm2"
              repeat with w in windows
                repeat with t in tabs of w
                  repeat with s in sessions of t
                    if (unique id of s) is \(Self.literal(tab.itermID ?? "-")) or (tty of s) is \(Self.literal(tab.tty.isEmpty ? "-" : tab.tty)) then
                      tell s to write text \(lit) without newline
                      delay 0.2
                      tell s to write text (character id 13) without newline
                      return "ok"
                    end if
                  end repeat
                end repeat
              end repeat
              return "missing"
            end tell
            """
        }
        run(script) { [weak self] result in
            guard let self else { return }
            if result == "ok" {
                self.flash("Sent to \(tab.displayName)")
                // Treat it as started right away; the hooks will confirm.
                self.claudeEvent("working", tty: tab.tty, itermID: tab.itermID, message: nil)
            } else {
                self.flash("Couldn't reach \(tab.displayName). Is the tab open, and is Notchi allowed to control iTerm2?")
            }
        }
    }

    /// Typing + Return into the wrong place could approve a permission prompt or run a shell
    /// command, so only send when Claude is clearly sitting at its input box.
    func blockReason(for tab: TermTab) -> String? {
        switch state(of: tab) {
        case .attention:
            return "Claude is waiting for your approval in \(tab.displayName). Answer it in the terminal."
        case .closed:
            return "\(tab.displayName) was closed."
        default:
            break
        }
        let raw = (tab.rawName ?? "").lowercased()
        let looksLikeClaude = raw.hasPrefix("✳") || raw.contains("claude") || raw.unicodeScalars.first.map {
            (0x2800...0x28FF).contains($0.value) || (0x2720...0x273F).contains($0.value)
                || (0x25D0...0x25D3).contains($0.value)   // Claude's title glyphs: ✳ idle, ◐◑◒◓ working
        } == true
        if !claudeSeen.contains(tab.id) && !looksLikeClaude {
            return "Claude doesn't seem to be running in \(tab.displayName)."
        }
        return nil
    }

    private func flash(_ message: String) {
        sentFlash = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { [weak self] in
            if self?.sentFlash == message { self?.sentFlash = nil }
        }
    }

    /// What's on the tab's screen (Terminal.app gives its whole scrollback), for tabs where
    /// Claude Code isn't running and there's no transcript to read.
    func screenText(of tab: TermTab, completion: @escaping (String?) -> Void) {
        let script: String
        if tab.app == "Terminal" {
            guard !tab.tty.isEmpty else { return completion(nil) }
            script = """
            tell application "Terminal"
              repeat with w in windows
                repeat with t in tabs of w
                  if tty of t is \(Self.literal(tab.tty)) then return history of t
                end repeat
              end repeat
            end tell
            """
        } else {
            script = """
            tell application "iTerm2"
              repeat with w in windows
                repeat with t in tabs of w
                  repeat with s in sessions of t
                    if (unique id of s) is \(Self.literal(tab.itermID ?? "-")) or (tty of s) is \(Self.literal(tab.tty.isEmpty ? "-" : tab.tty)) then
                      return contents of s
                    end if
                  end repeat
                end repeat
              end repeat
            end tell
            """
        }
        run(script, completion: completion)
    }

    /// Brings the terminal app forward with this tab selected.
    func focus(_ tab: TermTab) {
        let script: String
        if tab.app == "Terminal" {
            script = """
            tell application "Terminal"
              activate
              repeat with w in windows
                repeat with t in tabs of w
                  if tty of t is \(Self.literal(tab.tty)) then
                    set selected of t to true
                    set index of w to 1
                    return "ok"
                  end if
                end repeat
              end repeat
            end tell
            """
        } else {
            script = """
            tell application "iTerm2"
              activate
              repeat with w in windows
                repeat with t in tabs of w
                  repeat with s in sessions of t
                    if (unique id of s) is \(Self.literal(tab.itermID ?? "-")) or (tty of s) is \(Self.literal(tab.tty.isEmpty ? "-" : tab.tty)) then
                      select w
                      tell t to select
                      tell s to select
                      return "ok"
                    end if
                  end repeat
                end repeat
              end repeat
            end tell
            """
        }
        run(script, completion: nil)
    }

    // MARK: - Polling tab names

    /// Compiled once and only touched on `queue`.
    private var pollScript: NSAppleScript?
    /// One Apple event per property for *all* tabs (fast) instead of one per tab per property.
    private static let pollSource = """
    tell application "iTerm2"
      set ids to unique id of every session of every tab of every window
      set ttys to tty of every session of every tab of every window
      set names to name of every session of every tab of every window
      set titles to title of every tab of every window
      return {ids, ttys, names, titles}
    end tell
    """

    func poll(force: Bool = false) {
        guard force || !tabs.isEmpty || islandOpen else { return }
        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: Self.itermBundle).isEmpty
        if itermRunning != running { itermRunning = running }
        guard running else {
            if !openSessions.isEmpty { openSessions = [] }
            return
        }
        queue.async { [weak self] in
            guard let self else { return }
            if self.pollScript == nil {
                let script = NSAppleScript(source: Self.pollSource)
                var compileErr: NSDictionary?
                script?.compileAndReturnError(&compileErr)
                self.pollScript = script
            }
            var err: NSDictionary?
            let result = self.pollScript?.executeAndReturnError(&err)
            let sessions = err == nil ? Self.parseSessions(result) : nil
            let number = err?[NSAppleScript.errorNumber] as? Int
            let message = err?[NSAppleScript.errorMessage] as? String ?? "unknown error"
            DispatchQueue.main.async {
                if let number {
                    // -1743: not permitted · -1744: would need consent · -600: app not running
                    let denied = number == -1743 || number == -1744
                    if self.permissionDenied != denied { self.permissionDenied = denied }
                    let problem = denied ? "Notchi isn't allowed to control iTerm2 yet" : "iTerm2 said: \(message) (\(number))"
                    if self.accessProblem != problem { self.accessProblem = problem }
                    Self.debugLog("poll: AppleScript error \(number) \(message)")
                } else if let sessions {
                    self.apply(sessions)
                }
            }
        }
    }

    private func apply(_ sessions: [OpenSession]) {
        if accessProblem != nil { accessProblem = nil }
        if permissionDenied { permissionDenied = false }
        if sessions != openSessions { openSessions = sessions }
        refreshColors()
        var changed = false
        for i in tabs.indices where tabs[i].app == "iTerm2" {
            let t = tabs[i]
            let match = sessions.first { s in
                if let id = t.itermID { return s.itermID == id }
                return s.tty == t.tty
            }
            if let m = match {
                if tabs[i].liveName != m.name { tabs[i].liveName = m.name; changed = true }
                if tabs[i].rawName != m.raw { tabs[i].rawName = m.raw }
                if tabs[i].tty != m.tty { tabs[i].tty = m.tty; changed = true }
                if states[t.id] == .closed { states[t.id] = .idle }
                // Claude Code shows ◐◑◒◓ in the tab title while working and ✳ when idle — a
                // fallback for sessions started before the hooks were connected.
                let glyph = m.raw.unicodeScalars.first?.value ?? 0
                let spinning = (0x25D0...0x25D3).contains(glyph)
                if spinning && !state(of: t).isWorking {
                    claudeEvent("working", tty: t.tty, itermID: t.itermID, message: nil)
                } else if !spinning && glyph == 0x2733 && state(of: t).isWorking {
                    claudeEvent("done", tty: t.tty, itermID: t.itermID, message: nil)
                }
            } else if states[t.id] != .closed {
                states[t.id] = .closed
                workStart[t.id] = nil
                onStateChange?(t, .closed)
            }
        }
        if changed { save() }
    }

    /// {ids, ttys, names, titles}: the first three are nested windows → tabs → sessions,
    /// titles is windows → tabs.
    private static func parseSessions(_ result: NSAppleEventDescriptor?) -> [OpenSession]? {
        func items(_ d: NSAppleEventDescriptor?) -> [NSAppleEventDescriptor] {
            guard let d, d.descriptorType == DescType(typeAEList), d.numberOfItems > 0 else { return [] }
            return (1...d.numberOfItems).compactMap { d.atIndex($0) }
        }
        func at(_ a: [NSAppleEventDescriptor], _ i: Int) -> NSAppleEventDescriptor? { i < a.count ? a[i] : nil }
        let top = items(result)
        guard top.count == 4 else { return nil }
        let ids = items(top[0]), ttys = items(top[1]), names = items(top[2]), titles = items(top[3])
        var out: [OpenSession] = []
        for w in ids.indices {
            let wIds = items(ids[w]), wTtys = items(at(ttys, w)), wNames = items(at(names, w)), wTitles = items(at(titles, w))
            for t in wIds.indices {
                let tIds = items(wIds[t]), tTtys = items(at(wTtys, t)), tNames = items(at(wNames, t))
                let title = at(wTitles, t)?.stringValue ?? ""
                for i in tIds.indices {
                    let raw = at(tNames, i)?.stringValue ?? ""
                    // Show the tab's title exactly as iTerm2's tab bar does ("crm", "lead-gen"…).
                    let shown = title.isEmpty ? raw : title
                    out.append(OpenSession(itermID: tIds[i].stringValue, tty: at(tTtys, i)?.stringValue ?? "",
                                           name: Self.cleanName(shown), app: "iTerm2", raw: raw))
                }
            }
        }
        return out
    }

    /// "✳ Dizrupt CRM web app (python)" → "Dizrupt CRM web app"
    static func cleanName(_ raw: String) -> String {
        var s = Substring(raw)
        while let c = s.first, !(c.isLetter || c.isNumber) { s = s.dropFirst() }
        var out = String(s)
        if let r = out.range(of: #"\s*\([^()]*\)$"#, options: .regularExpression) { out.removeSubrange(r) }
        return out.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - AppleScript

    private static func literal(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private func run(_ source: String, onError: ((Int, String) -> Void)? = nil,
                     completion: ((String?) -> Void)?) {
        queue.async {
            var err: NSDictionary?
            let result = NSAppleScript(source: source)?.executeAndReturnError(&err)
            let out = err == nil ? result?.stringValue : nil
            if err != nil { Self.debugLog("run: AppleScript error \(err!)") }
            let number = err?[NSAppleScript.errorNumber] as? Int
            let message = err?[NSAppleScript.errorMessage] as? String ?? "unknown error"
            DispatchQueue.main.async {
                if let number { onError?(number, message) }
                completion?(out)
            }
        }
    }

    // MARK: - Automation permission

    /// Ask macOS for permission to control iTerm2 (shows the system prompt if it hasn't been answered).
    func requestAccess() {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: Self.itermBundle).isEmpty else {
            accessProblem = "Open iTerm2 first"
            return
        }
        queue.async { [weak self] in
            let target = NSAppleEventDescriptor(bundleIdentifier: Self.itermBundle)
            let status: OSStatus = target.aeDesc.map {
                AEDeterminePermissionToAutomateTarget($0, typeWildCard, typeWildCard, true)
            } ?? OSStatus(procNotFound)
            Self.debugLog("requestAccess: AEDeterminePermissionToAutomateTarget → \(status)")
            DispatchQueue.main.async {
                guard let self else { return }
                if status == noErr {
                    self.permissionDenied = false
                    self.accessProblem = nil
                    self.poll(force: true)
                } else if status == OSStatus(errAEEventNotPermitted) {
                    self.permissionDenied = true
                    self.accessProblem = "Notchi isn't allowed to control iTerm2. Turn it on in System Settings → Privacy & Security → Automation."
                } else {
                    self.accessProblem = "Couldn't ask for iTerm2 access (\(status))"
                }
            }
        }
    }

    /// Tiny diagnostic log at ~/Library/Logs/Notchi.log (NSLog isn't visible for ad-hoc builds).
    static func debugLog(_ message: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Notchi.log")
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    static func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Claude Code hooks installer

/// Adds/removes Notchi's hooks in ~/.claude/settings.json, so Claude Code tells the island
/// when it starts working, needs approval, or finishes — per terminal tab.
enum ClaudeHooks {
    /// Our hook commands look like: "/Users/…/.local/bin/island" claude-hook done
    static func isOurs(_ command: String) -> Bool { command.contains("island") && command.contains("claude-hook") }
    /// (Claude Code hook event, what we report)
    static let events: [(String, String)] = [
        ("UserPromptSubmit", "working"),
        ("PreToolUse", "working"),
        ("Notification", "attention"),
        ("Stop", "done"),
        ("SessionEnd", "end"),
    ]

    static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }
    static var cliPath: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/island").path
    }

    static func isInstalled() -> Bool {
        guard let s = try? String(contentsOf: settingsURL, encoding: .utf8) else { return false }
        return s.contains("claude-hook") && s.contains("/island")
    }

    static func install() throws {
        var root = try readSettings()
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for (event, report) in events {
            var groups = stripOurs(hooks[event] as? [[String: Any]] ?? [])
            groups.append(["hooks": [["type": "command", "command": "\"\(cliPath)\" claude-hook \(report)"]]])
            hooks[event] = groups
        }
        root["hooks"] = hooks
        try writeSettings(root)
    }

    static func uninstall() throws {
        var root = try readSettings()
        guard var hooks = root["hooks"] as? [String: Any] else { return }
        for (event, _) in events {
            let groups = stripOurs(hooks[event] as? [[String: Any]] ?? [])
            hooks[event] = groups.isEmpty ? nil : groups
        }
        root["hooks"] = hooks.isEmpty ? nil : hooks
        try writeSettings(root)
    }

    private static func stripOurs(_ groups: [[String: Any]]) -> [[String: Any]] {
        groups.filter { g in
            !((g["hooks"] as? [[String: Any]])?.contains { isOurs($0["command"] as? String ?? "") } ?? false)
        }
    }

    private static func readSettings() throws -> [String: Any] {
        let url = settingsURL
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return [:] }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "Notchi", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "~/.claude/settings.json isn't a JSON object."])
        }
        return obj
    }

    private static func writeSettings(_ root: [String: Any]) throws {
        let fm = FileManager.default
        let url = settingsURL
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: url.path) {
            let backup = url.deletingLastPathComponent().appendingPathComponent("settings.json.notchi-backup")
            try? fm.removeItem(at: backup)
            try? fm.copyItem(at: url, to: backup)
        }
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }
}
