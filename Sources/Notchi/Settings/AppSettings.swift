import SwiftUI

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }

    static let claude = Color(hex: 0xD97757)
}

struct CatPalette {
    var fur: Color
    var furDark: Color
    var cream: Color
    var creamDark: Color
    var outline: Color
    var eye: Color
    var pink: Color
    var blush: Color
    /// Colour-point coats (Siamese): dark ears, face mask, legs and tail.
    var points: Color? = nil
    var pointsDark: Color? = nil
    var mask: Color? = nil
    var innerEar: Color? = nil
    /// Big blue/green eyes with a pupil; nil = simple dot eyes.
    var iris: Color? = nil
    var nose: Color? = nil
    var stripes = true
    /// 0…1 — how tufty the cheeks are.
    var fluff: CGFloat = 0.5
    /// Dogs: floppy (Golden) vs pointy (Shiba) ears, curled vs plume tail, "maro" eyebrow dots.
    var floppyEars = false
    var curlyTail = false
    var brows: Color? = nil
    /// Birds: a crest of head feathers (cockatiel), coloured with `points`.
    var crest = false
}

enum Pet: String, CaseIterable, Identifiable {
    case cat, dog, bird
    var id: String { rawValue }
    var name: String {
        switch self {
        case .cat: "Cat"
        case .dog: "Dog"
        case .bird: "Bird"
        }
    }
    var emoji: String {
        switch self {
        case .cat: "🐱"
        case .dog: "🐶"
        case .bird: "🐦"
        }
    }
    /// Size relative to the cat.
    var sizeFactor: CGFloat {
        switch self {
        case .cat: 1
        case .dog: 1.08
        case .bird: 0.82
        }
    }
}

enum DogCoat: String, CaseIterable, Identifiable {
    case shiba, golden, choco
    var id: String { rawValue }
    var name: String {
        switch self {
        case .shiba: "Shiba"
        case .golden: "Golden"
        case .choco: "Choco"
        }
    }
    var palette: CatPalette {
        switch self {
        case .shiba:
            CatPalette(fur: Color(hex: 0xE8A055), furDark: Color(hex: 0xC97F3A), cream: Color(hex: 0xFFF4E6),
                       creamDark: Color(hex: 0xEEDCC6), outline: Color(hex: 0x3A2414), eye: Color(hex: 0x24160D),
                       pink: Color(hex: 0xFF8C9A), blush: Color(hex: 0xFF9AA6), nose: Color(hex: 0x24160D),
                       stripes: false, fluff: 0.4, curlyTail: true, brows: Color(hex: 0xFFF4E6))
        case .golden:
            CatPalette(fur: Color(hex: 0xF2C27B), furDark: Color(hex: 0xD99E52), cream: Color(hex: 0xFFF1D9),
                       creamDark: Color(hex: 0xEED9B8), outline: Color(hex: 0x3D2815), eye: Color(hex: 0x24160D),
                       pink: Color(hex: 0xFF8C9A), blush: Color(hex: 0xFF9AA6), nose: Color(hex: 0x24160D),
                       stripes: false, fluff: 0.7, floppyEars: true)
        case .choco:
            CatPalette(fur: Color(hex: 0x7A5136), furDark: Color(hex: 0x5C3B25), cream: Color(hex: 0xF3DFC8),
                       creamDark: Color(hex: 0xD8C0A5), outline: Color(hex: 0x24150C), eye: Color(hex: 0x1A0F08),
                       pink: Color(hex: 0xFF8C9A), blush: Color(hex: 0xFF9AA6), nose: Color(hex: 0x1A0F08),
                       stripes: false, fluff: 0.3, floppyEars: true)
        }
    }
}

enum BirdCoat: String, CaseIterable, Identifiable {
    case budgie, cockatiel, bluebird
    var id: String { rawValue }
    var name: String {
        switch self {
        case .budgie: "Budgie"
        case .cockatiel: "Cockatiel"
        case .bluebird: "Bluebird"
        }
    }
    /// fur = body, furDark = wings/tail, cream = belly & face, blush = cheek patch, nose = beak.
    var palette: CatPalette {
        switch self {
        case .budgie:
            CatPalette(fur: Color(hex: 0x8FD66B), furDark: Color(hex: 0x4E9E45), cream: Color(hex: 0xFFF08A),
                       creamDark: Color(hex: 0xE8D46A), outline: Color(hex: 0x23331C), eye: Color(hex: 0x1B1B1B),
                       pink: Color(hex: 0xFF8C9A), blush: Color(hex: 0x6E8BFF), nose: Color(hex: 0xF4C27A),
                       stripes: false)
        case .cockatiel:
            CatPalette(fur: Color(hex: 0xC9CBD3), furDark: Color(hex: 0x8D909C), cream: Color(hex: 0xFFE680),
                       creamDark: Color(hex: 0xE8CD5F), outline: Color(hex: 0x2B2C33), eye: Color(hex: 0x1B1B1B),
                       pink: Color(hex: 0xFF8C9A), blush: Color(hex: 0xFF8A3D), points: Color(hex: 0xFFE680),
                       nose: Color(hex: 0xC9B4A6), stripes: false, crest: true)
        case .bluebird:
            CatPalette(fur: Color(hex: 0x6FA8F5), furDark: Color(hex: 0x3F72C9), cream: Color(hex: 0xFFE3C2),
                       creamDark: Color(hex: 0xF0C99E), outline: Color(hex: 0x172540), eye: Color(hex: 0x111827),
                       pink: Color(hex: 0xFF8C9A), blush: Color(hex: 0xFF9AA6), nose: Color(hex: 0xFFB347),
                       stripes: false)
        }
    }
}

