import AppKit
import SwiftUI

/// Colour themes for the open island. `accent` replaces the old Claude-orange everywhere
/// (buttons, focus rings, the progress ring, selected tabs…); `base` is the island's surface tint.
enum IslandTheme: String, CaseIterable, Identifiable {
    case graphite, midnight, ocean, forest, lavender, rose, claude
    var id: String { rawValue }

    var name: String {
        switch self {
        case .graphite: "Graphite"
        case .midnight: "Midnight"
        case .ocean: "Ocean"
        case .forest: "Forest"
        case .lavender: "Lavender"
        case .rose: "Rose"
        case .claude: "Claude"
        }
    }

    var accent: Color {
        switch self {
        case .graphite: Color(hex: 0xE6E6EB)
        case .midnight: Color(hex: 0x8AB4FF)
        case .ocean: Color(hex: 0x4FC3F7)
        case .forest: Color(hex: 0x5ED89A)
        case .lavender: Color(hex: 0xB79CFF)
        case .rose: Color(hex: 0xFF7AA8)
        case .claude: Color(hex: 0xD97757)
        }
    }

    /// The island's own colour (black like the hardware notch for the classic look).
    var base: Color {
        switch self {
        case .graphite: Color(hex: 0x000000)
        case .midnight: Color(hex: 0x0A0E1A)
        case .ocean: Color(hex: 0x06141C)
        case .forest: Color(hex: 0x07140E)
        case .lavender: Color(hex: 0x110D1C)
        case .rose: Color(hex: 0x170A11)
        case .claude: Color(hex: 0x000000)
        }
    }

    /// Text/icons drawn *on* an accent fill (e.g. the tab-count badge).
    var onAccent: Color { self == .graphite ? .black : .black.opacity(0.85) }
}

/// How the open island's surface is rendered.
enum IslandStyle: String, CaseIterable, Identifiable {
    case solid, frosted, glass
    var id: String { rawValue }
    var name: String {
        switch self {
        case .solid: "Solid"
        case .frosted: "Frosted"
        case .glass: "Liquid Glass"
        }
    }
}

extension Color {
    /// The current theme's accent colour.
    static var islandAccent: Color { AppSettings.shared.theme.accent }
}

/// The open island's background: solid, frosted blur, or macOS Liquid Glass — tinted by the
/// theme, with adjustable opacity (lower = more see-through).
struct IslandSurface<S: Shape>: View {
    let shape: S
    let style: IslandStyle
    let theme: IslandTheme
    /// 0.2 … 1
    let opacity: Double

    var body: some View {
        switch style {
        case .solid:
            shape.fill(theme.base.opacity(opacity))
        case .frosted:
            ZStack {
                VisualEffectBlur(material: .hudWindow).clipShape(shape)
                shape.fill(theme.base.opacity(0.25 + 0.6 * opacity))
            }
            .overlay(shape.stroke(Color.white.opacity(0.1), lineWidth: 1))
        case .glass:
            if #available(macOS 26.0, *) {
                Color.clear
                    .glassEffect(.regular.tint(theme.base.opacity(0.15 + 0.7 * opacity)), in: shape)
                    // macOS renders glass darker/flatter once the window becomes key (e.g. when you
                    // click into a chat). Pin it to one look so the island doesn't change under you.
                    .environment(\.controlActiveState, .inactive)
            } else {
                IslandSurface(shape: shape, style: .frosted, theme: theme, opacity: opacity)
            }
        }
    }
}

/// Behind-window blur (classic frosted glass).
struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        v.appearance = NSAppearance(named: .darkAqua)
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material }
}
