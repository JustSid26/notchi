import Foundation

/// One entry of a terminal tab's recent conversation, as shown in the island.
struct ChatItem: Identifiable, Equatable {
    enum Role { case user, assistant, tool, screen, note }
    let id: String
    let role: Role
    let text: String
}

/// Loads the recent conversation of the selected terminal tab.
///
/// If Claude Code runs in the tab, this reads the tail of that session's transcript file
/// (found through `~/.claude/sessions/<pid>.json`), so you get the real messages rather than
/// a screen scrape. Otherwise it falls back to the text currently on the terminal's screen.
final class TranscriptStore: ObservableObject {
    enum Source: Equatable { case none, claude, screen }

    /// Aim to show at least this many characters of earlier conversation.
    static let minChars = 8000

    @Published private(set) var items: [ChatItem] = []
    @Published private(set) var source: Source = .none
    @Published private(set) var loading = false
    /// How many characters of conversation are loaded.
    @Published private(set) var chars = 0
    /// Bumps whenever the content changes (the view scrolls to the newest message).
    @Published private(set) var version = 0

    /// Reads what's on a tab's screen (AppleScript, supplied by `TerminalTabs`).
    var screenProvider: ((TermTab, @escaping (String?) -> Void) -> Void)?

    private var current: TermTab?
    private var generation = 0
    private var timer: Timer?
    private var tick = 0
    private let queue = DispatchQueue(label: "notchi.transcript", qos: .userInitiated)

    // Only touched on `queue`.
    private var claudePID: Int32?
    private var lastStamp: String?
    private var pathCache: [String: URL] = [:]

    // MARK: - Lifecycle

    func show(_ tab: TermTab) {
        if current?.id == tab.id { return }
        current = tab
        generation += 1
        items = []
        chars = 0
        source = .none
        loading = true
        tick = 0
        queue.async { [weak self] in
            self?.claudePID = nil
            self?.lastStamp = nil
        }
        refresh()
        timer?.invalidate()
        let t = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func hide() {
        guard current != nil else { return }
        current = nil
        generation += 1
        timer?.invalidate()
        timer = nil
        items = []
        chars = 0
        source = .none
        loading = false
    }

    private func refresh() {
        guard let tab = current else { return }
        let gen = generation
        tick += 1
        // Look for a (new) Claude session now and then: it may start or stop while you watch.
        let reresolve = tick % 6 == 1
        let screenTurn = tick % 2 == 1
        queue.async { [weak self] in
            guard let self else { return }
            if let url = self.transcriptURL(for: tab, reresolve: reresolve) {
                let stamp = Self.stamp(url)
                if stamp == self.lastStamp { return }
                guard let parsed = Self.parse(url) else { return }
                self.lastStamp = stamp
                self.publish(parsed.items, chars: parsed.chars, source: .claude, gen: gen)
            } else if screenTurn {
                self.lastStamp = nil
                DispatchQueue.main.async {
                    guard gen == self.generation else { return }
                    guard let provider = self.screenProvider else { self.loading = false; return }
                    provider(tab) { text in
                        let screen = Self.screenItems(text ?? "")
                        self.publish(screen.items, chars: screen.chars, source: text == nil ? .none : .screen, gen: gen)
                    }
                }
            }
        }
    }

    private func publish(_ new: [ChatItem], chars: Int, source: Source, gen: Int) {
        DispatchQueue.main.async {
            guard gen == self.generation else { return }
            self.loading = false
            if self.source != source { self.source = source }
            if self.chars != chars { self.chars = chars }
            if self.items != new {
                self.items = new
                self.version += 1
            }
        }
    }

    // MARK: - Finding the Claude Code session in a tab

    private static var claudeDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
    }

    private func transcriptURL(for tab: TermTab, reresolve: Bool) -> URL? {
        if let pid = claudePID, kill(pid, 0) != 0 { claudePID = nil }
        if claudePID == nil || reresolve { claudePID = Self.claudePID(onTTY: tab.tty) ?? claudePID }
        guard let pid = claudePID, let session = Self.sessionInfo(pid: pid) else { return nil }
        if let cached = pathCache[session.id], FileManager.default.fileExists(atPath: cached.path) { return cached }
        guard let url = Self.findTranscript(sessionID: session.id, cwd: session.cwd) else { return nil }
        pathCache[session.id] = url
        return url
    }