enum CatCoat: String, CaseIterable, Identifiable {
    case siamese, ginger, cream, midnight, smoky
    var id: String { rawValue }

    var name: String {
        switch self {
        case .siamese: "Siamese"
        case .ginger: "Ginger"
        case .cream: "Cream"
        case .midnight: "Midnight"
        case .smoky: "Smoky"
        }
    }

    var palette: CatPalette {
        switch self {
        case .siamese:
            CatPalette(fur: Color(hex: 0xF8ECD9), furDark: Color(hex: 0xE6D0B0), cream: Color(hex: 0xFFF9EF),
                       creamDark: Color(hex: 0xEADBC4), outline: Color(hex: 0x3E2A20), eye: Color(hex: 0x1C1411),
                       pink: Color(hex: 0xE59A9A), blush: Color(hex: 0xFFB0A8),
                       points: Color(hex: 0x5E4334), pointsDark: Color(hex: 0x47322A), mask: Color(hex: 0x6A4B3B),
                       innerEar: Color(hex: 0x8E6757), iris: Color(hex: 0x8EC6EE), nose: Color(hex: 0x33241D),
                       stripes: false, fluff: 1)
        case .ginger:
            CatPalette(fur: Color(hex: 0xF6A65A), furDark: Color(hex: 0xDB7F33), cream: Color(hex: 0xFFF1DF),
                       creamDark: Color(hex: 0xEDD3B3), outline: Color(hex: 0x3A2416), eye: Color(hex: 0x2B1A10),
                       pink: Color(hex: 0xFF8C9E), blush: Color(hex: 0xFF8FA0))
        case .cream:
            CatPalette(fur: Color(hex: 0xFFF4E4), furDark: Color(hex: 0xE6C9A0), cream: Color(hex: 0xFFFFFF),
                       creamDark: Color(hex: 0xEFE2CF), outline: Color(hex: 0x3D3027), eye: Color(hex: 0x2B1E16),
                       pink: Color(hex: 0xFF94A6), blush: Color(hex: 0xFF9FB0))
        case .midnight:
            CatPalette(fur: Color(hex: 0x34333E), furDark: Color(hex: 0x24232C), cream: Color(hex: 0xF4F2F7),
                       creamDark: Color(hex: 0xD3D0DC), outline: Color(hex: 0xC9C4E6), eye: Color(hex: 0xF5CB4C),
                       pink: Color(hex: 0xFF9FB2), blush: Color(hex: 0xFF8FA6))
        case .smoky:
            CatPalette(fur: Color(hex: 0xADB4C1), furDark: Color(hex: 0x868E9D), cream: Color(hex: 0xF5F6F9),
                       creamDark: Color(hex: 0xDADDE4), outline: Color(hex: 0x2A2E36), eye: Color(hex: 0x2A2E36),
                       pink: Color(hex: 0xFF97A8), blush: Color(hex: 0xFF9DAE))
        }
    }
}

enum ClaudeProvider: String, CaseIterable, Identifiable {
    case auto, api, claudeCode
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: "Automatic"
        case .api: "Anthropic API key"
        case .claudeCode: "Local Claude Code"
        }
    }
}

enum IslandDock: String, CaseIterable, Identifiable {
    case notch, left
    var id: String { rawValue }
    var label: String { self == .notch ? "Top (notch)" : "Left edge" }
    var symbol: String { self == .notch ? "arrow.up.to.line" : "arrow.left.to.line" }
    var other: IslandDock { self == .notch ? .left : .notch }
}

