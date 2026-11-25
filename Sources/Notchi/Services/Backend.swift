import AppKit
import Foundation

/// Client for Notchi's Java backend (`backend/` in this repo), which runs on this Mac at
/// http://127.0.0.1:7340 and owns the algorithms:
///
/// - LIVE queue order: an indexed binary heap
/// - duplicate event screening: a Bloom filter in front of an exact event log
/// - launcher search: a trie
/// - Claude ETA: percentiles by randomized Quickselect
///
/// The backend is optional. When it isn't running (or is turned off in Settings) Notchi works
/// exactly as before; it reconnects by itself as soon as the backend starts.
final class Backend: ObservableObject {
    static let shared = Backend()
    static let base = "http://127.0.0.1:7340"
    /// Shown in Settings when the backend isn't running.
    static let startCommand = "cd backend && ./mvnw -q package -DskipTests && java -jar target/notchi-backend.jar"

    struct Eta: Equatable {
        let p50: Double
        let p90: Double
        let count: Int
        let scope: String
    }

    struct LaunchResult: Identifiable, Equatable {
        let id: String
        let label: String
        let kind: String      // app, tab, command
        let path: String?
        let uses: Int
    }

    struct Response {
        let status: Int
        let json: [String: Any]
        var ok: Bool { (200..<300).contains(status) }
        var error: String { json["error"] as? String ?? "HTTP \(status)" }
    }

    @Published private(set) var connected = false
    @Published private(set) var version: String?
    /// What the running backend can do (an older backend lacks the newer pages).
    @Published private(set) var features: Set<String> = []
    /// Why the backend can't be used, if it can't (shown on the pages and in Settings).
    @Published var problem: String?
    /// The backend's /api/stats (shown in Settings).
    @Published private(set) var stats: [String: Any] = [:]
    /// Claude run-time percentiles per terminal tab (key: lower-cased tab name).
    @Published private(set) var etas: [String: Eta] = [:]
    /// LIVE activity ids, most urgent first, as ordered by the backend's heap.
    @Published private(set) var liveOrder: [String] = []
    @Published private(set) var launcherResults: [LaunchResult] = []
    /// e.g. "Trie · 0.04 ms · 312 items"
    @Published private(set) var launcherInfo: String?

    /// Called on the main queue each time the backend (re)connects.
    var onConnect: (() -> Void)?

    private let session: URLSession
    private var timer: Timer?
    /// The backend process we're talking to (changes when it restarts).
    private var instance: String?
    /// Queue version of the order currently shown; older orders are ignored.
    private var orderVersion: Int64 = -1
    private var searchSeq = 0
    private var searchWork: DispatchWorkItem?

    /// LIVE changes go out one at a time, in order, so a late reply can't undo a newer update
    /// and a removal can't overtake the push before it.
    private enum LiveOp {
        case event([String: Any], (String?) -> Void)
        case remove(String)
    }
    private var liveQueue: [LiveOp] = []
    private var inFlight: (op: LiveOp, token: Int)?
    private var opToken = 0

    /// The key the backend requires (X-Notchi-Token). Made once, kept in the Keychain, and given
    /// to the backend Notchi starts, so other programs can't read your notes or clipboard.
    static let token: String = {
        if let t = Keychain.get(account: "backend-token"), t.count >= 32 { return t }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let t = bytes.map { String(format: "%02x", $0) }.joined()
        Keychain.set(t, account: "backend-token")
        return t
    }()

    func supports(_ feature: String) -> Bool { features.contains(feature) }

