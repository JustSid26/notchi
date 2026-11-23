import SwiftUI

struct ExpandedView: View {
    @ObservedObject var c: IslandController
    @ObservedObject var media: NowPlayingService
    @ObservedObject var activities: ActivityCenter
    @ObservedObject var claude: ClaudeSession
    @ObservedObject var battery: BatteryMonitor
    @ObservedObject var apps: AppShelf
    @ObservedObject var settings: AppSettings
    @ObservedObject var terminals: TerminalTabs
    @ObservedObject var transcript: TranscriptStore

    private var hPad: CGFloat { settings.dock == .notch ? 18 : 16 }

    var body: some View {
        let header = c.headerHeight
        // The cat peeks over the top edge of the cards, paws on the "ledge".
        let catHeight = max(header, 32) + 4
        let k = catHeight / CatRenderer.peekLedge * 0.86
        let catW = CatRenderer.peekUnitW * k
        let catX: CGFloat = hPad + 6
        let catY = header + 5 - CatRenderer.peekLedge * k
        let hasTabs = !terminals.tabs.isEmpty

        VStack(spacing: 10) {
            HeaderRow(c: c, battery: battery, settings: settings, terminals: terminals, leadingInset: settings.showCat ? catW + 8 : 0)
                .frame(height: header)
            if settings.dock == .notch {
                // Landscape: hangs from the notch. Terminal tabs get a rail on the left.
                HStack(alignment: .top, spacing: 10) {
                    if hasTabs {
                        TerminalRail(terminals: terminals)
                            .frame(width: Metrics.railWidth, height: 84 + 10 + 56 + 10 + 38)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                    VStack(spacing: 10) {
                        HStack(spacing: 10) {
                            NowPlayingCard(media: media).frame(maxWidth: .infinity)
                            ActivitiesCard(activities: activities, battery: battery).frame(width: 200)
                        }
                        .frame(height: 84)
                        HStack(spacing: 8) {
                            AppsRow(c: c, apps: apps)
                            IslandControls(c: c, settings: settings, terminals: terminals)
                                .padding(.horizontal, 6)
                                .frame(maxHeight: .infinity)
                                .background(CardBackground())
                        }
                        .frame(height: 56)
                        ClaudeBar(c: c, claude: claude, terminals: terminals).frame(height: 38)
                    }
                    .frame(width: Metrics.expandedWidth(.notch) - 2 * hPad)
                }
            } else {
                // Portrait: docked to the left edge.
                NowPlayingCard(media: media, vertical: true).frame(height: 156)
                ActivitiesCard(activities: activities, battery: battery, maxRows: 1).frame(height: 76)
                if hasTabs {
                    TerminalGrid(terminals: terminals).frame(height: Metrics.terminalGridHeight(terminals.tabs.count))
                }
                AppsGrid(c: c, apps: apps).frame(height: 116)
                ClaudeBar(c: c, claude: claude, terminals: terminals).frame(height: 38)
            }
            if let tab = terminals.selected {
                // Clicking a terminal tab grows the island to show that tab's conversation.
                TranscriptPanel(tab: tab, store: transcript, terminals: terminals)
                    .frame(height: Metrics.transcriptHeight(settings.dock))
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else if claude.hasAnswer {
                AnswerPanel(claude: claude)
                    .frame(height: Metrics.answerHeight)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, hPad)
        .frame(width: c.expandedWidth, height: c.expandedHeight, alignment: .top)
        .overlay(alignment: .topLeading) {
            if settings.showCat {
                let islandMinX = settings.dock == .notch ? c.islandCenterX - c.expandedWidth / 2 : 0
                PeekCatView(engine: c.cat, settings: settings, height: catHeight,
                            centerX: islandMinX + catX + catW / 2,
                            mouseX: { c.islandMouse.x })
                    .offset(x: catX, y: catY)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(c.spring, value: claude.hasAnswer)
        .animation(c.spring, value: terminals.selectedID)
        .animation(c.spring, value: terminals.tabs.count)
    }
}

// MARK: - Header

struct HeaderRow: View {
    @ObservedObject var c: IslandController
    @ObservedObject var battery: BatteryMonitor
    @ObservedObject var settings: AppSettings
    @ObservedObject var terminals: TerminalTabs
    var leadingInset: CGFloat

    var body: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: leadingInset, height: 1)
            if leadingInset == 0 {
                Image(systemName: "pawprint.fill").font(.system(size: 11)).foregroundStyle(Color.islandAccent)
            }
            Text("Notchi").font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.8))
            // Leave room for the hardware notch when hanging from it.
            Spacer(minLength: settings.dock == .notch ? c.geometry.notchWidth + 12 : 8)
            if battery.hasBattery {
                HStack(spacing: 4) {
                    if battery.isCharging {
                        Image(systemName: "bolt.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(Color(hex: 0x4CD97B))
                    }
                    Text("\(battery.level)%").font(.system(size: 11, weight: .medium, design: .rounded))
                    Image(systemName: battery.symbol).font(.system(size: 13))
                        .foregroundStyle(battery.level <= 15 && !battery.isCharging ? Color(hex: 0xFF5A5F) : .white.opacity(0.8))
                }
                .foregroundStyle(.white.opacity(0.75))
            }
            // The menu-bar strip beside the notch doesn't receive clicks, so in notch mode
            // the buttons live in the apps row instead (see IslandControls).
            if settings.dock != .notch {
                IslandControls(c: c, settings: settings, terminals: terminals)
            }
        }
        .padding(.horizontal, 4)
    }
}

/// Terminal-tab picker, move-island toggle and Settings.
struct IslandControls: View {
    @ObservedObject var c: IslandController
    @ObservedObject var settings: AppSettings
    @ObservedObject var terminals: TerminalTabs

