import AppKit
import CoreGraphics

/// Fires when you press ⌘ and ⌥ together and let go *without* pressing any other key or
/// clicking (so ⌘⌥Esc, ⌘⌥-click etc. never trigger it).
///
/// Watching modifier keys system-wide needs macOS "Input Monitoring" permission; we use a
/// listen-only event tap, so Notchi can never block or change your typing.
final class ModifierChord {
    static let shared = ModifierChord()

    var action: (() -> Void)?
    private(set) var isRunning = false
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var armed = false
    private var spoiled = false
    private var armedAt = 0.0
    private var retryTimer: Timer?

    static var hasPermission: Bool { CGPreflightListenEventAccess() }

    /// Shows macOS's "allow Input Monitoring" prompt (only the first time).
    static func requestPermission() { CGRequestListenEventAccess() }

    static func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Starts listening (asking for permission if needed). Keeps retrying quietly until the
    /// permission is granted, so it starts working as soon as you flip the switch.
    func start(action: @escaping () -> Void) {
        self.action = action
        TerminalTabs.debugLog("chord: start, input-monitoring permission=\(Self.hasPermission)")
        if tryStart() { return }
        if !Self.hasPermission { Self.requestPermission() }
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] t in
            if self?.tryStart() == true { t.invalidate() }
        }
    }

    @discardableResult
    private func tryStart() -> Bool {
        guard tap == nil else { return true }
        guard Self.hasPermission else { return false }
        let types: [CGEventType] = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                if let refcon {
                    Unmanaged<ModifierChord>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            TerminalTabs.debugLog("chord: CGEvent.tapCreate failed (permission=\(Self.hasPermission))")
            return false
        }
        self.tap = tap
        TerminalTabs.debugLog("chord: listening for ⌘⌥")
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isRunning = true
        return true
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .flagsChanged:
            let f = event.flags
            let cmd = f.contains(.maskCommand), opt = f.contains(.maskAlternate)
            let extra = f.contains(.maskControl) || f.contains(.maskShift)
            let now = ProcessInfo.processInfo.systemUptime
            if cmd && opt && !extra {
                if !armed { armed = true; spoiled = false; armedAt = now }
            } else if armed {
                if extra { spoiled = true }
                if !cmd && !opt {
                    // Both let go: a clean, quick ⌘⌥ tap toggles the island.
                    if !spoiled && now - armedAt < 1.2 {
                        DispatchQueue.main.async { [weak self] in self?.action?() }
                    }
                    armed = false
                }
            }
        default:
            // Any key or click while ⌘⌥ is held means it was part of another shortcut.
            if armed { spoiled = true }
        }
    }
}