    private init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 2
        cfg.waitsForConnectivity = false
        session = URLSession(configuration: cfg)
    }

    // MARK: - Connection

    func start() {
        checkHealth()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.checkHealth() }
    }

    func checkHealth() {
        guard AppSettings.shared.useBackend else { return setConnected(false) }
        call("GET", "/api/health") { [weak self] r in
            guard let self else { return }
            let v = r?.json["version"] as? String
            if v != self.version { self.version = v }   // publish only real changes (no re-render every 5 s)
            let f = Set(r?.json["features"] as? [String] ?? [])
            if f != self.features { self.features = f }
            let ok = r?.json["status"] as? String == "ok"
            let inst = r?.json["instance"] as? String
            if ok, self.connected, inst != self.instance {
                // The backend restarted between checks: start over so it gets our state again.
                self.setConnected(false)
            }
            self.instance = inst
            self.setConnected(ok)
            if !ok { BackendLauncher.launchIfNeeded() }   // start the bundled backend if we have one
        }
    }

    private func setConnected(_ on: Bool) {
        guard on != connected else { return }
        connected = on
        orderVersion = -1
        searchSeq += 1
        if on {
            onConnect?()
            refreshStats()
        } else {
            liveOrder = []
            launcherResults = []
            launcherInfo = nil
            etas = [:]
            stats = [:]
            // Hand every unsent change back for local handling, oldest first (the one in
            // flight before the queued ones); its late reply, if any, is then ignored.
            let pending = (inFlight.map { [$0.op] } ?? []) + liveQueue
            inFlight = nil
            liveQueue = []
            for op in pending { if case .event(_, let done) = op { done(nil) } }
        }
    }

    // MARK: - HTTP

    /// Calls the backend. `done` runs on the main queue: nil if the backend couldn't be reached.
    func call(_ method: String, _ path: String, query: [String: String] = [:], json: Any? = nil,
              csv: String? = nil, done: ((Response?) -> Void)? = nil) {
        guard var comps = URLComponents(string: Self.base + path) else { done?(nil); return }
        if !query.isEmpty {
            comps.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            // URLComponents leaves '+' alone, but servers read it as a space.
            comps.percentEncodedQuery = comps.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        guard let url = comps.url else { done?(nil); return }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(Self.token, forHTTPHeaderField: "X-Notchi-Token")
        if let json {
            // JSONSerialization raises (not throws) on NaN or infinity; never let that crash the app.
            guard JSONSerialization.isValidJSONObject(json),
                  let body = try? JSONSerialization.data(withJSONObject: json) else { done?(nil); return }
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        } else if let csv {
            req.httpBody = Data(csv.utf8)
            req.setValue("text/csv", forHTTPHeaderField: "Content-Type")
        }
        session.dataTask(with: req) { [weak self] data, resp, err in
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let obj = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:]
            DispatchQueue.main.async {
                if err != nil || status == 0 {
                    self?.setConnected(false)
                    done?(nil)
                } else {
                    if status == 401 {
                        let msg = "The running backend was started with a different key. Quit it and Notchi will start its own."
                        if self?.problem != msg { self?.problem = msg }
                    }
                    done?(Response(status: status, json: obj))
                }
            }
        }.resume()
    }

    /// A path segment with everything but unreserved characters percent-encoded.
    static func segment(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    func refreshStats() {
        guard connected else { return }
        call("GET", "/api/stats") { [weak self] r in
            guard let self, self.connected, let r, r.ok else { return }
            self.stats = r.json
        }
    }

    // MARK: - LIVE queue

    /// Sends a LIVE event. `done` gets the backend's verdict ("new", "duplicate", …),
    /// or nil if the backend isn't in use, in which case the caller handles the event locally.
    func pushEvent(_ fields: [String: Any], done: @escaping (String?) -> Void) {
        guard connected else { return done(nil) }
        liveQueue.append(.event(fields, done))
        sendNextLiveOp()
    }

    /// Removes an activity, after any changes to it that are still queued.
    func endActivity(_ id: String) {
        guard connected else { return }
        liveQueue.append(.remove(id))
        sendNextLiveOp()
    }

    private func sendNextLiveOp() {
        guard inFlight == nil, !liveQueue.isEmpty else { return }
        let op = liveQueue.removeFirst()
        opToken += 1
        let token = opToken
        inFlight = (op, token)
        let finish: (Response?) -> Void = { [weak self] r in
            guard let self, self.inFlight?.token == token else { return }   // flushed by a disconnect
            self.inFlight = nil
            switch op {
            case .event(_, let done):
                if let r, r.ok {
                    self.applyOrder(r.json["order"] as? [String], version: r.json["version"])
                    done(r.json["verdict"] as? String)
                } else {
                    done(nil)   // rejected: handle it locally
                }
            case .remove:
                self.refreshLiveOrder()
            }
            self.sendNextLiveOp()
        }
        switch op {
        case .event(let fields, _):
            call("POST", "/api/live/events", query: ["limit": "50"], json: fields, done: finish)
        case .remove(let id):
            call("DELETE", "/api/live/" + Self.segment(id), done: finish)
        }
    }

    func refreshLiveOrder() {
        guard connected else { return }
        call("GET", "/api/live", query: ["limit": "50"]) { [weak self] r in
            guard let r, r.ok, let items = r.json["items"] as? [[String: Any]] else { return }
            self?.applyOrder(items.compactMap { $0["id"] as? String }, version: r.json["version"])
        }
    }

    /// Applies a queue order unless a newer one (higher backend queue version) is already shown.
    private func applyOrder(_ order: [String]?, version: Any?) {
        guard connected, let order, let v = (version as? NSNumber)?.int64Value, v >= orderVersion else { return }
        orderVersion = v
        if order != liveOrder { liveOrder = order }
    }

    // MARK: - Launcher

    /// Uploads what can be launched: apps, pinned tabs and Notchi commands.
    func uploadCatalog(_ items: [[String: Any]]) {
        guard connected else { return }
        call("PUT", "/api/launcher/catalog", json: ["items": items]) { [weak self] _ in self?.refreshStats() }
    }

    /// Prefix search as you type (debounced). An empty query clears the results.
    func search(_ text: String) {
        searchWork?.cancel()
        let q = text.trimmingCharacters(in: .whitespaces)
        searchSeq += 1
        let seq = searchSeq
        guard connected, !q.isEmpty, q.count <= 40 else {
            if !launcherResults.isEmpty { launcherResults = [] }
            launcherInfo = nil
            return
        }
        let work = DispatchWorkItem { [weak self] in
            self?.call("GET", "/api/launcher/search", query: ["q": q, "k": "6"]) { r in
                guard let self, self.connected, seq == self.searchSeq, let r, r.ok else { return }
                let items = (r.json["items"] as? [[String: Any]] ?? []).compactMap { d -> LaunchResult? in
                    guard let id = d["id"] as? String, let label = d["label"] as? String,
                          let kind = d["kind"] as? String else { return nil }
                    return LaunchResult(id: id, label: label, kind: kind, path: d["path"] as? String,
                                        uses: (d["uses"] as? NSNumber)?.intValue ?? 0)
                }
                self.launcherResults = items
                let ms = ((r.json["tookMicros"] as? NSNumber)?.doubleValue ?? 0) / 1000
                let n = (r.json["catalogSize"] as? NSNumber)?.intValue ?? 0
                self.launcherInfo = String(format: "Trie · %.2f ms · %d items", ms, n)
            }
        }
        searchWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
    }

    func clearSearch() { search("") }

    func recordUse(_ id: String) {
        guard connected else { return }
        call("POST", "/api/launcher/use", json: ["id": id])
    }

    // MARK: - Claude ETA

    /// History key for a tab: its custom name if you gave it one (stable, and matches imported
    /// history), otherwise its id. iTerm2 titles change with every Claude conversation, so they
    /// would split one tab's history into many.
    static func key(for tab: TermTab) -> String {
        if let name = tab.customName?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            return String(name.lowercased().prefix(100))
        }
        return "tab-" + tab.id.uuidString.lowercased()
    }

    func eta(for tab: TermTab) -> Eta? { etas[Self.key(for: tab)] }

    func recordDuration(tab: TermTab, seconds: TimeInterval) {
        guard connected, seconds >= 3 else { return }
        let key = Self.key(for: tab)
        call("POST", "/api/durations", json: ["key": key, "seconds": seconds]) { [weak self] r in
            if let r, r.ok { self?.storeEta(key, r.json) }
        }
    }

    func refreshEtas(for tabs: [TermTab]) {
        guard connected else { return }
        for key in Set(tabs.map(Self.key(for:))) {
            call("GET", "/api/durations/summary", query: ["key": key]) { [weak self] r in
                if let r, r.ok { self?.storeEta(key, r.json) }
            }
        }
    }

    private func storeEta(_ key: String, _ json: [String: Any]) {
        guard connected else { return }
        guard json["enough"] as? Bool == true,
              let p50 = (json["p50"] as? NSNumber)?.doubleValue,
              let p90 = (json["p90"] as? NSNumber)?.doubleValue else {
            etas[key] = nil
            return
        }
        etas[key] = Eta(p50: p50, p90: p90, count: (json["count"] as? NSNumber)?.intValue ?? 0,
                        scope: json["scope"] as? String ?? key)
    }

    // MARK: - Settings actions

    func configureDedupe(expected: Int, fpp: Double, done: @escaping (String?) -> Void) {
        call("PUT", "/api/live/dedupe", json: ["expected": expected, "fpp": fpp]) { [weak self] r in
            self?.refreshStats()
            done(r.map { $0.ok ? nil : $0.error } ?? "Backend not reachable")
        }
    }

    func importDurations(csv: String, done: @escaping (String) -> Void) {
        call("POST", "/api/durations/import", csv: csv) { [weak self] r in
            guard let r else { return done("Backend not reachable") }
            self?.refreshStats()
            done(r.ok ? "Imported \((r.json["imported"] as? NSNumber)?.intValue ?? 0) runs" : r.error)
        }
    }
}

