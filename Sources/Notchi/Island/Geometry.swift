import AppKit

/// Where the hardware notch is (or where a virtual one should sit on screens without a notch).
struct NotchGeometry: Equatable {
    var screenFrame: CGRect = .zero
    var visibleFrame: CGRect = .zero
    var hasNotch = false
    var notchWidth: CGFloat = 190
    var notchHeight: CGFloat = 32
    /// Global screen x of the notch centre.
    var notchCenterX: CGFloat = 0

    static func detect() -> NotchGeometry {
        let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return NotchGeometry() }
        let f = screen.frame

        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            let minX = f.minX + left.width
            let maxX = f.maxX - right.width
            return NotchGeometry(screenFrame: f, visibleFrame: screen.visibleFrame, hasNotch: true,
                                 notchWidth: maxX - minX,
                                 notchHeight: screen.safeAreaInsets.top,
                                 notchCenterX: (minX + maxX) / 2)
        }

        // No notch: hang a virtual island from the menu bar.
        var menuBar = f.maxY - screen.visibleFrame.maxY
        if menuBar < 20 { menuBar = NSStatusBar.system.thickness }
        return NotchGeometry(screenFrame: f, visibleFrame: screen.visibleFrame, hasNotch: false,
                             notchWidth: 190,
                             notchHeight: min(max(menuBar, 24), 40),
                             notchCenterX: f.midX)
    }
}

enum Metrics {
    /// Notch: wide & short, hanging from the top. Left edge: tall & narrow, portrait.
    static func panelSize(_ dock: IslandDock) -> CGSize {
        dock == .notch ? CGSize(width: 880, height: 620) : CGSize(width: 420, height: 920)
    }
    /// The selected terminal tab's conversation, shown under the cards.
    static func transcriptHeight(_ dock: IslandDock) -> CGFloat { dock == .notch ? 330 : 270 }
    /// Terminal tabs rail on the left of the notch island.
    static let railWidth: CGFloat = 160
    static func expandedWidth(_ dock: IslandDock, rail: Bool = false) -> CGFloat {
        dock == .notch ? 600 + (rail ? railWidth + 10 : 0) : 340
    }

    static let topCatPanelSize = CGSize(width: 680, height: 140)
    /// Left-edge cat world: a strip along the left of the screen, full height.
    static let leftCatWorldWidth: CGFloat = 300
    static let answerHeight: CGFloat = 200
    static let edgeHeaderHeight: CGFloat = 34

    static func wing(_ g: NotchGeometry) -> CGFloat { g.notchHeight + 8 }

    /// Portrait terminals grid: 2 columns, grows a row per 2 tabs (up to 5 rows for 10 tabs).
    static func terminalGridHeight(_ count: Int) -> CGFloat { 32 + CGFloat((max(count, 1) + 1) / 2) * 29 }

    static func expandedHeight(_ dock: IslandDock, header: CGFloat, answer: Bool, terminals: Bool = false,
                               terminalCount: Int = 0, transcript: Bool = false) -> CGFloat {
        let body: CGFloat = dock == .notch
            // 10 + now playing 84 + 10 + apps 56 + 10 + claude 38 + bottom 14 (the rail sits beside these)
            ? 222
            // 10 + now playing 156 + 10 + live 76 + 10 + apps grid 116 + 10 + claude 38 + bottom 14
            // (+ terminals grid + 10)
            : 440 + (terminals ? terminalGridHeight(terminalCount) + 10 : 0)
        // The conversation panel replaces the answer panel while a tab is selected.
        let below: CGFloat = transcript ? transcriptHeight(dock) + 10 : (answer ? answerHeight + 10 : 0)
        return header + body + below
    }
}
