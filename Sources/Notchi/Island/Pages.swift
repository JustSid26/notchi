import AppKit
import SwiftUI

// The island's pages beyond Home: Notes, Clipboard and Activity (screen time + workspaces).
// Their data lives in the Java backend; without it each page says how to start it.

enum IslandPage: String, CaseIterable, Identifiable {
    case home, notes, clipboard, activity
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .home: "house.fill"
        case .notes: "note.text"
        case .clipboard: "doc.on.clipboard.fill"
        case .activity: "chart.bar.fill"
        }
    }

    var title: String {
        switch self {
        case .home: "Home"
        case .notes: "Notes"
        case .clipboard: "Clipboard"
        case .activity: "Activity"
        }
    }
}

/// Home · Notes · Clipboard · Activity.
struct PageBar: View {
    @ObservedObject var c: IslandController

    var body: some View {
        HStack(spacing: 2) {
            ForEach(IslandPage.allCases) { p in
                Button {
                    withAnimation(c.spring) { c.page = p }
                } label: {
                    Image(systemName: p.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(c.page == p ? Color.black.opacity(0.85) : .white.opacity(0.6))
                        .frame(width: 26, height: 24)
                        .background(Capsule().fill(c.page == p ? Color.islandAccent : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(p.title)
            }
        }
        .padding(3)
        .background(Capsule().fill(.white.opacity(0.07)))
    }
}

/// Shown on a page when the backend isn't running (or is too old for this page).
struct BackendMissingView: View {
    let feature: String
    @ObservedObject var backend = Backend.shared

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "bolt.horizontal.circle").font(.system(size: 20)).foregroundStyle(.white.opacity(0.4))
            Text("\(feature) runs on Notchi's Java backend").font(.system(size: 12, weight: .semibold, design: .rounded))
            Text(backend.problem ?? (backend.connected
                    ? "The running backend is an older version. Quit it and Notchi will start the new one."
                    : "Starting it… (Settings → Java backend)"))
                .font(.system(size: 10)).foregroundStyle(.white.opacity(0.5)).multilineTextAlignment(.center)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A rounded text field for the bottom row of a page.
struct PageField: View {
    let symbol: String
    let placeholder: String
    @Binding var text: String
    var onSubmit: () -> Void = {}
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 12, weight: .bold)).foregroundStyle(Color.islandAccent)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
                .onSubmit(onSubmit)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.islandAccent.opacity(focused ? 0.6 : 0), lineWidth: 1))
        .onAppear { DispatchQueue.main.async { focused = true } }
    }
}

private func relativeDay(_ d: Date) -> String {
    let cal = Calendar.current
    let time = d.formatted(date: .omitted, time: .shortened)
    if cal.isDateInToday(d) { return "Today \(time)" }
    if cal.isDateInTomorrow(d) { return "Tomorrow \(time)" }
    if cal.isDateInYesterday(d) { return "Yesterday \(time)" }
    if let days = cal.dateComponents([.day], from: cal.startOfDay(for: .now), to: cal.startOfDay(for: d)).day, days > 0, days < 7 {
        return d.formatted(.dateTime.weekday(.wide)) + " \(time)"
    }
    return d.formatted(.dateTime.day().month(.abbreviated)) + " \(time)"
}

private func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }

private func ago(_ d: Date) -> String {
    let s = Int(Date().timeIntervalSince(d))
    if s < 60 { return "now" }
    if s < 3600 { return "\(s / 60)m ago" }
    if s < 86_400 { return "\(s / 3600)h ago" }
    return "\(s / 86_400)d ago"
}

// MARK: - Notes

final class NotesModel: ObservableObject {
    @Published var notes: [NoteItem] = []
    @Published var counts: [String: Int] = [:]
    @Published var filter: NoteKind?
    @Published var search = ""
    @Published var input = ""
    @Published var preview: NotePreview?
    @Published var flash: String?
    @Published var revealed: Set<String> = []
    private var previewWork: DispatchWorkItem?
    private var searchWork: DispatchWorkItem?

    func refresh() {
        Backend.shared.loadNotes(category: filter, query: search) { [weak self] notes, counts in
            self?.notes = notes
            if !counts.isEmpty { self?.counts = counts }
        }
    }

