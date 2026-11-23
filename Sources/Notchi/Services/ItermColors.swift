import AppKit
import SwiftUI

/// Reads each iTerm2 tab's colour (the one you set with right-click → Tab Color).
/// AppleScript can't see tab colours, so this uses iTerm2's Python API through a tiny
/// script, run in Notchi's own private Python environment.
enum ItermColorBridge {
    private static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Notchi/python", isDirectory: true)
    }
    private static var python: URL { root.appendingPathComponent("bin/python3") }
    private static var readyMarker: URL { root.appendingPathComponent(".iterm2-ready") }

    /// Notchi's private environment has the `iterm2` package.
    static var isInstalled: Bool { FileManager.default.fileExists(atPath: readyMarker.path) }

    /// iTerm2 → Settings → General → Magic → "Enable Python API".
    static var apiEnabled: Bool {
        UserDefaults(suiteName: "com.googlecode.iterm2")?.bool(forKey: "EnableAPIServer") ?? false
    }

    private static func basePython() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3", "\(home)/.pyenv/shims/python3"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Creates the private environment and installs `iterm2` (one-time, needs internet, ~20 s).
    static func install(completion: @escaping (Result<Void, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                guard let base = basePython() else { throw message("Couldn't find python3 on this Mac.") }
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                if !FileManager.default.isExecutableFile(atPath: python.path) {
                    try run(base, ["-m", "venv", root.path])
                }
                try run(python.path, ["-m", "pip", "install", "--quiet", "--disable-pip-version-check", "iterm2"])
                try Data().write(to: readyMarker)
                DispatchQueue.main.async { completion(.success(())) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    /// Returns iTerm2 session id → tab colour. `cookieAndKey` comes from AppleScript
    /// (`request cookie and key for app named "Notchi"`), which iTerm2 grants because Notchi
    /// already has Automation permission for it.
    static func fetchColors(cookieAndKey: String) throws -> [String: Color] {
        guard let script = Bundle.main.url(forResource: "iterm_tabs", withExtension: "py") else {
            throw message("Color script missing from the app bundle.")
        }
        let parts = cookieAndKey.split(separator: " ").map(String.init)
        guard parts.count >= 2 else { throw message("iTerm2 didn't hand out an API key.") }
        var env = ProcessInfo.processInfo.environment
        env["ITERM2_COOKIE"] = parts[0]
        env["ITERM2_KEY"] = parts[1]
        let out = try run(python.path, [script.path], env: env, timeout: 8)
        guard let line = out.split(separator: "\n").last(where: { $0.hasPrefix("[") }),
              let items = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [[String: Any]] else {
            throw message("Unexpected output from iTerm2.")
        }
        var colors: [String: Color] = [:]
        for item in items {
            guard let id = item["id"] as? String, let c = item["color"] as? [NSNumber], c.count == 3 else { continue }
            colors[id] = Color(.sRGB, red: c[0].doubleValue / 255, green: c[1].doubleValue / 255,
                               blue: c[2].doubleValue / 255, opacity: 1)
        }
        return colors
    }

    // MARK: - Helpers

    @discardableResult
    private static func run(_ exe: String, _ args: [String], env: [String: String]? = nil,
                            timeout: TimeInterval = 180) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        if let env { p.environment = env }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        try p.run()
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if p.isRunning { p.terminate(); throw message("Timed out talking to iTerm2.") }
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if p.terminationStatus != 0 {
            let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let last = stderr.split(separator: "\n").last.map(String.init) ?? "exit \(p.terminationStatus)"
            throw message(last)
        }
        return stdout
    }

    private static func message(_ s: String) -> NSError {
        NSError(domain: "Notchi", code: 1, userInfo: [NSLocalizedDescriptionKey: s])
    }
}