    var body: some View {
        HStack(spacing: 2) {
            TerminalPickerMenu(terminals: terminals) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "terminal.fill").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 26, height: 26)
                    if !terminals.tabs.isEmpty {
                        Text("\(terminals.tabs.count)").font(.system(size: 7.5, weight: .heavy).monospacedDigit())
                            .foregroundStyle(.black).padding(.horizontal, 3)
                            .background(Capsule().fill(Color.islandAccent)).offset(x: 2, y: 1)
                    }
                }
            }
            .help("Choose terminal tabs to show on the island")
            Button { settings.dock = settings.dock.other } label: {
                Image(systemName: settings.dock.other.symbol).font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .buttonStyle(IconButtonStyle(size: 26))
            .help("Move the island to the \(settings.dock.other == .notch ? "top" : "left edge")")
            Button { c.openSettings() } label: {
                Image(systemName: "gearshape.fill").font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
            }
            .buttonStyle(IconButtonStyle(size: 26))
            .help("Settings")
        }
    }
}

// MARK: - Now playing

struct NowPlayingCard: View {
    @ObservedObject var media: NowPlayingService
    var vertical = false

    var body: some View {
        Group {
            if let t = media.track {
                if vertical { playingVertical(t) } else { playing(t) }
            } else {
                empty
            }
        }
        .padding(vertical ? 12 : 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(CardBackground())
    }

    /// Portrait card: artwork + titles on top, scrubber, then big centred controls.
    private func playingVertical(_ t: NowPlayingService.Track) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                ArtworkView(image: media.artwork, tint: media.tint, size: 64, radius: 12)
                    .shadow(color: media.tint.opacity(t.isPlaying ? 0.55 : 0.15), radius: 12)
                    .scaleEffect(t.isPlaying ? 1 : 0.92)
                    .animation(.spring(response: 0.4, dampingFraction: 0.7), value: t.isPlaying)
                VStack(alignment: .leading, spacing: 3) {
                    Text(t.title).font(.system(size: 14, weight: .semibold, design: .rounded)).lineLimit(2)
                    Text(t.artist).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            Scrubber(media: media, track: t)
            HStack(spacing: 26) {
                control("backward.fill", 14, size: 30) { media.previous() }
                control(t.isPlaying ? "pause.fill" : "play.fill", 20, size: 38) { media.playPause() }
                control("forward.fill", 14, size: 30) { media.next() }
            }
            .frame(maxWidth: .infinity)
        }
        .foregroundStyle(.white)
    }

    private func playing(_ t: NowPlayingService.Track) -> some View {
        HStack(spacing: 12) {
            ArtworkView(image: media.artwork, tint: media.tint, size: 62, radius: 12)
                .shadow(color: media.tint.opacity(t.isPlaying ? 0.55 : 0.15), radius: 12)
                .scaleEffect(t.isPlaying ? 1 : 0.92)
                .animation(.spring(response: 0.4, dampingFraction: 0.7), value: t.isPlaying)
            VStack(alignment: .leading, spacing: 3) {
                Text(t.title).font(.system(size: 13, weight: .semibold, design: .rounded)).lineLimit(1)
                Text(t.artist).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                Spacer(minLength: 0)
                Scrubber(media: media, track: t)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 4) {
                control("backward.fill", 12) { media.previous() }
                control(t.isPlaying ? "pause.fill" : "play.fill", 17, size: 32) { media.playPause() }
                control("forward.fill", 12) { media.next() }
            }
        }
        .foregroundStyle(.white)
    }

