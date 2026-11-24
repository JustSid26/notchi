import AppKit
import Carbon.HIToolbox
import IOKit.ps
import SwiftUI

// MARK: - Battery

final class BatteryMonitor: ObservableObject {
    @Published private(set) var level = 100
    @Published private(set) var isCharging = false
    @Published private(set) var isPluggedIn = false
    @Published private(set) var hasBattery = false
    /// macOS's estimate while charging; nil while it's still working it out.
    @Published private(set) var minutesToFull: Int?
    private var source: CFRunLoopSource?

    init() {
        refresh()
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        if let s = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let me = Unmanaged<BatteryMonitor>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async { me.refresh() }
        }, ctx)?.takeRetainedValue() {
            source = s
            CFRunLoopAddSource(CFRunLoopGetMain(), s, .defaultMode)
        }
    }

    func refresh() {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  d["Type"] as? String == "InternalBattery" else { continue }
            hasBattery = true
            let cur = d["Current Capacity"] as? Int ?? 0
            let max = d["Max Capacity"] as? Int ?? 100
            level = max > 0 ? Int((Double(cur) / Double(max) * 100).rounded()) : cur
            isCharging = d["Is Charging"] as? Bool ?? false
            isPluggedIn = d["Power Source State"] as? String == "AC Power"
            let ttf = d[kIOPSTimeToFullChargeKey] as? Int ?? -1
            minutesToFull = isCharging && ttf > 0 ? ttf : nil
        }
    }

    /// Percentage points still to go before 100%.
    var toFull: Int { max(0, 100 - level) }

    /// "16% to go · full in 1h 12m"
    var chargeDetail: String {
        guard level < 100 else { return "Fully charged" }
        var s = "\(toFull)% to go"
        if let m = minutesToFull { s += " · full in " + Self.duration(m) }
        return s
    }

    static func duration(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

    var symbol: String {
        switch level {
        case 88...: "battery.100"
        case 63..<88: "battery.75"
        case 38..<63: "battery.50"
        case 13..<38: "battery.25"
        default: "battery.0"
        }
    }
}

// MARK: - Global hotkey (Carbon — no Accessibility permission needed)

final class HotKey {
    static let shared = HotKey()
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var action: (() -> Void)?
    private(set) var label = "⌥Space"

    func register(action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotKey.shared.action?() }
            return noErr
        }, 1, &spec, nil, &handler)

        let id = EventHotKeyID(signature: OSType(0x4E54_4348), id: 1) // 'NTCH'
        var status = RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey), id,
                                         GetApplicationEventTarget(), 0, &ref)
        if status != noErr {
            status = RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey | controlKey), id,
                                         GetApplicationEventTarget(), 0, &ref)
            label = status == noErr ? "⌃⌥Space" : "—"
        }
    }
}

// MARK: - Live activities (pushed via notchi:// URLs, e.g. from the `island` CLI)

struct LiveActivity: Identifiable, Equatable {
    enum State: String { case running, done, failed, attention }
    let id: String
    var title: String
    var subtitle: String?
    var progress: Double?
    var state: State
    var symbol: String
    var tint: Color
    var updated: Date
    var expires: Date?
    /// Tinted with the theme accent ("accent"/"claude" tints) — recoloured when the theme changes.
    var followsTheme = false
    /// The tint as it was sent ("blue", "#ff8800", "accent"…), for the Java backend.
    var tintName: String?

    var rank: Int {
        switch state {
        case .attention: 3
        case .running: 2
        case .failed: 1
        case .done: 0
        }
    }
}

