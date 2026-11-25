import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private(set) var controller: IslandController!
    private var statusItem: NSStatusItem!
    private var pendingURLs: [URL] = []
    private var dockItems: [IslandDock: NSMenuItem] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = IslandController()
        controller.start()
        setupStatusItem()
        HotKey.shared.register { [weak self] in self?.controller.toggleFromHotkey() }
        // ⌘⌥ (press and release together) also toggles the island.
        ModifierChord.shared.start { [weak self] in self?.controller.toggleFromHotkey() }
        pendingURLs.forEach { controller.handle(url: $0) }
        pendingURLs = []
    }

    func applicationWillTerminate(_ notification: Notification) {
        ActivityMonitor.shared.saveForLater()
        BackendLauncher.stop()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let controller else { pendingURLs.append(contentsOf: urls); return }
        urls.forEach { controller.handle(url: $0) }
    }

    // MARK: - Menu bar item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "Notchi")

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(item("Open Island", #selector(openIsland), key: ""))

        let position = NSMenuItem(title: "Island Position", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for d in IslandDock.allCases {
            let i = item(d.label, #selector(chooseDock(_:)), key: "")
            i.representedObject = d.rawValue
            i.image = NSImage(systemSymbolName: d.symbol, accessibilityDescription: nil)
            dockItems[d] = i
            sub.addItem(i)
        }
        position.submenu = sub
        menu.addItem(position)

        menu.addItem(item("Settings…", #selector(openSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(item("Quit Notchi", #selector(quit), key: "q"))
        statusItem.menu = menu
    }

    private func item(_ title: String, _ action: Selector, key: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    func menuWillOpen(_ menu: NSMenu) {
        for (d, i) in dockItems { i.state = AppSettings.shared.dock == d ? .on : .off }
    }

    @objc private func chooseDock(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let d = IslandDock(rawValue: raw) else { return }
        AppSettings.shared.dock = d
    }

    @objc private func openIsland() { controller.open(.programmatic) }
    @objc private func openSettings() { controller.openSettings() }
    @objc private func quit() { NSApp.terminate(nil) }
}