    private func control(_ symbol: String, _ font: CGFloat, size: CGFloat = 26, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: font, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(IconButtonStyle(size: size))
    }

    private var empty: some View {
        HStack(spacing: 12) {
            Image(systemName: "music.note")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 62, height: 62)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.06)))
            VStack(alignment: .leading, spacing: 6) {
                Text("Nothing playing").font(.system(size: 13, weight: .semibold, design: .rounded))
                HStack(spacing: 6) {
                    ForEach([NowPlayingService.Source.spotify, .music], id: \.rawValue) { s in
                        if s.isInstalled {
                            Button { media.openPlayer(s) } label: {
                                Text(s.appName).font(.system(size: 11, weight: .medium))
                                    .padding(.horizontal, 10).padding(.vertical, 4)
                                    .background(Capsule().fill(.white.opacity(0.1)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            Spacer()
        }
        .foregroundStyle(.white)
    }
}

struct Scrubber: View {
    @ObservedObject var media: NowPlayingService
    let track: NowPlayingService.Track

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            let pos = track.position(at: ctx.date)
            let frac = track.duration > 0 ? pos / track.duration : 0
            HStack(spacing: 6) {
                Text(fmt(pos)).font(.system(size: 9, weight: .medium).monospacedDigit())
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.15))
                        Capsule().fill(media.tint).frame(width: max(3, geo.size.width * frac))
                    }
                    .frame(height: 3.5)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture(coordinateSpace: .local) { loc in
                        guard track.duration > 0 else { return }
                        media.seek(to: Double(loc.x / geo.size.width) * track.duration)
                    }
                }
                Text("-" + fmt(max(0, track.duration - pos))).font(.system(size: 9, weight: .medium).monospacedDigit())
            }
            .foregroundStyle(.white.opacity(0.45))
            .frame(height: 10)
        }
    }

    private func fmt(_ s: Double) -> String {
        let t = Int(s.rounded(.down))
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

// MARK: - Live activities

struct ActivitiesCard: View {
    @ObservedObject var activities: ActivityCenter
    @ObservedObject var battery: BatteryMonitor
    var maxRows = 2

    private struct Row: Identifiable {
        let id: String
        let symbol: String
        let title: String
        let subtitle: String?
        let progress: Double?
        let tint: Color
        /// Right-aligned figure next to the title (the battery's current %).
        var value: String? = nil
        /// Small line under the bar ("16% to go · full in 1h 12m").
        var caption: String? = nil
        /// The live activity behind this row (nil for the battery row).
        var activity: LiveActivity? = nil
    }

    private var rows: [Row] {
        var r: [Row] = activities.items.sorted { ($0.rank, $0.updated) > ($1.rank, $1.updated) }.map {
            Row(id: $0.id, symbol: $0.symbol, title: $0.title, subtitle: $0.subtitle, progress: $0.progress,
                tint: $0.tint, activity: $0)
        }
        if battery.isCharging {
            r.append(Row(id: "battery", symbol: "bolt.fill", title: "Charging", subtitle: nil,
                         progress: Double(battery.level) / 100, tint: Color(hex: 0x4CD97B),
                         value: "\(battery.level)%", caption: battery.chargeDetail))
        }
        return r
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 4) {
                Text("LIVE").font(.system(size: 9, weight: .bold)).tracking(1.2).foregroundStyle(.white.opacity(0.35))
                if rows.count > 1 {
                    Text("· \(rows.count)").font(.system(size: 9, weight: .bold).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
            if rows.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles").foregroundStyle(.white.opacity(0.4))
                    Text("All quiet").font(.system(size: 12, weight: .medium, design: .rounded))
                }
                Text("island push --title …").font(.system(size: 9.5, design: .monospaced)).foregroundStyle(.white.opacity(0.3))
            } else if rows.count > 1 {
                // Several at once: a scrollable queue of compact one-line rows.
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(rows) { row in compactRow(row) }
                    }
                    .padding(.bottom, 4)
                }
                .scrollBounceBehavior(.basedOnSize)
                // Fade the bottom edge so it's obvious more rows are waiting below.
                .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.72),
                                             .init(color: .black.opacity(rows.count > 2 ? 0.15 : 1), location: 1)],
                                     startPoint: .top, endPoint: .bottom))
            } else {
                let shown = Array(rows.prefix(1))
                ForEach(shown) { row in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: row.symbol).font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(row.tint).frame(width: 16)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 4) {
                                Text(row.title).font(.system(size: 11.5, weight: .semibold, design: .rounded)).lineLimit(1)
                                if let v = row.value {
                                    Spacer(minLength: 2)
                                    // No room for the caption line: say how far to 100% right here.
                                    Text(shown.count == 1 || row.caption == nil ? v
                                         : "\(v) · \(battery.toFull)% to go").font(.system(size: 11.5, weight: .bold, design: .rounded).monospacedDigit())
                                        .foregroundStyle(row.tint)
                                        .contentTransition(.numericText())
                                }
                            }
                            if let p = row.progress {
                                ProgressCapsule(value: p, tint: row.tint).frame(height: 3)
                                // Only room for the extra line when this is the only row.
                                if let c = row.caption, shown.count == 1 {
                                    Text(c).font(.system(size: 9.5, weight: .medium).monospacedDigit())
                                        .foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                                }
                            } else if let s = row.subtitle {
                                Text(s).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()   // never draw past the card, whatever is in it
        .background(CardBackground())
    }

    /// Icon · name · status on a single line.
    private func compactRow(_ row: Row) -> some View {
        HStack(spacing: 7) {
            Image(systemName: row.symbol).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(row.tint).frame(width: 15)
            Text(row.title).font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .lineLimit(1).truncationMode(.tail)
                .layoutPriority(1)
            Spacer(minLength: 4)
            if let v = row.value {
                Text(v).font(.system(size: 11, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(row.tint)
            } else if let a = row.activity {
                ActivityTrailing(activity: a).frame(width: 15, height: 15)
            } else if let p = row.progress {
                ProgressCapsule(value: p, tint: row.tint).frame(width: 30, height: 3)
            }
        }
        .frame(height: 17)
        .help([row.title, row.subtitle].compactMap { $0 }.joined(separator: " — "))
    }
}

// MARK: - Apps

struct AppsRow: View {
    @ObservedObject var c: IslandController
    @ObservedObject var apps: AppShelf
    @State private var dropTargeted = false

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(apps.apps.enumerated()), id: \.element.id) { i, app in
                AppTile(app: app, index: i) { c.launch(app) }
                    .contextMenu { Button("Unpin \(app.name)") { apps.remove(app) } }
            }
            if apps.apps.count < AppShelf.maxApps {
                Button { c.addApps() } label: {
                    Image(systemName: "plus").font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 40, height: 40)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(.white.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                }
                .buttonStyle(.plain)
                .help("Pin an app — or drag one here")
            }
            if apps.apps.isEmpty {
                Text("Drop apps here").font(.system(size: 12, design: .rounded)).foregroundStyle(.white.opacity(0.4))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CardBackground(highlighted: dropTargeted))
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { apps.handleDrop($0) }
    }
}