    func searchChanged() {
        searchWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.refresh() }
        searchWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: w)
    }

    func inputChanged() {
        previewWork?.cancel()
        let text = input
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { preview = nil; return }
        let w = DispatchWorkItem { [weak self] in
            Backend.shared.classify(text) { p in
                guard let self, self.input == text else { return }
                self.preview = p
            }
        }
        previewWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: w)
    }

    func save() {
        let text = input
        Backend.shared.createNote(text) { [weak self] note, error in
            guard let self else { return }
            if let note {
                self.input = ""
                self.preview = nil
                var msg = "Saved to \(note.kind.title)"
                if let due = note.dueAt { msg += " · \(relativeDay(due))" }
                if note.secret { msg += " · secret kept in Keychain" }
                self.show(msg)
                self.refresh()
            } else if let error {
                self.show(error)
            }
        }
    }

    func toggleDone(_ n: NoteItem) { Backend.shared.updateNote(n.id, ["done": !n.done]) { [weak self] in self?.refresh() } }
    func togglePin(_ n: NoteItem) { Backend.shared.updateNote(n.id, ["pinned": !n.pinned]) { [weak self] in self?.refresh() } }
    func move(_ n: NoteItem, to k: NoteKind) {
        if k == .credential {
            Backend.shared.moveToPasswords(n) { [weak self] in self?.refresh() }
        } else {
            Backend.shared.updateNote(n.id, ["category": k.rawValue]) { [weak self] in self?.refresh() }
        }
    }
    func delete(_ n: NoteItem) { Backend.shared.deleteNote(n.id) { [weak self] in self?.refresh() } }

    func copy(_ n: NoteItem) {
        guard n.secret else {
            ClipboardMonitor.shared.copy(n.text)
            return show("Copied")
        }
        guard let value = Backend.secret(of: n)?.secret else {
            return show("Couldn't read this password from your Keychain")
        }
        ClipboardMonitor.shared.copy(value, secret: true)
        show("Password copied · clears in a minute")
    }

    func displayText(_ n: NoteItem) -> String {
        guard n.secret, revealed.contains(n.id) else { return n.text }
        return Backend.secret(of: n)?.text ?? n.text
    }

    func show(_ message: String) {
        withAnimation(.easeOut(duration: 0.2)) { flash = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
            guard self?.flash == message else { return }
            withAnimation(.easeOut(duration: 0.2)) { self?.flash = nil }
        }
    }
}

struct NotesPage: View {
    @ObservedObject var model: NotesModel
    @ObservedObject var backend: Backend