final class ActivityCenter: ObservableObject {
    @Published private(set) var items: [LiveActivity] = []
    /// Bumped by `end(id:)`, so a push that was still waiting for the backend is dropped.
    private var generations: [String: Int] = [:]
    var onEvent: ((LiveActivity) -> Void)?
    private var timer: Timer?

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.purge() }
    }

    var primary: LiveActivity? {
        let order = Backend.shared.liveOrder
        if !order.isEmpty, let first = ordered(by: order).first { return first }
        return items.max { ($0.rank, $0.updated) < ($1.rank, $1.updated) }
    }

    func push(_ q: [String: String]) {
        // Double("nan") parses; NaN/∞ would poison sorting and JSON, so ignore non-finite values.
        let finite: (String?) -> Double? = { $0.flatMap(Double.init).flatMap { $0.isFinite ? $0 : nil } }
        let progress = finite(q["progress"]).map { min(max($0, 0), 1) }
        let state = LiveActivity.State(rawValue: q["state"] ?? "") ?? ((progress ?? 0) >= 1 ? .done : .running)
        let id = q["id"] ?? q["title"] ?? UUID().uuidString
        let defaultTTL: Double = state == .running ? 1800 : (state == .attention ? 30 : 6)
        let ttl = finite(q["ttl"]) ?? defaultTTL
        let symbol = q["icon"] ?? {
            switch state {
            case .running: "gearshape.2.fill"
            case .done: "checkmark.circle.fill"
            case .failed: "xmark.octagon.fill"
            case .attention: "bell.badge.fill"
            }
        }()
        let followsTheme = ["accent", "claude"].contains(q["tint"]?.lowercased() ?? "")
        let tint = (followsTheme ? Color.islandAccent : nil) ?? parseColor(q["tint"]) ?? {
            switch state {
            case .running: Color(hex: 0x5AA9FF)
            case .done: Color(hex: 0x4CD97B)
            case .failed: Color(hex: 0xFF5A5F)
            case .attention: Color(hex: 0xFFB340)
            }
        }()
        var a = LiveActivity(id: id, title: q["title"] ?? id, subtitle: q["subtitle"], progress: progress,
                             state: state, symbol: symbol, tint: tint, updated: Date(),
                             expires: ttl > 0 ? Date().addingTimeInterval(ttl) : nil)
        a.followsTheme = followsTheme
        a.tintName = q["tint"]
        let quiet = q["quiet"] == "1"

        // With the Java backend running, it decides first: its Bloom filter + event log drop
        // events it has already seen (a retried webhook, a hook that fires twice…), and its heap
        // orders the queue. Without it, the event is applied right here as before.
        guard Backend.shared.connected else { return apply(a, quiet: quiet) }
        var fields = Self.fields(for: a, ttl: ttl)
        if let e = q["event"], !e.isEmpty { fields["eventId"] = String(e.prefix(256)) }
        let generation = generations[id, default: 0]
        Backend.shared.pushEvent(fields) { [weak self] verdict in
            // Dropped as a repeat, or ended while the push was on its way.
            guard let self, verdict != "duplicate", self.generations[id, default: 0] == generation else { return }
            var fresh = a
            fresh.updated = Date()
            fresh.expires = ttl > 0 ? Date().addingTimeInterval(ttl) : nil
            self.apply(fresh, quiet: quiet)
        }
    }

    private func apply(_ a: LiveActivity, quiet: Bool) {
        if let i = items.firstIndex(where: { $0.id == a.id }) {
            let old = items[i]
            items[i] = a
            if (old.state != a.state || old.title != a.title) && !quiet { onEvent?(a) }
        } else {
            items.append(a)
            if !quiet { onEvent?(a) }
        }
    }

    func end(id: String) {
        items.removeAll { $0.id == id }
        generations[id, default: 0] += 1   // a push for this id still in flight must not bring it back
        Backend.shared.endActivity(id)
    }

    /// Most urgent first: in the backend heap's order when it's connected, otherwise sorted here
    /// (needs-you, running, failed, done; newest first). Anything the backend hasn't
    /// acknowledged yet goes after the ordered ones.
    func ordered(by order: [String]) -> [LiveActivity] {
        let local = items.sorted { ($0.rank, $0.updated) > ($1.rank, $1.updated) }
        guard !order.isEmpty else { return local }
        var position: [String: Int] = [:]
        for (i, id) in order.enumerated() where position[id] == nil { position[id] = i }
        return local.enumerated().sorted { x, y in
            switch (position[x.element.id], position[y.element.id]) {
            case let (a?, b?): return a < b
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return x.offset < y.offset
            }
        }.map(\.element)
    }

    /// The backend just (re)connected: send it what's on screen so both agree. Oldest first, so
    /// the backend's "newest first" order matches what's shown.
    func resync() {
        let now = Date()
        for a in items.sorted(by: { $0.updated < $1.updated }) {
            let ttl = a.expires.map { max(1, $0.timeIntervalSince(now)) } ?? 0
            var fields = Self.fields(for: a, ttl: ttl)
            fields["eventId"] = "sync:\(a.id):\(a.updated.timeIntervalSince1970)"
            Backend.shared.pushEvent(fields) { _ in }
        }
        Backend.shared.refreshLiveOrder()
    }

    private static func fields(for a: LiveActivity, ttl: Double) -> [String: Any] {
        var f: [String: Any] = ["id": String(a.id.prefix(200)), "title": String(a.title.prefix(200)),
                                "state": a.state.rawValue, "icon": String(a.symbol.prefix(100)),
                                "ttl": min(max(ttl, 0), 7 * 24 * 3600)]
        if let s = a.subtitle { f["subtitle"] = String(s.prefix(300)) }
        if let p = a.progress { f["progress"] = p }
        if let t = a.tintName, !t.isEmpty { f["tint"] = String(t.prefix(40)) }
        return f
    }

    /// Theme changed: recolour the activities that follow the accent.
    func retint(_ accent: Color) {
        guard items.contains(where: \.followsTheme) else { return }
        for i in items.indices where items[i].followsTheme { items[i].tint = accent }
    }

    private func purge() {
        let now = Date()
        if items.contains(where: { ($0.expires ?? .distantFuture) < now }) {
            items.removeAll { ($0.expires ?? .distantFuture) < now }
        }
    }
}

func parseColor(_ s: String?) -> Color? {
    guard let s = s?.lowercased(), !s.isEmpty else { return nil }
    let named: [String: UInt32] = ["blue": 0x5AA9FF, "green": 0x4CD97B, "red": 0xFF5A5F, "orange": 0xFF9F43,
                                   "yellow": 0xFFD60A, "purple": 0xB18CFF, "pink": 0xFF7EB6, "teal": 0x40E0D0,
                                   "gray": 0xA0A0A8, "white": 0xFFFFFF, "claude": 0xD97757]
    if let v = named[s] { return Color(hex: v) }
    let hex = s.hasPrefix("#") ? String(s.dropFirst()) : s
    guard hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
    return Color(hex: v)
}