/// Portrait version of the apps row: a 5 × 2 grid.
struct AppsGrid: View {
    @ObservedObject var c: IslandController
    @ObservedObject var apps: AppShelf
    @State private var dropTargeted = false

    private let columns = Array(repeating: GridItem(.fixed(48), spacing: 10), count: 5)

    var body: some View {
        LazyVGrid(columns: columns, alignment: .center, spacing: 8) {
            ForEach(Array(apps.apps.enumerated()), id: \.element.id) { i, app in
                AppTile(app: app, index: i) { c.launch(app) }
                    .contextMenu { Button("Unpin \(app.name)") { apps.remove(app) } }
            }
            if apps.apps.count < AppShelf.maxApps {
                Button { c.addApps() } label: {
                    Image(systemName: "plus").font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 40, height: 40)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(.white.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                }
                .buttonStyle(.plain)
                .help("Pin an app — or drag one here")
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(CardBackground(highlighted: dropTargeted))
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { apps.handleDrop($0) }
    }
}

struct AppTile: View {
    let app: PinnedApp
    let index: Int
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(nsImage: app.icon).resizable().interpolation(.high).frame(width: 40, height: 40)
        }
        .buttonStyle(.plain)
        .scaleEffect(hover ? 1.18 : 1, anchor: .bottom)
        .offset(y: hover ? -2 : 0)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: hover)
        .onHover { hover = $0 }
        .overlay(alignment: .bottom) {
            if hover && index < 9 {
                Text("⌘\(index + 1)").font(.system(size: 8.5, weight: .bold, design: .rounded))
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Capsule().fill(.black.opacity(0.75)))
                    .foregroundStyle(.white)
                    .offset(y: 7)
                    .transition(.opacity)
            }
        }
        .help(app.name)
        .frame(width: 46)
    }
}

