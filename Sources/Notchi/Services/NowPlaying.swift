import AppKit
import SwiftUI

/// Spotify + Apple Music, via their distributed notifications (no private frameworks)
/// and AppleScript for artwork and transport controls.
final class NowPlayingService: NSObject, ObservableObject {
    enum Source: String {
        case spotify, music
        var bundleID: String { self == .spotify ? "com.spotify.client" : "com.apple.Music" }
        var appName: String { self == .spotify ? "Spotify" : "Music" }
        var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty }
        var isInstalled: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil }
    }

    struct Track: Equatable {
        var id: String
        var title: String
        var artist: String
        var album: String
        var duration: Double
        var position: Double
        var positionDate: Date
        var isPlaying: Bool
        var source: Source

        func position(at date: Date) -> Double {
            guard isPlaying else { return position }
            return min(duration, position + date.timeIntervalSince(positionDate))
        }
    }

    @Published private(set) var track: Track?
    @Published private(set) var artwork: NSImage?
    @Published private(set) var tint: Color = Color(hex: 0xF6A65A)

    var onTrackChange: ((Track) -> Void)?
    private let scriptQueue = DispatchQueue(label: "notchi.applescript")

    override init() {
        super.init()
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(self, selector: #selector(spotifyChanged(_:)),
                        name: NSNotification.Name("com.spotify.client.PlaybackStateChanged"),
                        object: nil, suspensionBehavior: .deliverImmediately)
        dnc.addObserver(self, selector: #selector(musicChanged(_:)),
                        name: NSNotification.Name("com.apple.Music.playerInfo"),
                        object: nil, suspensionBehavior: .deliverImmediately)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(appTerminated(_:)),
                                                          name: NSWorkspace.didTerminateApplicationNotification,
                                                          object: nil)
        refreshFromRunningPlayers()
    }

    // MARK: - Notifications

    @objc private func spotifyChanged(_ n: Notification) {
        let u = n.userInfo ?? [:]
        let state = u["Player State"] as? String ?? ""
        if state == "Stopped" { clear(.spotify); return }
        let t = Track(id: u["Track ID"] as? String ?? "",
                      title: u["Name"] as? String ?? "",
                      artist: u["Artist"] as? String ?? "",
                      album: u["Album"] as? String ?? "",
                      duration: num(u["Duration"]) / 1000,
                      position: num(u["Playback Position"]),
                      positionDate: Date(),
                      isPlaying: state == "Playing",
                      source: .spotify)
        apply(t)
    }

    @objc private func musicChanged(_ n: Notification) {
        let u = n.userInfo ?? [:]
        let state = u["Player State"] as? String ?? ""
        if state == "Stopped" { clear(.music); return }
        var t = Track(id: (u["PersistentID"] as? String) ?? String(describing: u["PersistentID"] ?? u["Name"] ?? ""),
                      title: u["Name"] as? String ?? "",
                      artist: u["Artist"] as? String ?? "",
                      album: u["Album"] as? String ?? "",
                      duration: num(u["Total Time"]) / 1000,
                      position: track?.source == .music ? track?.position(at: Date()) ?? 0 : 0,
                      positionDate: Date(),
                      isPlaying: state == "Playing",
                      source: .music)
        if t.id.isEmpty { t.id = t.title + t.artist }
        apply(t)
        // Music doesn't include the playhead in its notification.
        runScript(#"tell application "Music" to return player position as string"#) { [weak self] s, _ in
            guard let self, let s, let pos = Double(s.replacingOccurrences(of: ",", with: ".")),
                  var cur = self.track, cur.source == .music else { return }
            cur.position = pos
            cur.positionDate = Date()
            self.track = cur
        }
    }

    @objc private func appTerminated(_ n: Notification) {
        guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        if app.bundleIdentifier == Source.spotify.bundleID { clear(.spotify) }
        if app.bundleIdentifier == Source.music.bundleID { clear(.music) }
    }

    private func apply(_ t: Track) {
        // Don't let a paused player steal the card from one that's playing.
        if let cur = track, cur.source != t.source, cur.isPlaying, !t.isPlaying { return }
        let changed = track?.id != t.id || track?.source != t.source
        track = t
        if changed {
            artwork = nil
            loadArtwork(for: t)
            if t.isPlaying { onTrackChange?(t) }
        }
    }

    private func clear(_ source: Source) {
        guard track?.source == source else { return }
        track = nil
        artwork = nil
    }

    // MARK: - Initial state

    private func refreshFromRunningPlayers() {
        if Source.spotify.isRunning {
            let script = """
            tell application "Spotify"
              if player state is stopped then return "stopped"
              set t to current track
              return (player state as string) & "|||" & (name of t) & "|||" & (artist of t) & "|||" & (album of t) & "|||" & (duration of t) & "|||" & (player position) & "|||" & (id of t)
            end tell
            """
            runScript(script) { [weak self] s, _ in self?.applyScriptState(s, source: .spotify, durationScale: 1000) }
        }
        if Source.music.isRunning {
            let script = """
            tell application "Music"
              if player state is stopped then return "stopped"
              set t to current track
              return (player state as string) & "|||" & (name of t) & "|||" & (artist of t) & "|||" & (album of t) & "|||" & ((duration of t) as string) & "|||" & (player position as string) & "|||" & (persistent ID of t)
            end tell
            """
            runScript(script) { [weak self] s, _ in self?.applyScriptState(s, source: .music, durationScale: 1) }
        }
    }

    private func applyScriptState(_ s: String?, source: Source, durationScale: Double) {
        guard let s else { return }
        let p = s.components(separatedBy: "|||")
        guard p.count >= 7 else { return }
        let d = { (x: String) in Double(x.replacingOccurrences(of: ",", with: ".")) ?? 0 }
        apply(Track(id: p[6], title: p[1], artist: p[2], album: p[3],
                    duration: d(p[4]) / durationScale, position: d(p[5]), positionDate: Date(),
                    isPlaying: p[0] == "playing", source: source))
    }

    // MARK: - Artwork

    private func loadArtwork(for t: Track) {
        switch t.source {
        case .spotify:
            runScript(#"tell application "Spotify" to return artwork url of current track"#) { [weak self] s, _ in
                guard let s, let url = URL(string: s) else { return }
                URLSession.shared.dataTask(with: url) { data, _, _ in
                    guard let data, let img = NSImage(data: data) else { return }
                    DispatchQueue.main.async { self?.setArtwork(img, for: t) }
                }.resume()
            }
        case .music:
            let script = """
            tell application "Music"
              try
                return raw data of artwork 1 of current track
              on error
                return data of artwork 1 of current track
              end try
            end tell
            """
            runScript(script) { [weak self] _, data in
                guard let data, let img = NSImage(data: data) else { return }
                self?.setArtwork(img, for: t)
            }
        }
    }

    private func setArtwork(_ img: NSImage, for t: Track) {
        guard track?.id == t.id else { return }
        artwork = img
        if let c = img.vibrantAverageColor { tint = Color(nsColor: c) }
    }

    // MARK: - Controls

    func playPause() {
        guard var t = track else { return }
        send("playpause")
        t.position = t.position(at: Date())
        t.positionDate = Date()
        t.isPlaying.toggle()
        track = t
    }
    func next() { send("next track") }
    func previous() { send("previous track") }

    func seek(to seconds: Double) {
        guard var t = track else { return }
        send("set player position to \(String(format: "%.2f", seconds))")
        t.position = seconds
        t.positionDate = Date()
        track = t
    }

    func openPlayer(_ source: Source) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: source.bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    private func send(_ command: String) {
        guard let src = track?.source, src.isRunning else { return }
        runScript("tell application \"\(src.appName)\" to \(command)")
    }

    // MARK: - Helpers

    private func runScript(_ source: String, completion: ((String?, Data?) -> Void)? = nil) {
        scriptQueue.async {
            var err: NSDictionary?
            let result = NSAppleScript(source: source)?.executeAndReturnError(&err)
            let s = err == nil ? result?.stringValue : nil
            let d = err == nil ? result?.data : nil
            if let completion { DispatchQueue.main.async { completion(s, d) } }
        }
    }

    private func num(_ v: Any?) -> Double {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) ?? 0 }
        return 0
    }
}

extension NSImage {
    /// Average colour, nudged to be vivid enough to glow on black.
    var vibrantAverageColor: NSColor? {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil),
              let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let p = data.assumingMemoryBound(to: UInt8.self)
        let c = NSColor(srgbRed: CGFloat(p[0]) / 255, green: CGFloat(p[1]) / 255, blue: CGFloat(p[2]) / 255, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.usingColorSpace(.sRGB)?.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return NSColor(hue: h, saturation: max(s, 0.45), brightness: max(b, 0.8), alpha: 1)
    }
}