    /// Claude Code writes `~/.claude/sessions/<pid>.json` for every running session.
    private static func sessionInfo(pid: Int32) -> (id: String, cwd: String, updated: Double)? {
        let url = claudeDir.appendingPathComponent("sessions/\(pid).json")
        guard let data = try? Data(contentsOf: url),
              let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = d["sessionId"] as? String, isSafeID(id) else { return nil }
        return (id, d["cwd"] as? String ?? "", (d["updatedAt"] as? NSNumber)?.doubleValue ?? 0)
    }

    /// The session id becomes part of a file path, so accept only plain ids.
    private static func isSafeID(_ s: String) -> Bool {
        !s.isEmpty && s.count < 80 && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    private static func claudePID(onTTY tty: String) -> Int32? {
        let name = (tty as NSString).lastPathComponent
        guard !name.isEmpty, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
              let out = run("/bin/ps", ["-t", name, "-o", "pid="]) else { return nil }
        let pids = out.split(whereSeparator: \.isNewline).compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
        // Several sessions on one tty (a nested shell): take the one that was active last.
        return pids.compactMap { pid in sessionInfo(pid: pid).map { (pid, $0.updated) } }
            .max { $0.1 < $1.1 }?.0
    }

    private static func findTranscript(sessionID: String, cwd: String) -> URL? {
        let fm = FileManager.default
        let projects = claudeDir.appendingPathComponent("projects", isDirectory: true)
        let file = "\(sessionID).jsonl"
        // Claude Code names the project folder after the working directory.
        if !cwd.isEmpty {
            let folder = String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
            let guess = projects.appendingPathComponent(folder).appendingPathComponent(file)
            if fm.fileExists(atPath: guess.path) { return guess }
        }
        guard let dirs = try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil) else { return nil }
        return dirs.map { $0.appendingPathComponent(file) }.first { fm.fileExists(atPath: $0.path) }
    }

