import SwiftUI

// MARK: - Root

struct IslandRootView: View {
    @ObservedObject var c: IslandController
    @ObservedObject var media: NowPlayingService
    @ObservedObject var activities: ActivityCenter
    @ObservedObject var claude: ClaudeSession
    @ObservedObject var settings: AppSettings
    @ObservedObject var battery: BatteryMonitor
    @ObservedObject var apps: AppShelf
    @ObservedObject var terminals: TerminalTabs

    var body: some View {
        let open = c.isOpen
        let size = open ? CGSize(width: c.expandedWidth, height: c.expandedHeight) : c.closedSize()
        Group {
            if settings.dock == .notch { notchIsland(size: size, open: open) } else { edgeIsland(size: size, open: open) }
        }
        .frame(width: c.panelSize.width, height: c.panelSize.height,
               alignment: settings.dock == .notch ? .top : .leading)
        .environment(\.colorScheme, .dark)
        .acceptsActivationClicks()
    }

    private var closeCatcher: some View {
        // Clicking the transparent area around the open island closes it.
        Color.black.opacity(0.001).contentShape(Rectangle()).onTapGesture { c.close() }
    }

    private var expanded: some View {
        expandedContent.id(settings.theme)
    }

    private var expandedContent: some View {
        ExpandedView(c: c, media: media, activities: activities, claude: claude,
                     battery: battery, apps: apps, settings: settings, terminals: terminals,
                     transcript: c.transcript)
    }

    /// Hanging from the notch.
    private func notchIsland(size: CGSize, open: Bool) -> some View {
        let g = c.geometry
        // No flared shoulders while idle — the shape must hide completely behind the notch.
        let tr: CGFloat = open ? 14 : (c.isIdle ? 0 : 6)
        let br: CGFloat = open ? 32 : (c.peek != nil ? 20 : (c.isIdle ? 8 : 10))
        let shape = NotchShape(topRadius: tr, bottomRadius: br)
        return ZStack(alignment: .top) {
            if open { closeCatcher }
            ZStack(alignment: .top) {
                // Idle on a notched Mac: draw nothing — the hardware notch is already black.
                if open {
                    // Open: themed surface (solid / frosted). Liquid Glass is drawn by the
                    // SurfacePanel behind this window (see IslandGlassRootView).
                    if settings.islandStyle != .glass {
                        IslandSurface(shape: shape, style: settings.islandStyle, theme: settings.theme,
                                      opacity: settings.islandOpacity)
                    }
                } else {
                    // Closed: black so it melts into the hardware notch (invisible when idle).
                    shape.fill(Color.black.opacity(g.hasNotch && c.isIdle ? 0 : 1))
                }
                if open {
                    expanded.transition(.blurFade)
                } else {
                    ClosedView(c: c, media: media, activities: activities).transition(.blurFade)
                }
            }
            .frame(width: size.width + tr * 2, height: size.height, alignment: .top)
            .clipShape(shape)
            .shadow(color: .black.opacity(open && settings.islandStyle != .glass ? 0.5 : 0),
                    radius: open ? 24 : 0, y: open ? 10 : 0)
            .animation(c.spring, value: size)
        }
    }

    /// Docked to the left screen edge, vertically centred.
    private func edgeIsland(size: CGSize, open: Bool) -> some View {
        let tr: CGFloat = open ? 14 : 5
        let br: CGFloat = open ? 30 : (c.peek != nil ? 20 : (c.isIdle ? 3.5 : 16))
        let shape = EdgeShape(flare: tr, radius: br)
        return ZStack(alignment: .leading) {
            if open { closeCatcher }
            ZStack(alignment: .leading) {
                if open {
                    if settings.islandStyle != .glass {
                        IslandSurface(shape: shape, style: settings.islandStyle, theme: settings.theme,
                                      opacity: settings.islandOpacity)
                    }
                } else {
                    shape.fill(Color.black)
                }
                if c.isIdle && !open {
                    // A hairline so the handle is findable on dark wallpapers too.
                    shape.stroke(Color.white.opacity(0.22), lineWidth: 1)
                }
                if open {
                    expanded.padding(.vertical, tr).transition(.blurFade)
                } else {
                    ClosedEdgeView(c: c, media: media, activities: activities)
                        .padding(.vertical, tr)
                        .transition(.blurFade)
                }
            }
            .frame(width: size.width, height: size.height + tr * 2, alignment: .leading)
            .clipShape(shape)
            .shadow(color: .black.opacity(open ? (settings.islandStyle != .glass ? 0.5 : 0) : 0.25),
                    radius: open ? 24 : 6, x: open ? 8 : 2)
            .animation(c.spring, value: size)
        }
    }
}

/// The Liquid Glass surface, drawn in its own never-key window right behind the island.
/// Same geometry and spring as IslandRootView, so the two move as one.
struct IslandGlassRootView: View {
    @ObservedObject var c: IslandController
    @ObservedObject var settings: AppSettings
    @ObservedObject var claude: ClaudeSession
    @ObservedObject var terminals: TerminalTabs

