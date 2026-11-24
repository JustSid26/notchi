import SwiftUI

/// Left-hand rail inside the island: up to 10 terminal tabs with Claude's live status (scrolls past ~6).
struct TerminalRail: View {
    @ObservedObject var terminals: TerminalTabs
    @State private var dragging: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            TerminalsHeader(terminals: terminals)
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: terminals.tabs.count > 6) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(terminals.tabs) { tab in
                            TerminalRow(tab: tab, terminals: terminals)
                                .reorderable(tab, terminals: terminals, dragging: $dragging)
                                .id(tab.id)
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                // Keep the ⌘↑/⌘↓ selection in view when there are more tabs than fit.
                .onChange(of: terminals.selectedID) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
        .padding(7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(CardBackground())
    }
}

/// Portrait version (left-edge dock): two columns.
struct TerminalGrid: View {
    @ObservedObject var terminals: TerminalTabs
    @State private var dragging: UUID?
    private let columns = [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TerminalsHeader(terminals: terminals)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 3) {
                ForEach(terminals.tabs) { tab in
                    TerminalRow(tab: tab, terminals: terminals)
                        .reorderable(tab, terminals: terminals, dragging: $dragging)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(CardBackground())
    }
}

/// A checklist of every open iTerm2 tab — tick to pin (up to 10), untick to unpin.
struct TerminalPickerMenu<Label: View>: View {
    @ObservedObject var terminals: TerminalTabs
    @ViewBuilder var label: () -> Label

    var body: some View {
        Menu {
            if !terminals.itermRunning {
                Text("iTerm2 isn't running")
            } else if terminals.permissionDenied {
                Text("Notchi needs permission to see your iTerm2 tabs")
                Button("Allow Notchi to control iTerm2…") { terminals.requestAccess() }
                Button("Open Automation settings…") { TerminalTabs.openAutomationSettings() }
            } else if let problem = terminals.accessProblem {
                Text(problem)
                Button("Try again") { terminals.requestAccess() }
            } else if terminals.openSessions.isEmpty {
                Text("Looking for iTerm2 tabs…")
            } else {
                Section("Pin up to \(TerminalTabs.maxTabs) tabs · \(terminals.tabs.count) pinned") {
                    ForEach(terminals.openSessions) { s in
                        let pinned = terminals.isPinned(s)
                        Toggle(isOn: Binding(get: { pinned }, set: { _ in terminals.togglePin(s) })) {
                            Text(s.name.isEmpty ? (s.tty as NSString).lastPathComponent : s.name)
                        }
                        .disabled(!pinned && terminals.isFull)
                    }
                }
            }
            Button("Refresh list") { terminals.poll(force: true) }
        } label: {
            label()
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onAppear {
            // First time: ask macOS for iTerm2 access (shows the Allow prompt), then list tabs.
            if terminals.openSessions.isEmpty { terminals.requestAccess() } else { terminals.poll(force: true) }
        }
    }
}

struct TerminalsHeader: View {
    @ObservedObject var terminals: TerminalTabs

    var body: some View {
        HStack(spacing: 4) {
            Text("TERMINALS").font(.system(size: 9, weight: .bold)).tracking(1.2)
                .foregroundStyle(.white.opacity(0.35))
            Text("\(terminals.tabs.count)/\(TerminalTabs.maxTabs)").font(.system(size: 8.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.25))
            Spacer(minLength: 0)
            TerminalPickerMenu(terminals: terminals) {
                Image(systemName: "checklist").font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.55))
            }
            .help("Choose which terminal tabs to show · ⌘↑/⌘↓ to switch between them")
        }
        .padding(.horizontal, 3)
        .frame(height: 14)
    }
}

struct TerminalRow: View {
    let tab: TermTab
    @ObservedObject var terminals: TerminalTabs
    @ObservedObject private var backend = Backend.shared
    @State private var hover = false

    /// The tab's colour in iTerm2 (right-click a tab → Tab Color), if it has one.
    private var tint: Color? { terminals.color(for: tab) }

    /// Same colour coding as iTerm2's tab bar; uncoloured tabs stay subtle.
    @ViewBuilder private func rowBackground(selected: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        if let tint {
            shape.fill(tint.opacity(selected ? 1 : 0.82))
                .overlay(shape.fill(Color.white.opacity(hover ? 0.1 : 0)))
        } else {
            shape.fill(selected ? Color.islandAccent.opacity(0.22) : Color.white.opacity(hover ? 0.07 : 0.035))
        }
    }