final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    private enum K {
        static let showCat = "showCat"
        static let coat = "catCoat"
        static let walkRange = "walkRange"
        static let catSize = "catSize"
        static let dock = "islandDock"
        static let pet = "pet"
        static let claudeSound = "claudeSound"
        static let dogCoat = "dogCoat"
        static let birdCoat = "birdCoat"
        static let edgePosition = "edgePosition"
        static let provider = "claudeProvider"
        static let model = "claudeModel"
        static let dimBehindIsland = "dimBehindIsland"
        static let backdropStrength = "backdropStrength"
        static let theme = "islandTheme"
        static let islandStyle = "islandStyle"
        static let islandOpacity = "islandOpacity"
        static let useBackend = "useJavaBackend"
    }

    @Published var showCat: Bool { didSet { d.set(showCat, forKey: K.showCat) } }
    @Published var pet: Pet { didSet { d.set(pet.rawValue, forKey: K.pet) } }
    /// Play a sound when Claude finishes (or needs approval) in a pinned terminal tab.
    @Published var claudeSound: Bool { didSet { d.set(claudeSound, forKey: K.claudeSound) } }
    /// Use the Java backend (backend/ in the repo) when it's running on this Mac.
    @Published var useBackend: Bool { didSet { d.set(useBackend, forKey: K.useBackend) } }
    @Published var coat: CatCoat { didSet { d.set(coat.rawValue, forKey: K.coat) } }
    @Published var dogCoat: DogCoat { didSet { d.set(dogCoat.rawValue, forKey: K.dogCoat) } }
    @Published var birdCoat: BirdCoat { didSet { d.set(birdCoat.rawValue, forKey: K.birdCoat) } }

    /// Colours for whichever pet is selected.
    var palette: CatPalette {
        switch pet {
        case .cat: coat.palette
        case .dog: dogCoat.palette
        case .bird: birdCoat.palette
        }
    }
    @Published var walkRange: Double { didSet { d.set(walkRange, forKey: K.walkRange) } }
    /// Cat height relative to the menu bar (1 = exactly menu-bar tall).
    @Published var catSize: Double { didSet { d.set(catSize, forKey: K.catSize) } }
    /// Where the island lives.
    @Published var dock: IslandDock { didSet { d.set(dock.rawValue, forKey: K.dock) } }
    /// For edge docks: 0 = top of the screen, 1 = bottom.
    @Published var edgePosition: Double { didSet { d.set(edgePosition, forKey: K.edgePosition) } }
    @Published var provider: ClaudeProvider { didSet { d.set(provider.rawValue, forKey: K.provider) } }
    @Published var model: String { didSet { d.set(model, forKey: K.model) } }
    /// Dim and blur the rest of the screen (and the menu bar icons) while the island is open.
    @Published var dimBehindIsland: Bool { didSet { d.set(dimBehindIsland, forKey: K.dimBehindIsland) } }
    /// 0…1 — how strongly the screen behind the open island is blurred/dimmed.
    @Published var backdropStrength: Double { didSet { d.set(backdropStrength, forKey: K.backdropStrength) } }
    /// Island colours (accent + surface tint).
    @Published var theme: IslandTheme { didSet { d.set(theme.rawValue, forKey: K.theme) } }
    /// Solid / frosted blur / Liquid Glass.
    @Published var islandStyle: IslandStyle { didSet { d.set(islandStyle.rawValue, forKey: K.islandStyle) } }
    /// 0.2…1 — lower makes the open island more see-through.
    @Published var islandOpacity: Double { didSet { d.set(islandOpacity, forKey: K.islandOpacity) } }

    private init() {
        d.register(defaults: [
            K.showCat: true,
            K.coat: CatCoat.siamese.rawValue,
            K.walkRange: 170.0,
            K.catSize: 1.25,
            K.dock: IslandDock.notch.rawValue,
            K.edgePosition: 0.5,
            K.provider: ClaudeProvider.auto.rawValue,
            K.model: "claude-opus-5-5",
            K.dimBehindIsland: true,
            K.backdropStrength: 0.35,
            K.theme: IslandTheme.graphite.rawValue,
            K.islandStyle: IslandStyle.solid.rawValue,
            K.islandOpacity: 1.0,
        ])
        showCat = d.bool(forKey: K.showCat)
        coat = CatCoat(rawValue: d.string(forKey: K.coat) ?? "") ?? .siamese
        pet = Pet(rawValue: d.string(forKey: K.pet) ?? "") ?? .cat
        claudeSound = d.object(forKey: K.claudeSound) as? Bool ?? true
        useBackend = d.object(forKey: K.useBackend) as? Bool ?? true
        dogCoat = DogCoat(rawValue: d.string(forKey: K.dogCoat) ?? "") ?? .shiba
        birdCoat = BirdCoat(rawValue: d.string(forKey: K.birdCoat) ?? "") ?? .budgie
        walkRange = d.double(forKey: K.walkRange)
        catSize = d.double(forKey: K.catSize)
        dock = IslandDock(rawValue: d.string(forKey: K.dock) ?? "") ?? .notch
        edgePosition = d.double(forKey: K.edgePosition)
        provider = ClaudeProvider(rawValue: d.string(forKey: K.provider) ?? "") ?? .auto
        model = d.string(forKey: K.model) ?? "claude-opus-5-5"
        dimBehindIsland = d.bool(forKey: K.dimBehindIsland)
        backdropStrength = d.double(forKey: K.backdropStrength)
        theme = IslandTheme(rawValue: d.string(forKey: K.theme) ?? "") ?? .graphite
        islandStyle = IslandStyle(rawValue: d.string(forKey: K.islandStyle) ?? "") ?? .solid
        islandOpacity = d.double(forKey: K.islandOpacity)
    }
}