    var body: some View {
        let open = c.isOpen
        let glass = open && settings.islandStyle == .glass
        let size = open ? CGSize(width: c.expandedWidth, height: c.expandedHeight) : c.closedSize()
        Group {
            if settings.dock == .notch {
                let tr: CGFloat = open ? 14 : (c.isIdle ? 0 : 6)
                let br: CGFloat = open ? 32 : (c.peek != nil ? 20 : (c.isIdle ? 8 : 10))
                let shape = NotchShape(topRadius: tr, bottomRadius: br)
                ZStack(alignment: .top) {
                    if glass {
                        IslandSurface(shape: shape, style: .glass, theme: settings.theme, opacity: settings.islandOpacity)
                            .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
                    }
                }
                .frame(width: size.width + tr * 2, height: size.height, alignment: .top)
                .animation(c.spring, value: size)
            } else {
                let tr: CGFloat = open ? 14 : 5
                let br: CGFloat = open ? 30 : (c.peek != nil ? 20 : (c.isIdle ? 3.5 : 16))
                let shape = EdgeShape(flare: tr, radius: br)
                ZStack(alignment: .leading) {
                    if glass {
                        IslandSurface(shape: shape, style: .glass, theme: settings.theme, opacity: settings.islandOpacity)
                            .shadow(color: .black.opacity(0.35), radius: 24, x: 8)
                    }
                }
                .frame(width: size.width, height: size.height + tr * 2, alignment: .leading)
                .animation(c.spring, value: size)
            }
        }
        .frame(width: c.panelSize.width, height: c.panelSize.height,
               alignment: settings.dock == .notch ? .top : .leading)
        .environment(\.colorScheme, .dark)
    }
}

/// The menu-bar cat lives in its own window, beneath the island.
struct CatRootView: View {
    let engine: CatEngine
    @ObservedObject var settings: AppSettings