    var body: some View {
        let state = terminals.state(of: tab)
        let selected = terminals.selectedID == tab.id
        HStack(spacing: 7) {
            ClaudeStatusGlyph(state: state).frame(width: 14, height: 14)
            Text(tab.displayName)
                .font(.system(size: 11.5, weight: selected ? .semibold : .medium, design: .rounded))
                .foregroundStyle(.white.opacity(state == .closed ? 0.35 : 0.9))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 2)
            if hover {
                Button { terminals.focus(tab) } label: {
                    Image(systemName: "arrow.up.forward.app").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
                .help("Open in \(tab.app)")
            } else {
                StatusDetail(state: state, eta: backend.eta(for: tab))
            }
        }
        .padding(.horizontal, 7)
        .frame(height: 26)
        .background(rowBackground(selected: selected))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(selected ? (tint == nil ? Color.islandAccent.opacity(0.6) : Color.white.opacity(0.7)) : .clear,
                              lineWidth: 1.2)
        )
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { terminals.toggleSelect(tab) } }
        .onHover { hover = $0 }
        .contextMenu {
            Button("Open in \(tab.app)") { terminals.focus(tab) }
            Button("Remove from island", role: .destructive) { terminals.remove(tab) }
        }
        .help(selected ? "Showing this tab's conversation · typing below sends to it"
                       : "Click to see this tab's conversation and send prompts to it")
    }
}

/// Elapsed time while working (plus the usual run time when the Java backend knows it),
/// how long it took when done.
struct StatusDetail: View {
    let state: ClaudeState
    var eta: Backend.Eta? = nil

    var body: some View {
        switch state {
        case .working(let since):
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                if let eta {
                    Text(Self.fmt(ctx.date.timeIntervalSince(since)))
                    + Text(" / ~\(Self.fmt(eta.p50))").foregroundStyle(.white.opacity(0.45))
                } else {
                    Text(Self.fmt(ctx.date.timeIntervalSince(since)))
                }
            }
            .font(.system(size: 9.5, weight: .medium).monospacedDigit())
            .foregroundStyle(Color.islandAccent.opacity(0.9))
            .help(eta.map { "Usually done in ~\(Self.fmt($0.p50)); 90% of runs within \(Self.fmt($0.p90)) (\($0.count) runs, \($0.scope)). Percentiles by randomized Quickselect in the Java backend." } ?? "")
        case .done(_, let took) where took > 0:
            Text(Self.fmt(took)).font(.system(size: 9.5, weight: .medium).monospacedDigit())
                .foregroundStyle(Color(hex: 0x4CD97B).opacity(0.8))
        case .attention:
            Text("needs you").font(.system(size: 9, weight: .semibold)).foregroundStyle(Color(hex: 0xFFB340))
        default:
            EmptyView()
        }
    }

    static func fmt(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Spinning ring while Claude works, ✓ when done, ! when it needs you.
struct ClaudeStatusGlyph: View {
    let state: ClaudeState

    var body: some View {
        switch state {
        case .working:
            TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                ZStack {
                    Circle().stroke(Color.white.opacity(0.14), lineWidth: 2)
                    Circle()
                        .trim(from: 0, to: 0.28 + 0.12 * sin(t * 2.4))
                        .stroke(Color.islandAccent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(t.truncatingRemainder(dividingBy: 1) * 360))
                }
                .padding(1)
            }
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(Color(hex: 0x4CD97B))
                .transition(.scale.combined(with: .opacity))
        case .attention:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(Color(hex: 0xFFB340))
                .symbolEffect(.pulse)
        case .idle:
            Circle().fill(Color.white.opacity(0.28)).frame(width: 6, height: 6)
        case .closed:
            Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 1).frame(width: 7, height: 7)
        }
    }
}

// MARK: - Drag to reorder

private struct TabDropDelegate: DropDelegate {
    let target: TermTab
    let terminals: TerminalTabs
    @Binding var dragging: UUID?

    func dropEntered(info: DropInfo) {
        guard let id = dragging, id != target.id else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { terminals.move(id, to: target.id) }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { dragging = nil; return true }
}

extension View {
    /// Rows can be dragged up and down to reorder the pinned tabs.
    func reorderable(_ tab: TermTab, terminals: TerminalTabs, dragging: Binding<UUID?>) -> some View {
        self
            .opacity(dragging.wrappedValue == tab.id ? 0.35 : 1)
            .onDrag {
                dragging.wrappedValue = tab.id
                return NSItemProvider(object: tab.id.uuidString as NSString)
            }
            .onDrop(of: [.text], delegate: TabDropDelegate(target: tab, terminals: terminals, dragging: dragging))
    }
}
