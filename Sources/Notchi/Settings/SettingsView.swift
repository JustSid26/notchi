import AppKit
import ServiceManagement
import SwiftUI

final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show(controller: IslandController) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 720),
                             styleMask: [.titled, .closable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Notchi"
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView(settings: controller.settings,
                                                                 claude: controller.claude,
                                                                 cat: controller.cat,
                                                                 terminals: controller.terminals))
            w.center()
            window = w
        }
        controller.claude.refreshClaudeCode()
        controller.terminals.poll(force: true)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var claude: ClaudeSession
    let cat: CatEngine
    @ObservedObject var terminals: TerminalTabs
    @State private var keyDraft = ""
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var cliStatus: String?
    @State private var previewCat = CatEngine()   // not observed: the preview drives itself
    @State private var hooksInstalled = ClaudeHooks.isInstalled()
    @State private var hooksStatus: String?
    @State private var cliInstalled = FileManager.default.fileExists(atPath: ClaudeHooks.cliPath)
    @State private var colorSetupRunning = false
    private var chordReady: Bool { ModifierChord.hasPermission }
    @State private var colorTick = 0

    private func setUpColors() {
        colorSetupRunning = true
        ItermColorBridge.install { result in
            colorSetupRunning = false
            if case .failure(let e) = result { hooksStatus = "Colour setup failed: \(e.localizedDescription)" }
            terminals.refreshColors(force: true)
            colorTick += 1
        }
    }

    private func toggleHooks(_ on: Bool) {
        do {
            if on { try ClaudeHooks.install() } else { try ClaudeHooks.uninstall() }
            hooksInstalled = ClaudeHooks.isInstalled()
            hooksStatus = on ? "Hooks added. New Claude Code sessions will report to Notchi." : "Hooks removed."
        } catch {
            hooksStatus = error.localizedDescription
        }
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    Spacer()
                    CatPreview(engine: previewCat, palette: settings.palette, species: settings.pet)
                        .frame(width: 150, height: 110)
                    Spacer()
                }
                Picker("Pet", selection: $settings.pet) {
                    ForEach(Pet.allCases) { Text("\($0.emoji) \($0.name)").tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Show the \(settings.pet.name.lowercased())", isOn: $settings.showCat)
                switch settings.pet {
                case .cat:
                    Picker("Coat", selection: $settings.coat) {
                        ForEach(CatCoat.allCases) { Text($0.name).tag($0) }
                    }
                case .dog:
                    Picker("Breed", selection: $settings.dogCoat) {
                        ForEach(DogCoat.allCases) { Text($0.name).tag($0) }
                    }
                case .bird:
                    Picker("Bird", selection: $settings.birdCoat) {
                        ForEach(BirdCoat.allCases) { Text($0.name).tag($0) }
                    }
                }
                LabeledContent("Size") {
                    Slider(value: $settings.catSize, in: 0.8...1.8)
                }
                LabeledContent("Wander range") {
                    Slider(value: $settings.walkRange, in: 60...260)
                }
            } header: { Text("Pet") }

            Section {
                LabeledContent("Theme") {
                    HStack(spacing: 8) {
                        ForEach(IslandTheme.allCases) { t in
                            Button { settings.theme = t } label: {
                                ZStack {
                                    Circle().fill(t.base).frame(width: 22, height: 22)
                                        .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
                                    Circle().fill(t.accent).frame(width: 10, height: 10)
                                }
                                .padding(2)
                                .overlay(Circle().strokeBorder(settings.theme == t ? t.accent : .clear, lineWidth: 2))
                            }
                            .buttonStyle(.plain)
                            .help(t.name)
                        }
                    }
                }
                Text(settings.theme.name).font(.caption).foregroundStyle(.secondary)
                Picker("Style", selection: $settings.islandStyle) {
                    ForEach(IslandStyle.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
                LabeledContent("Transparency") {
                    HStack {
                        Text("Clear").font(.caption).foregroundStyle(.secondary)
                        Slider(value: $settings.islandOpacity, in: 0.2...1.0)
                        Text("Opaque").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle("Blur the screen behind the open island", isOn: $settings.dimBehindIsland)
                if settings.dimBehindIsland {
                    LabeledContent("Blur strength") {
                        HStack {
                            Text("Light").font(.caption).foregroundStyle(.secondary)
                            Slider(value: $settings.backdropStrength, in: 0.05...1)
                            Text("Heavy").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: { Text("Appearance") } footer: {
                Text("Frosted and Liquid Glass let your wallpaper show through the island; drag Transparency towards Clear to see more of it.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Picker("Position", selection: $settings.dock) {
                    ForEach(IslandDock.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.radioGroup)
                if settings.dock == .left {
                    LabeledContent("Height on screen") {
                        HStack {
                            Text("Top").font(.caption).foregroundStyle(.secondary)
                            Slider(value: $settings.edgePosition, in: 0.1...0.9)
                            Text("Bottom").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: { Text("Island") } footer: {
                Text(settings.dock == .left
                     ? "Push your cursor against the left edge of the screen to open the island."
                     : "Hover the notch (or the cat) to open the island.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Picker("Use", selection: $settings.provider) {
                    ForEach(ClaudeProvider.allCases) { Text($0.label).tag($0) }
                }
                if claude.hasAPIKey {
                    LabeledContent("API key") {
                        HStack {
                            Label("Saved in Keychain", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                            Button("Remove") { claude.removeAPIKey() }
                        }
                    }
                } else {
                    HStack {
                        SecureField("sk-ant-…", text: $keyDraft)
                        Button("Save") { claude.saveAPIKey(keyDraft); keyDraft = "" }
                            .disabled(keyDraft.isEmpty)
                    }
                    Link("Get an API key at platform.claude.com",
                         destination: URL(string: "https://platform.claude.com/settings/keys")!)
                        .font(.caption)
                }
                TextField("Model", text: $settings.model)
                LabeledContent("Claude Code") {
                    Text(claude.claudeCodePath ?? "Not found").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            } header: { Text("Claude") } footer: {
                Text("API usage is billed to your Anthropic account. “Local Claude Code” runs the `claude` CLI you already have installed.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Open the island") {
                    HStack {
                        Text("⌘⌥ (tap together) · \(HotKey.shared.label)").foregroundStyle(.secondary)
                        if !chordReady {
                            Button("Allow ⌘⌥…") {
                                ModifierChord.requestPermission()
                                ModifierChord.openPrivacySettings()
                            }
                        }
                    }
                }
                if !chordReady {
                    Text("⌘⌥ needs Input Monitoring: System Settings → Privacy & Security → Input Monitoring → turn on Notchi. ⌥Space works without it.")
                        .font(.caption).foregroundStyle(.orange)
                }
                LabeledContent("Launch pinned apps", value: "⌘1 – ⌘9")
                LabeledContent("Close", value: "Esc")
                HStack {
                    Button("Install `island` command") { installCLI() }
                    if let cliStatus { Text(cliStatus).font(.caption).foregroundStyle(.secondary) }
                }
            } header: { Text("Shortcuts & command line") }

            Section {
                LabeledContent("Step 1") {
                    HStack {
                        Text(cliInstalled ? "`island` command installed" : "Install the `island` command")
                            .foregroundStyle(cliInstalled ? .green : .primary)
                        Spacer()
                        Button(cliInstalled ? "Reinstall" : "Install") { installCLI() }
                    }
                }
                LabeledContent("Step 2") {
                    HStack {
                        Text(hooksInstalled ? "Claude Code connected" : "Connect Claude Code")
                            .foregroundStyle(hooksInstalled ? .green : .primary)
                        Spacer()
                        if hooksInstalled {
                            Button("Disconnect") { toggleHooks(false) }
                        } else {
                            Button("Connect") { toggleHooks(true) }.disabled(!cliInstalled)
                        }
                    }
                }
                if let hooksStatus { Text(hooksStatus).font(.caption).foregroundStyle(.secondary) }
                Toggle("Play a sound when Claude finishes", isOn: $settings.claudeSound)
                LabeledContent("Tab colours") {
                    HStack {
                        if colorSetupRunning {
                            ProgressView().controlSize(.small)
                            Text("Setting up… (about 20 s)").foregroundStyle(.secondary)
                        } else if !ItermColorBridge.isInstalled {
                            Text("Match iTerm2's tab colours").foregroundStyle(.primary)
                            Spacer()
                            Button("Set up") { setUpColors() }
                        } else if !ItermColorBridge.apiEnabled {
                            Text("Turn on iTerm2 → Settings → General → Magic → Enable Python API")
                                .font(.caption).foregroundStyle(.orange)
                            Spacer()
                            Button("Check again") { terminals.refreshColors(force: true); colorTick += 1 }
                        } else if let problem = terminals.colorProblem, problem != "setup", problem != "api" {
                            Text(problem).font(.caption).foregroundStyle(.orange).lineLimit(2)
                            Spacer()
                            Button("Retry") { terminals.refreshColors(force: true) }
                        } else {
                            Text("Matching your iTerm2 tab colours").foregroundStyle(.green)
                        }
                    }
                    .id(colorTick)
                }
                LabeledContent("Tabs on the island") {
                    HStack {
                        Text("\(terminals.tabs.count) of \(TerminalTabs.maxTabs)").foregroundStyle(.secondary)
                        Button("Refresh") { terminals.poll(force: true) }
                    }
                }
                if terminals.openSessions.isEmpty {
                    Text("No iTerm2 tabs found. Open iTerm2, then click Refresh (allow Notchi to control iTerm2 if asked).")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(terminals.openSessions) { s in
                        let pinned = terminals.isPinned(s)
                        Toggle(isOn: Binding(get: { pinned }, set: { _ in terminals.togglePin(s) })) {
                            Text(s.name.isEmpty ? (s.tty as NSString).lastPathComponent : s.name).lineLimit(1)
                        }
                        .disabled(!pinned && terminals.isFull)
                    }
                }
            } header: { Text("Terminal tabs") } footer: {
                Text("Tick up to 10 tabs above, or use the terminal button in the island header. Notchi shows a spinner while Claude works in a tab, tells you when it's done or needs approval, and lets you type prompts into that tab from the island. Connecting adds hooks to ~/.claude/settings.json (a backup is saved next to it); start new Claude sessions to pick them up.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            BackendSection(settings: settings, backend: Backend.shared)

            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            } header: { Text("General") }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 720)
        .onAppear { previewCat.setPose(stand: 1, happy: 1, time: 0) }
    }

    private func installCLI() {
        guard let src = Bundle.main.url(forResource: "island", withExtension: nil) else {
            cliStatus = "Run from the built Notchi.app"
            return
        }
        let fm = FileManager.default
        let dir = fm.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin", isDirectory: true)
        let dst = dir.appendingPathComponent("island")
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try? fm.removeItem(at: dst)
            try fm.createSymbolicLink(at: dst, withDestinationURL: src)
            cliStatus = "Installed to ~/.local/bin/island"
            cliInstalled = true
        } catch {
            cliStatus = error.localizedDescription
        }
    }
}

/// A live, looping cat in Settings so you can see the coat you pick.
struct CatPreview: View {
    let engine: CatEngine
    let palette: CatPalette
    var species: Pet = .cat

    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            Canvas { gctx, size in
                let k = size.height / (CatRenderer.unitH + 6)
                engine.species = species
                engine.setPose(sit: 0.5 + 0.5 * sin(t * 0.5), stand: max(0, -sin(t * 0.5)) * 0.9,
                               blink: (t.truncatingRemainder(dividingBy: 4) < 0.15) ? 1 : 0,
                               happy: 0.6, lookX: CGFloat(sin(t * 0.8)) * 0.6, time: t)
                CatRenderer.draw(in: &gctx, engine: engine, palette: palette,
                                 anchor: CGPoint(x: (size.width - CatRenderer.unitW * k) / 2 + CatRenderer.pivotX * k,
                                                 y: (6 + CatRenderer.ground) * k), k: k)
            }
        }
    }
}