    var body: some View {
        Group {
            if !backend.connected || !backend.supports("notes") {
                BackendMissingView(feature: "Notes")
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 6) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 5) {
                                chip(nil, "All", model.counts["all"] ?? 0)
                                ForEach(NoteKind.allCases) { k in
                                    if (model.counts[k.rawValue] ?? 0) > 0 || model.filter == k {
                                        chip(k, k.title, model.counts[k.rawValue] ?? 0)
                                    }
                                }
                            }
                        }
                        HStack(spacing: 4) {
                            Image(systemName: "magnifyingglass").font(.system(size: 9.5, weight: .semibold))
                            TextField("Search", text: $model.search).textFieldStyle(.plain).font(.system(size: 11))
                                .onChange(of: model.search) { _, _ in model.searchChanged() }
                        }
                        .padding(.horizontal, 7).frame(width: 120, height: 22)
                        .background(Capsule().fill(.white.opacity(0.07)))
                    }
                    if model.notes.isEmpty {
                        VStack(spacing: 4) {
                            Text(model.search.isEmpty ? "Write anything below" : "Nothing matches “\(model.search)”")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                            Text("Links, passwords, reminders (“call mom tomorrow 5pm”), to-dos, contacts and code are filed automatically.")
                                .font(.system(size: 10)).foregroundStyle(.white.opacity(0.5)).multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView(.vertical, showsIndicators: true) {
                            LazyVStack(alignment: .leading, spacing: 3) {
                                ForEach(model.notes) { n in NoteRow(note: n, model: model) }
                            }
                        }
                    }
                }
            }
        }
        .foregroundStyle(.white)
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(CardBackground())
        .onAppear { model.refresh() }
        .onChange(of: backend.connected) { _, on in if on { model.refresh() } }
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in model.refresh() }
    }

    private func chip(_ k: NoteKind?, _ title: String, _ count: Int) -> some View {
        let on = model.filter == k
        return Button {
            model.filter = k
            model.refresh()
        } label: {
            HStack(spacing: 4) {
                if let k { Image(systemName: k.symbol).font(.system(size: 8.5, weight: .bold)).foregroundStyle(on ? .black : k.tint) }
                Text(title).font(.system(size: 10, weight: .semibold, design: .rounded))
                Text("\(count)").font(.system(size: 9, weight: .bold).monospacedDigit()).opacity(0.6)
            }
            .foregroundStyle(on ? .black : .white.opacity(0.8))
            .padding(.horizontal, 8).padding(.vertical, 3.5)
            .background(Capsule().fill(on ? Color.islandAccent : .white.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }
}

struct NoteRow: View {
    let note: NoteItem
    @ObservedObject var model: NotesModel
    @State private var hover = false

    private var meta: String? {
        var parts: [String] = []
        if let due = note.dueAt {
            parts.append((due < Date() && !note.done ? "Overdue · " : "") + relativeDay(due))
        }
        if let u = note.urls.first {
            let host = URL(string: u.hasPrefix("http") ? u : "https://" + u)?.host() ?? u
            parts.append(host.replacingOccurrences(of: "www.", with: ""))
        }
        if note.secret { parts.append("hidden · kept in your Keychain") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: note.kind.symbol).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(note.kind.tint).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.displayText(note))
                    .font(.system(size: 11.5, weight: .medium, design: note.kind == .code ? .monospaced : .rounded))
                    .strikethrough(note.done, color: .white.opacity(0.5))
                    .foregroundStyle(.white.opacity(note.done ? 0.45 : 0.92))
                    .lineLimit(2)
                if let meta {
                    Text(meta).font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(note.dueAt.map { $0 < Date() && !note.done } == true ? Color(hex: 0xFF9F43) : .white.opacity(0.45))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if note.pinned && !hover {
                Image(systemName: "pin.fill").font(.system(size: 8)).foregroundStyle(.white.opacity(0.4))
            }
            if hover {
                HStack(spacing: 1) {
                    if note.kind == .todo || note.kind == .reminder {
                        action(note.done ? "arrow.uturn.backward" : "checkmark", note.done ? "Not done" : "Done") { model.toggleDone(note) }
                    }
                    if let u = note.urls.first, let url = URL(string: u.hasPrefix("http") ? u : "https://" + u) {
                        action("arrow.up.right.square", "Open") { NSWorkspace.shared.open(url) }
                    }
                    if note.secret {
                        action(model.revealed.contains(note.id) ? "eye.slash" : "eye", "Show") {
                            if model.revealed.contains(note.id) { model.revealed.remove(note.id) } else { model.revealed.insert(note.id) }
                        }
                    }
                    action("doc.on.doc", note.secret ? "Copy password" : "Copy") { model.copy(note) }
                    action(note.pinned ? "pin.slash" : "pin", note.pinned ? "Unpin" : "Pin") { model.togglePin(note) }
                    action("trash", "Delete") { model.delete(note) }
                }
            }
        }
        .padding(.horizontal, 7).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(hover ? 0.07 : 0.025)))
        .onHover { hover = $0 }
        .contextMenu {
            Menu("Move to") {
                ForEach(NoteKind.allCases.filter { $0 != note.kind }) { k in
                    Button(k.single) { model.move(note, to: k) }
                }
            }
            if !note.reasons.isEmpty {
                Section("Why \(note.kind.single.lowercased())") {
                    ForEach(note.reasons, id: \.self) { Text($0) }
                }
            }
            Button("Delete", role: .destructive) { model.delete(note) }
        }
        .help(note.reasons.isEmpty ? note.kind.single : "\(note.kind.single): " + note.reasons.joined(separator: ", "))
    }

    private func action(_ symbol: String, _ help: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.75))
                .frame(width: 22, height: 20).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Bottom row on the Notes page: write a note and see, live, where it will be filed.
