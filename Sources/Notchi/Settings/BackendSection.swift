import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings → Java backend: connection status, what each algorithm is doing right now, and
/// the parameters you can tune (Bloom filter size and false-positive rate, ETA history import).
struct BackendSection: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var backend: Backend
    @State private var expected = 10_000
    @State private var fpp = 0.01
    @State private var message: String?

    private static let expectedChoices = [1_000, 10_000, 100_000, 1_000_000]
    private static let fppChoices = [0.001, 0.01, 0.05]

    private func dict(_ path: String...) -> [String: Any] {
        var d: [String: Any]? = backend.stats
        for p in path { d = d?[p] as? [String: Any] }
        return d ?? [:]
    }

    private func num(_ d: [String: Any], _ k: String) -> Double { (d[k] as? NSNumber)?.doubleValue ?? 0 }

    private func int(_ d: [String: Any], _ k: String) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: Int(num(d, k))), number: .decimal)
    }

    private func pct(_ v: Double) -> String { String(format: v < 0.001 ? "%.3f%%" : "%.2f%%", v * 100) }

    var body: some View {
        Section {
            Toggle("Use the Java backend when it's running", isOn: $settings.useBackend)
            LabeledContent("Status") {
                if backend.connected {
                    Text("Connected · v\(backend.version ?? "?") · 127.0.0.1:7340").foregroundStyle(.green)
                } else if settings.useBackend {
                    Text("Not running").foregroundStyle(.secondary)
                } else {
                    Text("Off").foregroundStyle(.secondary)
                }
            }
            if backend.connected {
                let live = dict("live"), dedupe = dict("live", "dedupe")
                let launcher = dict("launcher"), runs = dict("durations")
                LabeledContent("LIVE queue") {
                    Text("\(int(live, "size")) activities · indexed binary heap")
                }
                LabeledContent("Duplicates") {
                    Text("\(int(dedupe, "received")) events · \(int(dedupe, "duplicatesDropped")) dropped · "
                         + "\(int(dedupe, "exactLookupsSkipped")) exact lookups skipped · "
                         + "\(int(dedupe, "falsePositives")) false positives")
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Bloom filter") {
                    Text("\(int(dedupe, "bits")) bits (\(int(dedupe, "bytes")) B) · k = \(int(dedupe, "hashes")) · "
                         + "\(pct(num(dedupe, "fillRatio"))) full · expected FPR \(pct(num(dedupe, "expectedFalsePositiveRate")))")
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Launcher") {
                    Text("\(int(launcher, "items")) items · trie of \(int(launcher, "trieNodes")) nodes")
                }
                LabeledContent("Claude ETA") {
                    Text("\(int(runs, "runs")) runs recorded · randomized Quickselect")
                }
                HStack {
                    Picker("Expected events", selection: $expected) {
                        ForEach(Self.expectedChoices, id: \.self) { n in
                            Text(NumberFormatter.localizedString(from: NSNumber(value: n), number: .decimal)).tag(n)
                        }
                    }
                    Picker("False positives", selection: $fpp) {
                        ForEach(Self.fppChoices, id: \.self) { p in Text(pct(p)).tag(p) }
                    }
                    .frame(width: 170)
                }
                HStack {
                    Button("Resize Bloom filter") {
                        backend.configureDedupe(expected: expected, fpp: fpp) { err in
                            message = err ?? "Bloom filter resized for \(expected) events at \(pct(fpp))"
                        }
                    }
                    Button("Import Claude run times…") { importCSV() }
                    Spacer()
                    Button("Refresh") { backend.refreshStats() }
                }
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            } else if settings.useBackend {
                Text("Start it from the repository:").font(.caption).foregroundStyle(.secondary)
                Text(Backend.startCommand).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
        } header: { Text("Java backend") } footer: {
            Text("Optional. When the backend runs, it orders the LIVE queue (heap), drops repeated events (Bloom filter + exact log), answers the launcher as you type in the Claude bar (trie), and estimates how long Claude usually takes in each tab (randomized Quickselect). Without it, Notchi works on its own.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { backend.refreshStats() }
    }

    private func importCSV() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.message = "Choose a CSV of past Claude runs: key,seconds (one run per line)"
        panel.begin { resp in
            guard resp == .OK, let url = panel.url else { return }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                message = "Couldn't read \(url.lastPathComponent)"
                return
            }
            backend.importDurations(csv: text) { message = $0 }
        }
    }
}
