import AppKit
import UniformTypeIdentifiers

struct PinnedApp: Identifiable, Equatable {
    let url: URL
    let name: String
    let icon: NSImage
    var id: String { url.path }

    init(url: URL) {
        self.url = url
        name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        icon = NSWorkspace.shared.icon(forFile: url.path)
    }

    static func == (a: PinnedApp, b: PinnedApp) -> Bool { a.url == b.url }
}

/// The user's pinned apps, launched from the island (⌘1–⌘9 while it's open).
final class AppShelf: ObservableObject {
    @Published private(set) var apps: [PinnedApp] = []
    private let key = "pinnedApps"
    static let maxApps = 10

    init() {
        let fm = FileManager.default
        if let paths = UserDefaults.standard.array(forKey: key) as? [String] {
            apps = paths.filter { fm.fileExists(atPath: $0) }.map { PinnedApp(url: URL(fileURLWithPath: $0)) }
        } else {
            let seed = ["/Applications/Safari.app", "/System/Applications/Notes.app",
                        "/System/Applications/Calendar.app", "/System/Applications/Utilities/Terminal.app",
                        "/Applications/Spotify.app", "/Applications/Claude.app"]
            apps = seed.filter { fm.fileExists(atPath: $0) }.map { PinnedApp(url: URL(fileURLWithPath: $0)) }
            save()
        }
    }

    func add(_ url: URL) {
        guard url.pathExtension == "app", !apps.contains(where: { $0.url.path == url.path }),
              apps.count < Self.maxApps else { return }
        apps.append(PinnedApp(url: url))
        save()
    }

    func remove(_ app: PinnedApp) {
        apps.removeAll { $0 == app }
        save()
    }

    func launch(_ app: PinnedApp) {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: app.url, configuration: cfg)
    }

    @discardableResult
    func launch(at index: Int) -> Bool {
        guard apps.indices.contains(index) else { return false }
        launch(apps[index])
        return true
    }

    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for p in providers where p.canLoadObject(ofClass: URL.self) {
            accepted = true
            _ = p.loadObject(ofClass: URL.self) { [weak self] url, _ in
                guard let url else { return }
                DispatchQueue.main.async { self?.add(url) }
            }
        }
        return accepted
    }

    func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        panel.prompt = "Pin"
        panel.message = "Choose apps to pin to the island"
        NSApp.activate()
        panel.begin { [weak self] resp in
            guard resp == .OK else { return }
            panel.urls.forEach { self?.add($0) }
        }
    }

    private func save() {
        UserDefaults.standard.set(apps.map(\.url.path), forKey: key)
    }
}