struct NoteInputBar: View {
    @ObservedObject var model: NotesModel
    @ObservedObject var backend: Backend

    var body: some View {
        HStack(spacing: 8) {
            if let flash = model.flash {
                Text(flash).font(.system(size: 12, weight: .medium)).foregroundStyle(Color(hex: 0x4CD97B))
                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12)
                    .frame(maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.07)))
                    .transition(.opacity)
            } else {
                PageField(symbol: "square.and.pencil", placeholder: "Write anything — Notchi files it…",
                          text: $model.input, onSubmit: { model.save() })
                    .onChange(of: model.input) { _, _ in model.inputChanged() }
                    .overlay(alignment: .trailing) {
                        if let p = model.preview {
                            HStack(spacing: 4) {
                                Image(systemName: p.kind.symbol).font(.system(size: 9, weight: .bold))
                                Text(p.kind.single + (p.dueAt.map { " · " + relativeDay($0) } ?? "")
                                     + (p.hasSecret ? " · will be hidden" : ""))
                                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                            }
                            .foregroundStyle(.black.opacity(0.85))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(p.kind.tint))
                            .padding(.trailing, 8)
                            .help(p.reasons.joined(separator: "\n"))
                            .transition(.opacity.combined(with: .scale(scale: 0.9)))
                        }
                    }
                    .animation(.easeOut(duration: 0.15), value: model.preview)
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.flash)
        .disabled(!backend.connected)
    }
}

// MARK: - Clipboard

final class ClipsModel: ObservableObject {
    @Published var clips: [ClipItem] = []
    @Published var query = ""
    @Published var stats: [String: Any] = [:]
    @Published var flash: String?
    private var work: DispatchWorkItem?

    func refresh() {
        Backend.shared.loadClips(query: query) { [weak self] clips, stats in
            self?.clips = clips
            self?.stats = stats
        }
    }

    func queryChanged() {
        work?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.refresh() }
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: w)
    }

    func copy(_ c: ClipItem) {
        ClipboardMonitor.shared.copy(c.text)
        withAnimation { flash = "Copied — paste it anywhere" }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in withAnimation { self?.flash = nil } }
    }

    func pin(_ c: ClipItem) { Backend.shared.pinClip(c.id, !c.pinned) { [weak self] in self?.refresh() } }
    func delete(_ c: ClipItem) { Backend.shared.deleteClip(c.id) { [weak self] in self?.refresh() } }
    func clear() { Backend.shared.clearClips { [weak self] in self?.refresh() } }
}

struct ClipboardPage: View {
    @ObservedObject var model: ClipsModel
    @ObservedObject var backend: Backend
    @ObservedObject var settings: AppSettings

    private func stat(_ k: String) -> Int { (model.stats[k] as? NSNumber)?.intValue ?? 0 }

    var body: some View {
        Group {
            if !backend.connected || !backend.supports("clipboard") {
                BackendMissingView(feature: "Clipboard history")
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 6) {
                        Text("CLIPBOARD").font(.system(size: 9, weight: .bold)).tracking(1.2).foregroundStyle(.white.opacity(0.35))
                        Text(plural(stat("clips"), "clip") + " · " + plural(stat("repeatsMerged"), "repeat") + " merged · "
                             + plural(stat("secretsSkipped"), "password") + " skipped")
                            .font(.system(size: 9.5, weight: .medium)).foregroundStyle(.white.opacity(0.4)).lineLimit(1)
                        Spacer()
                        if !settings.recordClipboard {
                            Text("Paused in Settings").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Color(hex: 0xFF9F43))
                        }
                        if !model.clips.isEmpty {
                            Button("Clear") { model.clear() }.buttonStyle(.plain)
                                .font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                                .help("Remove everything except pinned clips")
                        }
                    }
                    if model.clips.isEmpty {
                        Text(model.query.isEmpty ? "Copy some text and it shows up here." : "Nothing you copied contains “\(model.query)”")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.6))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView(.vertical, showsIndicators: true) {
                            LazyVStack(alignment: .leading, spacing: 3) {
                                ForEach(model.clips) { c in ClipRow(clip: c, model: model) }
                            }
                        }
                    }
                }
            }
        }
        .foregroundStyle(.white)
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(CardBackground())
        .overlay(alignment: .bottom) {
            if let f = model.flash {
                Text(f).font(.system(size: 11, weight: .semibold)).foregroundStyle(.black)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(Color(hex: 0x4CD97B))).padding(8)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .onAppear { model.refresh() }
        .onChange(of: backend.connected) { _, on in if on { model.refresh() } }
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in
            if model.query.isEmpty { model.refresh() }
        }
    }
}

