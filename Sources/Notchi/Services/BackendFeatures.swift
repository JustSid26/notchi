import AppKit
import SwiftUI

// Notes, clipboard history, screen time and workspaces. All of them live in the Java backend;
// this file holds the app-side models and the calls that fetch and change them.

// MARK: - Models

/// How Notchi files a note (or a copied clip), with its icon, name and colour.
enum NoteKind: String, CaseIterable, Identifiable {
    case reminder, todo, link, credential, contact, code, idea, note
    var id: String { rawValue }

    init(_ raw: String?) { self = NoteKind(rawValue: raw ?? "") ?? .note }

    var symbol: String {
        switch self {
        case .credential: "key.fill"
        case .reminder: "bell.fill"
        case .link: "link"
        case .contact: "person.crop.circle.fill"
        case .todo: "checklist"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .idea: "lightbulb.fill"
        case .note: "note.text"
        }
    }

    var title: String {
        switch self {
        case .credential: "Passwords"
        case .reminder: "Reminders"
        case .link: "Links"
        case .contact: "Contacts"
        case .todo: "To-dos"
        case .code: "Code"
        case .idea: "Ideas"
        case .note: "Notes"
        }
    }

    var single: String {
        switch self {
        case .credential: "Password"
        case .reminder: "Reminder"
        case .link: "Link"
        case .contact: "Contact"
        case .todo: "To-do"
        case .code: "Code"
        case .idea: "Idea"
        case .note: "Note"
        }
    }

    var tint: Color {
        switch self {
        case .credential: Color(hex: 0xFFD60A)
        case .reminder: Color(hex: 0xFF9F43)
        case .link: Color(hex: 0x5AA9FF)
        case .contact: Color(hex: 0x4CD97B)
        case .todo: Color(hex: 0xB18CFF)
        case .code: Color(hex: 0x40E0D0)
        case .idea: Color(hex: 0xFFB340)
        case .note: Color(hex: 0xA0A0A8)
        }
    }
}

struct NoteItem: Identifiable, Equatable {
    let id: String
    let text: String
    let kind: NoteKind
    let reasons: [String]
    let urls: [String]
    let dueAt: Date?
    let done: Bool
    let pinned: Bool
    let secret: Bool
    let updated: Date

    init?(_ d: [String: Any]) {
        guard let id = d["id"] as? String, let text = d["text"] as? String else { return nil }
        self.id = id
        self.text = text
        kind = NoteKind(d["category"] as? String)
        reasons = d["reasons"] as? [String] ?? []
        urls = d["urls"] as? [String] ?? []
        dueAt = (d["dueAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        done = d["done"] as? Bool ?? false
        pinned = d["pinned"] as? Bool ?? false
        secret = d["secret"] as? Bool ?? false
        updated = Date(timeIntervalSince1970: ((d["updated"] as? NSNumber)?.doubleValue ?? 0) / 1000)
    }
}

/// What the note being typed would be filed as (shown live under the field).
struct NotePreview: Equatable {
    let kind: NoteKind
    let reasons: [String]
    let dueAt: Date?
    let hasSecret: Bool
}

struct ClipItem: Identifiable, Equatable {
    let id: String
    let text: String
    let kind: NoteKind
    let source: String?
    let lastSeen: Date
    let copies: Int
    let pinned: Bool

    init?(_ d: [String: Any]) {
        guard let id = d["id"] as? String, let text = d["text"] as? String else { return nil }
        self.id = id
        self.text = text
        kind = NoteKind(d["kind"] as? String)
        source = d["source"] as? String
        lastSeen = Date(timeIntervalSince1970: ((d["lastSeen"] as? NSNumber)?.doubleValue ?? 0) / 1000)
        copies = (d["copies"] as? NSNumber)?.intValue ?? 1
        pinned = d["pinned"] as? Bool ?? false
    }
}

struct AppUsage: Identifiable, Equatable {
    let id: String       // bundle id
    let name: String
    let seconds: Int

    init?(_ d: [String: Any]) {
        guard let id = d["app"] as? String else { return nil }
        self.id = id
        name = d["name"] as? String ?? id
        seconds = (d["seconds"] as? NSNumber)?.intValue ?? 0
    }
}

struct ActivitySummary: Equatable {
    let totalSeconds: Int
    let hourly: [Int]
    let busiestHour: Int?
    let apps: [AppUsage]
    let focusApp: String?
    let focusSeconds: Int

    init(_ d: [String: Any]) {
        totalSeconds = (d["totalSeconds"] as? NSNumber)?.intValue ?? 0
        hourly = (d["hourly"] as? [NSNumber])?.map(\.intValue) ?? Array(repeating: 0, count: 24)
        busiestHour = (d["busiestHour"] as? NSNumber)?.intValue
        apps = (d["apps"] as? [[String: Any]] ?? []).compactMap(AppUsage.init)
        let focus = d["longestFocus"] as? [String: Any]
        focusApp = focus?["name"] as? String
        focusSeconds = (focus?["seconds"] as? NSNumber)?.intValue ?? 0
    }
}

struct WorkspaceItem: Identifiable, Equatable {
    let id: String       // signature
    let name: String
    let apps: [AppUsage]

    init?(_ d: [String: Any]) {
        guard let sig = d["signature"] as? String, let name = d["name"] as? String else { return nil }
        id = sig
        self.name = name
        apps = (d["apps"] as? [[String: Any]] ?? []).compactMap(AppUsage.init)
    }
}

/// Short durations for the island: "3h 12m", "52m", "40s".
func shortDuration(_ seconds: Int) -> String {
    let h = seconds / 3600, m = seconds / 60 % 60
    if h > 0 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
    if m > 0 { return "\(m)m" }
    return "\(seconds)s"
}

/// App icons by bundle id, loaded once.
enum BundleIconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(for bundleID: String) -> NSImage {
        if let i = cache[bundleID] { return i }
        let i: NSImage
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            i = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            i = NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
        }
        cache[bundleID] = i
        return i
    }
}

