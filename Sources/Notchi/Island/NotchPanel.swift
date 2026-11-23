import AppKit
import SwiftUI

/// A transparent, borderless panel that floats above the menu bar on every Space.
final class NotchPanel: NSPanel {
    init(frame: NSRect) {
        super.init(contentRect: frame,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // Set before `level`: assigning isFloatingPanel resets the level to .floating (3), which
        // put the island *under* the menu bar, so status icons drew on top of it.
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        ignoresMouseEvents = true
        acceptsMouseMovedEvents = true
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// AppKit normally pushes windows below the menu bar. We need to sit *in* it, behind the notch.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    /// The island opens on hover without becoming key (so it never steals your typing).
    /// Become key the moment you press the mouse, so that first click lands on the button
    /// instead of being swallowed as a "window activation" click.
    override func sendEvent(_ event: NSEvent) {
        if !ignoresMouseEvents, !isKeyWindow,
           event.type == .leftMouseDown || event.type == .rightMouseDown || event.type == .otherMouseDown {
            makeKey()
        }
        super.sendEvent(event)
    }
}

extension View {
    /// macOS 15+: let buttons/taps handle the click that also activates the window.
    @ViewBuilder func acceptsActivationClicks() -> some View {
        if #available(macOS 15.0, *) {
            self.allowsWindowActivationEvents(true)
        } else {
            self
        }
    }
}

/// Full-screen dim + blur that sits behind the open island (and over the menu bar icons),
/// so the island reads cleanly. Never takes clicks.
final class BackdropPanel: NSPanel {
    private let blur = NSVisualEffectView()
    private let dim = NSView()

    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isFloatingPanel = true
        // Above the menu bar and its status icons (25), below the island (27).
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        animationBehavior = .none
        alphaValue = 0

        let root = NSView(frame: NSRect(origin: .zero, size: frame.size))
        root.autoresizingMask = [.width, .height]
        blur.frame = root.bounds
        blur.autoresizingMask = [.width, .height]
        blur.material = .fullScreenUI
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.appearance = NSAppearance(named: .darkAqua)
        dim.frame = root.bounds
        dim.autoresizingMask = [.width, .height]
        dim.wantsLayer = true
        dim.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.28).cgColor
        root.addSubview(blur)
        root.addSubview(dim)
        contentView = root
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    /// 0…1. The system blur can't be given a radius, so we fade it: at 0.35 you mostly see
    /// your screen with a soft haze; at 1 it's the full frosted look.
    func setStrength(_ v: Double) {
        let t = CGFloat(min(max(v, 0), 1))
        blur.alphaValue = t
        dim.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.06 + 0.24 * t).cgColor
    }

    /// Fades in under `above` (ordered just below that window), or fades out.
    func show(_ visible: Bool, below above: NSWindow?) {
        if visible {
            if let above { order(.below, relativeTo: above.windowNumber) } else { orderFrontRegardless() }
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = visible ? 0.22 : 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = visible ? 1 : 0
        }, completionHandler: { [weak self] in
            guard let self, !visible, self.alphaValue == 0 else { return }
            self.orderOut(nil)
        })
    }
}

/// Holds only the island's Liquid Glass surface, directly behind the island window.
/// It can never become key, so macOS keeps drawing the glass in its light, see-through
/// style even while you're typing in the island (which *is* key).
final class SurfacePanel: NSPanel {
    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        animationBehavior = .none
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Lets the first click on a button work even when the panel isn't key yet.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The island docked to the left screen edge: flush left with concave flares that melt
/// into the edge (the notch silhouette turned on its side), rounded on the right.
struct EdgeShape: Shape {
    var flare: CGFloat
    var radius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(flare, radius) }
        set { flare = newValue.first; radius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let tr = min(flare, rect.height / 4, rect.width / 2)
        let br = max(0, min(radius, (rect.height - 2 * tr) / 2, rect.width - tr))
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + tr, y: rect.minY + tr),
                       control: CGPoint(x: rect.minX, y: rect.minY + tr))
        p.addLine(to: CGPoint(x: rect.maxX - br, y: rect.minY + tr))
        p.addCurve(to: CGPoint(x: rect.maxX, y: rect.minY + tr + br),
                   control1: CGPoint(x: rect.maxX - br * 0.45, y: rect.minY + tr),
                   control2: CGPoint(x: rect.maxX, y: rect.minY + tr + br * 0.45))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - tr - br))
        p.addCurve(to: CGPoint(x: rect.maxX - br, y: rect.maxY - tr),
                   control1: CGPoint(x: rect.maxX, y: rect.maxY - tr - br * 0.45),
                   control2: CGPoint(x: rect.maxX - br * 0.45, y: rect.maxY - tr))
        p.addLine(to: CGPoint(x: rect.minX + tr, y: rect.maxY - tr))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY),
                       control: CGPoint(x: rect.minX, y: rect.maxY - tr))
        p.closeSubpath()
        return p
    }
}

/// The island silhouette: flat top with concave "shoulders" that melt into the
/// screen edge, and rounded bottom corners — like the hardware notch.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let tr = min(topRadius, rect.width / 4, rect.height / 2)
        let br = max(0, min(bottomRadius, (rect.width - 2 * tr) / 2, rect.height - tr))
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + tr, y: rect.minY + tr),
                       control: CGPoint(x: rect.minX + tr, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + tr, y: rect.maxY - br))
        p.addCurve(to: CGPoint(x: rect.minX + tr + br, y: rect.maxY),
                   control1: CGPoint(x: rect.minX + tr, y: rect.maxY - br * 0.45),
                   control2: CGPoint(x: rect.minX + tr + br * 0.45, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - tr - br, y: rect.maxY))
        p.addCurve(to: CGPoint(x: rect.maxX - tr, y: rect.maxY - br),
                   control1: CGPoint(x: rect.maxX - tr - br * 0.45, y: rect.maxY),
                   control2: CGPoint(x: rect.maxX - tr, y: rect.maxY - br * 0.45))
        p.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY + tr))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                       control: CGPoint(x: rect.maxX - tr, y: rect.minY))
        p.closeSubpath()
        return p
    }
}