    private static func stamp(_ url: URL) -> String {
        let a = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (a?[.size] as? NSNumber)?.int64Value ?? -1
        let mod = (a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(url.path)|\(size)|\(mod)"
    }

    private static func run(_ exe: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Reading the transcript

    /// Reads the end of a Claude Code transcript (JSON lines), newest messages last.
    /// Grows the window it reads until it has `minChars` of conversation or reaches the start.
    static func parse(_ url: URL, minChars: Int = TranscriptStore.minChars) -> (items: [ChatItem], chars: Int)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        // Transcripts can be hundreds of MB (screenshots and tool output live inside them), so
        // read only the tail: 512 KB, widening to at most 6 MB if that's mostly tool chatter.
        var window: UInt64 = 512 * 1024
        let maxWindow: UInt64 = 6 * 1024 * 1024
        while true {
            let offset = size > window ? size - window : 0
            guard (try? handle.seek(toOffset: offset)) != nil,
                  var data = try? handle.readToEnd() else { return nil }
            if offset > 0 {
                // Drop the first line: it's cut off.
                guard let nl = data.firstIndex(of: 0x0A) else { data = Data(); break }
                data = data.subdata(in: data.index(after: nl)..<data.endIndex)
            }
            let result = collect(from: data, minChars: minChars)
            if result.chars >= minChars || offset == 0 || window >= maxWindow {
                return (result.items, result.chars)
            }
            window = min(window * 3, maxWindow)
        }
        return ([], 0)
    }

    private static let userMarker = Data(#""type":"user""#.utf8)
    private static let assistantMarker = Data(#""type":"assistant""#.utf8)

    private static func collect(from data: Data, minChars: Int) -> (items: [ChatItem], chars: Int) {
        var newestFirst: [ChatItem] = []
        var chars = 0
        var n = 0
        for line in data.split(separator: 0x0A).reversed() {
            // Multi-MB records are screenshots / big tool output, never chat text: skip unparsed.
            if line.count > 256 * 1024 { continue }
            // Parse one record at a time and free its objects right away (keeps memory flat).
            let done: Bool = autoreleasepool {
                // The file also holds large bookkeeping records; skip them without parsing.
                guard line.range(of: userMarker) != nil || line.range(of: assistantMarker) != nil,
                      let d = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let type = d["type"] as? String, type == "user" || type == "assistant",
                      d["isSidechain"] as? Bool != true, d["isMeta"] as? Bool != true,
                      let message = d["message"] as? [String: Any] else { return false }
                let uuid = d["uuid"] as? String ?? "line\(n)"
                n += 1
                if d["isCompactSummary"] as? Bool == true {
                    // The summary itself is long and not something you typed; mark where it happened.
                    newestFirst.append(ChatItem(id: uuid, role: .note, text: "Conversation compacted here"))
                    return false
                }
                // Blocks within one record are in reading order; we're collecting newest first.
                for (i, item) in blocks(of: message, type: type).enumerated().reversed() {
                    newestFirst.append(ChatItem(id: "\(uuid)-\(i)", role: item.role, text: item.text))
                    if item.role != .tool { chars += item.text.count }
                }
                return chars >= minChars
            }
            if done { break }
        }
        return (newestFirst.reversed(), chars)
    }

    private static func blocks(of message: [String: Any], type: String) -> [(role: ChatItem.Role, text: String)] {
        if type == "user" {
            if let s = message["content"] as? String {
                return cleanUser(s).map { [(.user, $0)] } ?? []
            }
            guard let parts = message["content"] as? [[String: Any]] else { return [] }
            // Tool results come back as "user" records; they aren't something you typed.
            if parts.contains(where: { $0["type"] as? String == "tool_result" }) { return [] }
            let text = parts.compactMap { p -> String? in
                switch p["type"] as? String {
                case "text": return p["text"] as? String
                case "image": return "[image]"
                default: return nil
                }
            }.joined(separator: "\n")
            return cleanUser(text).map { [(.user, $0)] } ?? []
        }
        guard let parts = message["content"] as? [[String: Any]] else { return [] }
        return parts.compactMap { p in
            switch p["type"] as? String {
            case "text":
                let t = (p["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return t.isEmpty ? nil : (.assistant, clip(t, 6000))
            case "tool_use":
                return (.tool, toolLine(name: p["name"] as? String ?? "Tool", input: p["input"] as? [String: Any] ?? [:]))
            default:
                return nil   // thinking etc.
            }
        }
    }

    /// "Bash · Run the tests", "Read · Geometry.swift"
    private static func toolLine(name: String, input: [String: Any]) -> String {
        var detail = ""
        if let s = input["description"] as? String { detail = s }
        else if let s = input["file_path"] as? String { detail = (s as NSString).lastPathComponent }
        else if let s = input["pattern"] as? String { detail = s }
        else if let s = input["command"] as? String { detail = s }
        else if let s = input["query"] as? String { detail = s }
        else if let s = input["url"] as? String { detail = s }
        detail = detail.replacingOccurrences(of: "\n", with: " ")
        return detail.isEmpty ? name : "\(name) · \(clip(detail, 90))"
    }

    /// Strips the bookkeeping Claude Code wraps around what you typed.
    static func cleanUser(_ raw: String) -> String? {
        var s = raw
        var command: String?
        if let name = firstTag("command-name", in: s) {
            let args = firstTag("command-args", in: s) ?? ""
            command = (name.hasPrefix("/") ? name : "/" + name) + (args.isEmpty ? "" : " " + args)
        }
        for tag in ["system-reminder", "local-command-caveat", "local-command-stdout", "local-command-stderr",
                    "command-name", "command-message", "command-args", "task-notification"] {
            s = s.replacingOccurrences(of: "<\(tag)>[\\s\\S]*?</\(tag)>", with: "", options: .regularExpression)
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let command { s = s.isEmpty ? command : command + "\n" + s }
        return s.isEmpty ? nil : clip(s, 2500)
    }

    private static func firstTag(_ tag: String, in s: String) -> String? {
        guard let open = s.range(of: "<\(tag)>"),
              let close = s.range(of: "</\(tag)>", range: open.upperBound..<s.endIndex) else { return nil }
        return String(s[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func clip(_ s: String, _ limit: Int) -> String {
        s.count > limit ? String(s.prefix(limit)) + " …" : s
    }

    // MARK: - Screen fallback

    /// The tail of what's on the terminal's screen, with the empty rows below the cursor removed.
    static func screenItems(_ text: String, limit: Int = 12000) -> (items: [ChatItem], chars: Int) {
        var lines = text.components(separatedBy: .newlines).map { line -> String in
            var l = Substring(line)
            while let c = l.last, c == " " || c == "\t" || c == "\u{00A0}" { l = l.dropLast() }
            return String(l)
        }
        while let last = lines.last, last.isEmpty { lines.removeLast() }
        while let first = lines.first, first.isEmpty { lines.removeFirst() }
        var out = lines.joined(separator: "\n")
        if out.count > limit {
            out = String(out.suffix(limit))
            if let nl = out.firstIndex(of: "\n") { out = String(out[out.index(after: nl)...]) }
        }
        return out.isEmpty ? ([], 0) : ([ChatItem(id: "screen", role: .screen, text: out)], out.count)
    }
}