    var body: some View {
        ZStack(alignment: .top) {
            if settings.showCat { CatLayer(engine: engine, settings: settings) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct BlurFade: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        content
            .blur(radius: active ? 10 : 0)
            .opacity(active ? 0 : 1)
            .scaleEffect(active ? 0.94 : 1, anchor: .top)
    }
}

extension AnyTransition {
    static var blurFade: AnyTransition {
        .modifier(active: BlurFade(active: true), identity: BlurFade(active: false))
    }
}

// MARK: - Closed (compact live activity + peek banner)

struct ClosedView: View {
    @ObservedObject var c: IslandController
    @ObservedObject var media: NowPlayingService
    @ObservedObject var activities: ActivityCenter

    var body: some View {
        let g = c.geometry
        let wing = Metrics.wing(g)
        VStack(spacing: 0) {
            // While a banner is showing it *is* the live activity — don't show it twice.
            HStack(spacing: 0) {
                leading.frame(width: wing, height: g.notchHeight)
                Spacer(minLength: 0)
                trailing.frame(width: wing, height: g.notchHeight)
            }
            .frame(height: g.notchHeight)
            .opacity(c.peek == nil ? 1 : 0)
            .animation(.easeOut(duration: 0.2), value: c.peek == nil)
            if let p = c.peek {
                PeekRow(peek: p, media: media)
                    .frame(height: 42)
                    .padding(.horizontal, 18)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var leading: some View { CompactLeading(c: c, media: media, activities: activities) }
    private var trailing: some View { CompactTrailing(c: c, media: media, activities: activities) }
}

/// The left-edge handle: a slim pill, artwork + waveform stacked while music plays,
/// or a banner when something new happens.
struct ClosedEdgeView: View {
    @ObservedObject var c: IslandController
    @ObservedObject var media: NowPlayingService
    @ObservedObject var activities: ActivityCenter

    var body: some View {
        if let p = c.peek {
            PeekRow(peek: p, media: media)
                .padding(.leading, 16)
                .padding(.trailing, 14)
                .frame(width: c.closedSize().width, height: c.closedSize().height)
                .transition(.opacity.combined(with: .move(edge: .leading)))
        } else if c.compactKind != .none {
            VStack(spacing: 12) {
                CompactLeading(c: c, media: media, activities: activities, artSize: 24)
                CompactTrailing(c: c, media: media, activities: activities)
            }
            .frame(width: c.closedSize().width, height: c.closedSize().height)
        }
    }
}

struct CompactLeading: View {
    @ObservedObject var c: IslandController
    @ObservedObject var media: NowPlayingService
    @ObservedObject var activities: ActivityCenter
    var artSize: CGFloat = 20

    var body: some View {
        switch c.compactKind {
        case .music:
            ArtworkView(image: media.artwork, tint: media.tint, size: artSize, radius: artSize / 4)
        case .activity:
            if let a = activities.primary {
                Image(systemName: a.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(a.tint)
                    .symbolEffect(.pulse, isActive: a.state == .running || a.state == .attention)
            }
        case .none:
            EmptyView()
        }
    }
}

struct CompactTrailing: View {
    @ObservedObject var c: IslandController
    @ObservedObject var media: NowPlayingService
    @ObservedObject var activities: ActivityCenter

    var body: some View {
        switch c.compactKind {
        case .music:
            Waveform(playing: media.track?.isPlaying == true, tint: media.tint)
                .frame(width: 18, height: 14)
        case .activity:
            if let a = activities.primary { ActivityTrailing(activity: a) }
        case .none:
            EmptyView()
        }
    }
}

struct PeekRow: View {
    let peek: Peek
    @ObservedObject var media: NowPlayingService

    var body: some View {
        HStack(spacing: 10) {
            if peek.kind == .music {
                ArtworkView(image: media.artwork, tint: media.tint, size: 28, radius: 7)
            } else if let s = peek.symbol {
                Image(systemName: s)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(peek.tint)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(peek.tint.opacity(0.16)))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(peek.title).font(.system(size: 12.5, weight: .semibold, design: .rounded)).lineLimit(1)
                if let sub = peek.subtitle {
                    Text(sub).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let p = peek.progress {
                ProgressCapsule(value: p, tint: peek.tint).frame(width: 56, height: 4)
            } else if peek.kind == .music {
                Waveform(playing: true, tint: media.tint).frame(width: 18, height: 14)
            }
        }
        .foregroundStyle(.white)
    }
}

// MARK: - Small components

struct ArtworkView: View {
    let image: NSImage?
    let tint: Color
    let size: CGFloat
    let radius: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(colors: [tint.opacity(0.9), tint.opacity(0.4)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .overlay(Image(systemName: "music.note").font(.system(size: size * 0.42, weight: .bold))
                        .foregroundStyle(.white.opacity(0.85)))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

struct Waveform: View {
    let playing: Bool
    let tint: Color
    private let speeds: [Double] = [7.1, 9.3, 6.2, 8.4]
    private let phases: [Double] = [0, 1.3, 2.1, 0.7]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !playing)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    let v = playing ? 0.3 + 0.7 * abs(sin(t * speeds[i] * 0.5 + phases[i])) : 0.18
                    Capsule().fill(tint).frame(width: 2.6, height: max(2.5, 14 * v))
                }
            }
            .frame(maxHeight: .infinity)
            .animation(.easeOut(duration: 0.25), value: playing)
        }
    }
}

struct ProgressCapsule: View {
    let value: Double
    let tint: Color
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.14))
                Capsule().fill(tint).frame(width: max(4, geo.size.width * value))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: value)
    }
}

struct ActivityTrailing: View {
    let activity: LiveActivity
    var body: some View {
        Group {
            switch activity.state {
            case .done:
                Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Color(hex: 0x4CD97B))
            case .failed:
                Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Color(hex: 0xFF5A5F))
            case .attention:
                Image(systemName: "exclamationmark").font(.system(size: 12, weight: .heavy)).foregroundStyle(Color(hex: 0xFFB340))
            case .running:
                if let p = activity.progress {
                    ZStack {
                        Circle().stroke(.white.opacity(0.15), lineWidth: 2.5)
                        Circle().trim(from: 0, to: p).stroke(activity.tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 15, height: 15)
                    .animation(.spring(response: 0.4), value: p)
                } else {
                    // Same spinning ring as the terminal rail, in the activity's (theme) colour.
                    TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
                        let t = ctx.date.timeIntervalSinceReferenceDate
                        ZStack {
                            Circle().stroke(Color.white.opacity(0.14), lineWidth: 2)
                            Circle().trim(from: 0, to: 0.28 + 0.12 * sin(t * 2.4))
                                .stroke(activity.tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                                .rotationEffect(.degrees(t.truncatingRemainder(dividingBy: 1) * 360))
                        }
                        .padding(1)
                    }
                    .frame(width: 14, height: 14)
                }
            }
        }
    }
}

struct CardBackground: View {
    var highlighted = false
    var body: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.white.opacity(highlighted ? 0.12 : 0.06))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(highlighted ? 0.25 : 0.06), lineWidth: 1))
    }
}

struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 26
    func makeBody(configuration: Configuration) -> some View {
        IconButtonBody(configuration: configuration, size: size)
    }
    private struct IconButtonBody: View {
        let configuration: Configuration
        let size: CGFloat
        @State private var hover = false
        var body: some View {
            configuration.label
                .frame(width: size, height: size)
                .background(Circle().fill(.white.opacity(hover ? 0.12 : 0)))
                .scaleEffect(configuration.isPressed ? 0.88 : 1)
                .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
                .onHover { hover = $0 }
                .contentShape(Circle())
        }
    }
}