struct ClipRow: View {
    let clip: ClipItem
    @ObservedObject var model: ClipsModel
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: clip.kind.symbol).font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(clip.kind.tint).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(clip.text.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.system(size: 11.5, weight: .medium, design: clip.kind == .code ? .monospaced : .rounded))
                    .foregroundStyle(.white.opacity(0.92)).lineLimit(2)
                Text([clip.source, ago(clip.lastSeen), clip.copies > 1 ? "copied \(clip.copies)×" : nil]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 9.5, weight: .medium)).foregroundStyle(.white.opacity(0.42)).lineLimit(1)
            }
            Spacer(minLength: 4)
            if clip.pinned && !hover { Image(systemName: "pin.fill").font(.system(size: 8)).foregroundStyle(.white.opacity(0.4)) }
            if hover {
                Button { model.pin(clip) } label: { Image(systemName: clip.pinned ? "pin.slash" : "pin") }
                    .buttonStyle(.plain).help(clip.pinned ? "Unpin" : "Pin")
                Button { model.delete(clip) } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain).help("Delete")
            }
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.white.opacity(0.75))
        .padding(.horizontal, 7).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(hover ? 0.08 : 0.025)))
        .contentShape(Rectangle())
        .onTapGesture { model.copy(clip) }
        .onHover { hover = $0 }
        .help("Click to copy")
    }
}

/// Bottom row on the Clipboard page: search inside everything you copied.
struct ClipSearchBar: View {
    @ObservedObject var model: ClipsModel

    var body: some View {
        PageField(symbol: "magnifyingglass", placeholder: "Search everything you copied…", text: $model.query)
            .onChange(of: model.query) { _, _ in model.queryChanged() }
            .overlay(alignment: .trailing) {
                if !model.query.isEmpty {
                    Text("\(model.clips.count) found · suffix array")
                        .font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.white.opacity(0.4)).padding(.trailing, 12)
                }
            }
    }
}

// MARK: - Activity

final class ActivityModel: ObservableObject {
    @Published var summary: ActivitySummary?
    @Published var workspaces: [WorkspaceItem] = []
    @Published var failed = false

    func refresh() {
        Backend.shared.loadActivity { [weak self] s in
            if let s { self?.summary = s }
            self?.failed = s == nil
        }
        Backend.shared.loadWorkspaces { [weak self] w in self?.workspaces = w }
    }

    func open(_ w: WorkspaceItem) {
        for app in w.apps {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.id) else { continue }
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    func dismiss(_ w: WorkspaceItem) { Backend.shared.dismissWorkspace(w) { [weak self] in self?.refresh() } }
}

struct ActivityPage: View {
    @ObservedObject var model: ActivityModel
    @ObservedObject var backend: Backend
    @ObservedObject var settings: AppSettings
    var vertical = false