// MARK: - Claude

struct ClaudeBar: View {
    @ObservedObject var c: IslandController
    @ObservedObject var claude: ClaudeSession
    @ObservedObject var terminals: TerminalTabs
    @FocusState private var focused: Bool

    /// When a terminal tab is selected, the bar types into that tab's Claude session instead.
    private var target: TermTab? { terminals.selected }

    private func submit() {
        if let tab = target {
            let text = claude.input
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            claude.input = ""
            terminals.send(text, to: tab)
        } else {
            claude.send()
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: target == nil ? "sparkle" : "terminal.fill")
                .font(.system(size: target == nil ? 14 : 12, weight: .bold))
                .foregroundStyle(Color.islandAccent)
                .symbolEffect(.pulse, isActive: claude.isStreaming)
                .contentTransition(.symbolEffect(.replace))
            if let flash = terminals.sentFlash {
                Text(flash)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color(hex: 0x4CD97B))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            } else {
                TextField(target.map { "Message Claude in \($0.displayName)…" } ?? "Ask Claude anything…",
                          text: $claude.input)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($focused)
                    .onSubmit { submit() }
            }
            if let tab = target {
                Button { withAnimation(.easeOut(duration: 0.15)) { terminals.selectedID = nil } } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.turn.down.right").font(.system(size: 8.5, weight: .bold))
                        Text(tab.displayName).lineLimit(1).frame(maxWidth: 110)
                        Image(systemName: "xmark").font(.system(size: 7.5, weight: .bold))
                    }
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(Color.islandAccent.opacity(0.25)))
                    .foregroundStyle(.white.opacity(0.85))
                }
                .buttonStyle(.plain)
                .help("Stop sending to this tab")
                Button { submit() } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 19))
                        .foregroundStyle(claude.input.isEmpty ? Color.white.opacity(0.25) : Color.islandAccent)
                }
                .buttonStyle(.plain)
                .disabled(claude.input.isEmpty)
            } else if claude.isStreaming {
                Button { claude.stop() } label: {
                    Image(systemName: "stop.circle.fill").font(.system(size: 17)).foregroundStyle(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
            } else {
                Text(claude.providerLabel)
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Capsule().fill(.white.opacity(0.08)))
                    .foregroundStyle(.white.opacity(0.5))
                Button { submit() } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 19))
                        .foregroundStyle(claude.input.isEmpty ? Color.white.opacity(0.25) : Color.islandAccent)
                }
                .buttonStyle(.plain)
                .disabled(claude.input.isEmpty)
            }
        }
        .animation(.easeOut(duration: 0.2), value: terminals.sentFlash)
        .onChange(of: terminals.selectedID) { _, id in if id != nil { focused = true } }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.islandAccent.opacity(focused ? 0.6 : 0), lineWidth: 1))
        .animation(.easeOut(duration: 0.15), value: focused)
        .onAppear {
            if c.pendingFocus {
                c.pendingFocus = false
                DispatchQueue.main.async { focused = true }
            }
        }
        .onChange(of: c.focusToken) { _, _ in
            c.pendingFocus = false
            focused = true
        }
    }
}

struct AnswerPanel: View {
    @ObservedObject var claude: ClaudeSession

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(claude.turns) { t in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(t.question).font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.45))
                                if t.answer.isEmpty && claude.isStreaming {
                                    TypingDots()
                                } else {
                                    Text(markdown(t.answer))
                                        .font(.system(size: 13))
                                        .foregroundStyle(t.failed ? Color(hex: 0xFFB3A8) : .white.opacity(0.92))
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(12)
                }
                .onChange(of: claude.turns.last?.answer) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            }
            HStack(spacing: 14) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(claude.turns.last?.answer ?? "", forType: .string)
                } label: { Label("Copy", systemImage: "doc.on.doc") }
                Button { claude.reset() } label: { Label("New chat", systemImage: "square.and.pencil") }
                Spacer()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.55))
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .background(CardBackground())
    }

    private func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}

struct TypingDots: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    Circle().fill(Color.islandAccent)
                        .frame(width: 5, height: 5)
                        .opacity(0.35 + 0.65 * max(0, sin(t * 5 - Double(i) * 0.7)))
                }
            }
        }
        .frame(height: 16)
    }
}