/// What the launcher can open: installed apps, pinned terminal tabs and Notchi commands.
enum LauncherCatalog {
    struct Command {
        let id: String
        let label: String
        let symbol: String
    }

    static var commands: [Command] {
        var c = [Command(id: "cmd:settings", label: "Notchi Settings", symbol: "gearshape.fill"),
                 Command(id: "cmd:dock-left", label: "Move island to the left edge", symbol: "sidebar.left"),
                 Command(id: "cmd:dock-top", label: "Move island to the top notch", symbol: "rectangle.topthird.inset.filled")]
        for t in IslandTheme.allCases {
            c.append(Command(id: "cmd:theme-\(t.rawValue)", label: "Theme \(t.name)", symbol: "paintpalette.fill"))
        }
        for s in IslandStyle.allCases {
            c.append(Command(id: "cmd:style-\(s.rawValue)", label: "Style \(s.name)", symbol: "square.on.square"))
        }
        return c
    }

    static func symbol(for result: Backend.LaunchResult) -> String {
        switch result.kind {
        case "tab": return "terminal.fill"
        case "command": return commands.first { $0.id == result.id }?.symbol ?? "command"
        default: return "app.fill"
        }
    }

    /// Scans the usual app folders (off the main thread) and adds tabs and commands.
    static func build(tabs: [TermTab], completion: @escaping ([[String: Any]]) -> Void) {
        let tabItems: [[String: Any]] = tabs.map {
            ["id": "tab:\($0.id.uuidString)", "label": String($0.displayName.prefix(100)), "kind": "tab"]
        }
        let commandItems: [[String: Any]] = commands.map { ["id": $0.id, "label": $0.label, "kind": "command"] }
        DispatchQueue.global(qos: .utility).async {
            var apps: [[String: Any]] = []
            var seen = Set<String>()
            let fm = FileManager.default
            let dirs = ["/Applications", "/Applications/Utilities", "/System/Applications",
                        "/System/Applications/Utilities", fm.homeDirectoryForCurrentUser.path + "/Applications"]
            for dir in dirs {
                guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
                for name in names where name.hasSuffix(".app") {
                    let path = dir + "/" + name
                    let label = String(name.dropLast(4))
                    guard seen.insert(path).inserted, label.utf16.count <= 120,
                          label.contains(where: { $0.isLetter || $0.isNumber }) else { continue }
                    apps.append(["id": "app:" + path, "label": label, "kind": "app", "path": path])
                }
            }
            DispatchQueue.main.async { completion(apps + tabItems + commandItems) }
        }
    }
}