    var body: some View {
        Group {
            if !backend.connected || !backend.supports("activity") {
                BackendMissingView(feature: "Screen time")
            } else if let s = model.summary {
                let layout = vertical ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                                      : AnyLayout(HStackLayout(alignment: .top, spacing: 14))
                layout {
                    overview(s).frame(width: vertical ? nil : 230)
                    topApps(s)
                }
            } else if model.failed {
                Text("Couldn't load screen time. It'll retry in a moment.")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .foregroundStyle(.white)
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(CardBackground())
        .onAppear { model.refresh() }
        .onChange(of: backend.connected) { _, on in if on { model.refresh() } }
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in model.refresh() }
    }

    private func overview(_ s: ActivitySummary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text("TODAY").font(.system(size: 9, weight: .bold)).tracking(1.2).foregroundStyle(.white.opacity(0.35))
                if !settings.trackScreenTime {
                    Text("· paused").font(.system(size: 9, weight: .bold)).foregroundStyle(Color(hex: 0xFF9F43))
                }
            }
            Text(s.totalSeconds > 0 ? shortDuration(s.totalSeconds) : "—")
                .font(.system(size: 22, weight: .bold, design: .rounded)).monospacedDigit()
            if let h = s.busiestHour {
                Text("Busiest \(hourLabel(h))–\(hourLabel((h + 1) % 24))").font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.65))
            }
            if let f = s.focusApp, s.focusSeconds >= 60 {
                Text("Longest focus \(shortDuration(s.focusSeconds)) · \(f)").font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.65)).lineLimit(1)
            }
            Spacer(minLength: 4)
            HourlyBars(hourly: s.hourly, busiest: s.busiestHour).frame(height: 34)
        }
    }

    private func topApps(_ s: ActivitySummary) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if s.apps.isEmpty {
                Text("Use your Mac for a bit — apps you use show up here.")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
            }
            let top = s.apps.first?.seconds ?? 1
            ForEach(s.apps.prefix(vertical ? 8 : 4)) { a in
                HStack(spacing: 7) {
                    Image(nsImage: BundleIconCache.icon(for: a.id)).resizable().interpolation(.high).frame(width: 18, height: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(a.name).font(.system(size: 11, weight: .semibold, design: .rounded)).lineLimit(1)
                            Spacer()
                            Text(shortDuration(a.seconds)).font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                                .foregroundStyle(.white.opacity(0.7))
                        }
                        GeometryReader { g in
                            Capsule().fill(Color.islandAccent.opacity(0.8))
                                .frame(width: max(4, g.size.width * CGFloat(a.seconds) / CGFloat(max(top, 1))))
                        }
                        .frame(height: 3)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func hourLabel(_ h: Int) -> String {
        let hr = h % 12 == 0 ? 12 : h % 12
        return "\(hr) \(h < 12 ? "AM" : "PM")"
    }
}

struct HourlyBars: View {
    let hourly: [Int]
    let busiest: Int?

    var body: some View {
        let top = max(hourly.max() ?? 1, 1)
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<24, id: \.self) { h in
                let v = h < hourly.count ? hourly[h] : 0
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(h == busiest ? Color.islandAccent : .white.opacity(v > 0 ? 0.45 : 0.1))
                    .frame(height: max(2, 30 * CGFloat(v) / CGFloat(top)))
                    .help("\(h):00 · \(shortDuration(v))")
            }
        }
        .frame(maxWidth: .infinity, alignment: .bottomLeading)
    }
}

/// Bottom row on the Activity page: suggested workspaces, one click to open them all.
struct WorkspacesBar: View {
    @ObservedObject var model: ActivityModel

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.stack.3d.up.fill").font(.system(size: 12, weight: .bold)).foregroundStyle(Color.islandAccent)
            if model.workspaces.isEmpty {
                Text("Workspaces show up after a few days: apps you keep using together, one click to open.")
                    .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                Spacer(minLength: 0)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(model.workspaces) { w in WorkspaceChip(workspace: w, model: model) }
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.07)))
    }
}

struct WorkspaceChip: View {
    let workspace: WorkspaceItem
    @ObservedObject var model: ActivityModel
    @State private var hover = false

    var body: some View {
        Button { model.open(workspace) } label: {
            HStack(spacing: 6) {
                HStack(spacing: -6) {
                    ForEach(workspace.apps.prefix(4)) { a in
                        Image(nsImage: BundleIconCache.icon(for: a.id)).resizable().interpolation(.high).frame(width: 18, height: 18)
                    }
                }
                Text(workspace.name).font(.system(size: 10.5, weight: .semibold, design: .rounded)).lineLimit(1)
                Image(systemName: "arrow.up.forward").font(.system(size: 8.5, weight: .bold)).opacity(0.6)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(.white.opacity(hover ? 0.16 : 0.09)))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .contextMenu {
            Button("Open all \(workspace.apps.count) apps") { model.open(workspace) }
            Button("Not a workspace") { model.dismiss(workspace) }
        }
        .help(workspace.apps.map(\.name).joined(separator: ", ") + " · union–find over apps you use together")
    }
}