// MARK: - Calls

extension Backend {
    static var utcOffsetMinutes: Int { TimeZone.current.secondsFromGMT() / 60 }

    // Notes

    /// Live preview while typing (debounced by the caller).
    func classify(_ text: String, done: @escaping (NotePreview?) -> Void) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard connected, !t.isEmpty, t.count <= 5_000 else { return done(nil) }
        call("POST", "/api/notes/classify", json: ["text": t, "tz": Self.utcOffsetMinutes]) { r in
            guard let r, r.ok else { return done(nil) }
            done(NotePreview(kind: NoteKind(r.json["category"] as? String), reasons: r.json["reasons"] as? [String] ?? [],
                             dueAt: (r.json["dueAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) },
                             hasSecret: r.json["hasSecret"] as? Bool ?? false))
        }
    }

    /// Saves a note. A password or key is kept in the macOS Keychain; the backend only stores
    /// the redacted text. The original goes into the Keychain *before* the request (under an id
    /// we choose), so a lost reply can't lose a secret.
    func createNote(_ text: String, done: @escaping (NoteItem?, String?) -> Void) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return done(nil, nil) }
        guard connected else { return done(nil, "Start the Java backend to save notes") }
        let id = UUID().uuidString.lowercased()
        Self.storeSecret(id: id, text: t, secret: "")
        call("POST", "/api/notes", json: ["id": id, "text": t, "tz": Self.utcOffsetMinutes]) { r in
            guard let r else { return done(nil, "Backend not reachable") }
            guard r.ok, let note = NoteItem(r.json) else {
                Keychain.delete(account: "note-\(id)")
                return done(nil, r.error)
            }
            if !note.secret {
                Keychain.delete(account: "note-\(id)")      // nothing to keep
            } else {
                let spans = (r.json["secretSpans"] as? [[NSNumber]] ?? []).compactMap { p -> String? in
                    guard p.count == 2 else { return nil }
                    let u = Array(t.utf16)
                    let a = p[0].intValue, b = p[1].intValue
                    guard a >= 0, b <= u.count, a < b else { return nil }
                    return String(utf16CodeUnits: Array(u[a..<b]), count: b - a)
                }
                Self.storeSecret(id: note.id, text: t, secret: spans.joined(separator: " "))
            }
            done(note, nil)
        }
    }

    static func storeSecret(id: String, text: String, secret: String) {
        if let data = try? JSONSerialization.data(withJSONObject: ["text": text, "secret": secret]),
           let json = String(data: data, encoding: .utf8) {
            Keychain.set(json, account: "note-\(id)")
        }
    }

    /// Files a note under Passwords by hand: the whole text goes to the Keychain first, then the
    /// backend hides it.
    func moveToPasswords(_ note: NoteItem, done: @escaping () -> Void) {
        if !note.secret { Self.storeSecret(id: note.id, text: note.text, secret: note.text) }
        updateNote(note.id, ["category": "credential"], done: done)
    }

    /// The hidden value of a password note (from the Keychain), or nil.
    static func secret(of note: NoteItem) -> (text: String, secret: String)? {
        guard let json = Keychain.get(account: "note-\(note.id)"),
              let d = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String],
              let text = d["text"] else { return nil }
        return (text, d["secret"].flatMap { $0.isEmpty ? nil : $0 } ?? text)
    }

    func loadNotes(category: NoteKind?, query: String, done: @escaping ([NoteItem], [String: Int]) -> Void) {
        guard connected else { return done([], [:]) }
        var q: [String: String] = ["limit": "300"]
        if let category { q["category"] = category.rawValue }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { q["q"] = trimmed }
        call("GET", "/api/notes", query: q) { r in
            guard let r, r.ok else { return done([], [:]) }
            let notes = (r.json["notes"] as? [[String: Any]] ?? []).compactMap(NoteItem.init)
            let counts = (r.json["counts"] as? [String: NSNumber] ?? [:]).mapValues(\.intValue)
            done(notes, counts)
        }
    }

    func updateNote(_ id: String, _ fields: [String: Any], done: @escaping () -> Void) {
        call("PATCH", "/api/notes/" + Self.segment(id), json: fields) { _ in done() }
    }

    func deleteNote(_ id: String, done: @escaping () -> Void) {
        Keychain.delete(account: "note-\(id)")
        call("DELETE", "/api/notes/" + Self.segment(id)) { _ in done() }
    }

    func dueReminders(done: @escaping ([NoteItem]) -> Void) {
        guard connected else { return done([]) }
        call("GET", "/api/notes/due") { r in
            done((r?.json["notes"] as? [[String: Any]] ?? []).compactMap(NoteItem.init))
        }
    }

    // Clipboard

    func addClip(_ text: String, source: String?) {
        guard connected else { return }
        var body: [String: Any] = ["text": text]
        if let source { body["source"] = String(source.prefix(200)) }
        call("POST", "/api/clipboard", json: body)
    }

    func loadClips(query: String, done: @escaping ([ClipItem], [String: Any]) -> Void) {
        guard connected else { return done([], [:]) }
        var q: [String: String] = ["limit": "200"]
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { q["q"] = trimmed }
        call("GET", "/api/clipboard", query: q) { r in
            guard let r, r.ok else { return done([], [:]) }
            done((r.json["clips"] as? [[String: Any]] ?? []).compactMap(ClipItem.init), r.json["stats"] as? [String: Any] ?? [:])
        }
    }

    func pinClip(_ id: String, _ pinned: Bool, done: @escaping () -> Void) {
        call("PATCH", "/api/clipboard/" + Self.segment(id), json: ["pinned": pinned]) { _ in done() }
    }

    func deleteClip(_ id: String, done: @escaping () -> Void) {
        call("DELETE", "/api/clipboard/" + Self.segment(id)) { _ in done() }
    }

    func clearClips(done: @escaping () -> Void) {
        call("DELETE", "/api/clipboard") { _ in done() }
    }

    // Screen time & workspaces

    /// Sends finished app spans; `done(true)` once the backend has them.
    func sendSpans(_ spans: [[String: Any]], done: @escaping (Bool) -> Void) {
        guard connected, !spans.isEmpty else { return done(false) }
        call("POST", "/api/activity/spans", json: ["tz": Self.utcOffsetMinutes, "spans": spans]) { r in
            // Accepted, or rejected for good (400: e.g. a clock jump) → done with this batch.
            // Unreachable, 401/404 (an older backend) or 5xx (disk full…) → keep it and retry.
            guard let r else { return done(false) }
            done(r.ok || r.status == 400)
        }
    }

    func loadActivity(done: @escaping (ActivitySummary?) -> Void) {
        guard connected else { return done(nil) }
        call("GET", "/api/activity/today", query: ["tz": String(Self.utcOffsetMinutes)]) { r in
            guard let r, r.ok else { return done(nil) }
            done(ActivitySummary(r.json))
        }
    }

    func loadWorkspaces(done: @escaping ([WorkspaceItem]) -> Void) {
        guard connected else { return done([]) }
        call("GET", "/api/workspaces", query: ["tz": String(Self.utcOffsetMinutes)]) { r in
            done((r?.json["workspaces"] as? [[String: Any]] ?? []).compactMap(WorkspaceItem.init))
        }
    }

    func dismissWorkspace(_ w: WorkspaceItem, done: @escaping () -> Void) {
        call("POST", "/api/workspaces/dismiss", json: ["apps": w.apps.map(\.id)]) { _ in done() }
    }
}
