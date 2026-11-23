import Foundation
import Security

// MARK: - Keychain

enum Keychain {
    private static let service = "dev.notchi.app"

    static func set(_ value: String, account: String) {
        delete(account: account)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                kSecValueData as String: Data(value.utf8)]
        SecItemAdd(q as CFDictionary, nil)
    }

    static func get(account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
    }
}

enum ClaudeCodeLocator {
    static func find() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
                          "\(home)/.claude/local/claude", "\(home)/.npm-global/bin/claude", "\(home)/.bun/bin/claude"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

// MARK: - Session

/// Ask Claude from the notch, through the Anthropic API (your key) or your local Claude Code install.
final class ClaudeSession: ObservableObject {
    struct Turn: Identifiable {
        let id = UUID()
        var question: String
        var answer: String = ""
        var failed = false
    }

    @Published var input = ""
    @Published private(set) var turns: [Turn] = []
    @Published private(set) var isStreaming = false
    @Published private(set) var hasAPIKey: Bool
    @Published private(set) var claudeCodePath: String?

    var hasAnswer: Bool { !turns.isEmpty }

    private let settings = AppSettings.shared
    private static let keyAccount = "anthropic-api-key"
    private var apiKey: String?
    private var task: Task<Void, Never>?
    private var process: Process?
    private var cliSessionID: String?

    private let systemPrompt = """
    You are Claude, answering inside Notchi — a small panel that drops down from the Mac's notch. \
    Keep answers short and skimmable: a few sentences or a compact list. Avoid big headings and tables.
    """

    init() {
        apiKey = Keychain.get(account: Self.keyAccount)
        hasAPIKey = apiKey != nil
        claudeCodePath = ClaudeCodeLocator.find()
    }

    // MARK: Settings

    func saveAPIKey(_ key: String) {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return }
        Keychain.set(k, account: Self.keyAccount)
        apiKey = k
        hasAPIKey = true
    }

    func removeAPIKey() {
        Keychain.delete(account: Self.keyAccount)
        apiKey = nil
        hasAPIKey = false
    }

    func refreshClaudeCode() { claudeCodePath = ClaudeCodeLocator.find() }

    private enum Route { case api(String), cli(String), unavailable(String) }

    private func route() -> Route {
        switch settings.provider {
        case .api:
            return apiKey.map { .api($0) } ?? .unavailable("Add your Anthropic API key in Settings.")
        case .claudeCode:
            return claudeCodePath.map { .cli($0) }
                ?? .unavailable("Claude Code isn't installed (looked in ~/.local/bin, /opt/homebrew/bin, /usr/local/bin).")
        case .auto:
            if let k = apiKey { return .api(k) }
            if let p = claudeCodePath { return .cli(p) }
            return .unavailable("Add an Anthropic API key in Settings, or install Claude Code.")
        }
    }

    var providerLabel: String {
        switch route() {
        case .api: return "API"
        case .cli: return "Claude Code"
        case .unavailable: return "Set up"
        }
    }

    // MARK: Asking

    func send() {
        let q = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !isStreaming else { return }
        input = ""
        ask(q)
    }

    func ask(_ question: String) {
        guard !isStreaming else { return }
        turns.append(Turn(question: question))
        let index = turns.count - 1
        isStreaming = true
        let r = route()
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                switch r {
                case .api(let key): try await self.streamAPI(key: key, index: index)
                case .cli(let path): try await self.streamCLI(path: path, index: index)
                case .unavailable(let msg): self.fail(index, msg)
                }
            } catch is CancellationError {
                if self.turns[index].answer.isEmpty { self.turns[index].answer = "Stopped." }
            } catch {
                self.fail(index, error.localizedDescription)
            }
            self.isStreaming = false
            self.process = nil
        }
    }

    func stop() {
        task?.cancel()
        process?.terminate()
    }

    func reset() {
        stop()
        turns = []
        cliSessionID = nil
    }

    private func fail(_ i: Int, _ message: String) {
        guard turns.indices.contains(i) else { return }
        turns[i].failed = true
        turns[i].answer += (turns[i].answer.isEmpty ? "" : "\n\n") + "⚠️ " + message
    }

    // MARK: Anthropic API (streaming SSE)

    @MainActor
    private func streamAPI(key: String, index: Int) async throws {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 600
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")

        var messages: [[String: Any]] = []
        for (i, t) in turns.enumerated() where i <= index && (!t.failed || i == index) {
            messages.append(["role": "user", "content": t.question])
            if i < index, !t.answer.isEmpty { messages.append(["role": "assistant", "content": t.answer]) }
        }

        let model = settings.model.trimmingCharacters(in: .whitespaces)
        var body: [String: Any] = [
            "model": model,
            "max_tokens": 64000,
            "stream": true,
            "system": systemPrompt,
            "messages": messages,
        ]
        // Notch answers should feel instant: keep thinking light on models that support effort.
        if !model.contains("haiku-4") && !model.contains("claude-3") {
            body["output_config"] = ["effort": "low"]
        }
        // If a safety classifier declines, let the API retry on a fallback model in the same call.
        let fallbackModels: Set<String> = ["claude-opus-5-5", "claude-opus-5", "claude-fable-5-2", "claude-fable-5-1", "claude-sonnet-5-5"]
        if fallbackModels.contains(model) {
            body["fallbacks"] = "default"
            req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        guard let http = response as? HTTPURLResponse else { throw ClaudeError.message("No response from the API.") }
        if http.statusCode != 200 {
            var raw = ""
            for try await line in bytes.lines { raw += line }
            throw ClaudeError.message(Self.apiErrorMessage(status: http.statusCode, body: raw))
        }

        var stopReason: String?
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
                  let type = obj["type"] as? String else { continue }
            switch type {
            case "content_block_delta":
                if let d = obj["delta"] as? [String: Any], d["type"] as? String == "text_delta",
                   let text = d["text"] as? String {
                    turns[index].answer += text
                }
            case "message_delta":
                if let d = obj["delta"] as? [String: Any], let sr = d["stop_reason"] as? String { stopReason = sr }
            case "error":
                let msg = (obj["error"] as? [String: Any])?["message"] as? String ?? "The API returned an error."
                throw ClaudeError.message(msg)
            default:
                break
            }
        }
        if stopReason == "refusal" {
            turns[index].answer += (turns[index].answer.isEmpty ? "" : "\n\n") + "_Claude declined to answer this one._"
        } else if stopReason == "max_tokens" {
            turns[index].answer += "\n\n_(answer truncated)_"
        }
    }

    private static func apiErrorMessage(status: Int, body: String) -> String {
        let msg = ((try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any])
            .flatMap { $0["error"] as? [String: Any] }?["message"] as? String
        switch status {
        case 401: return "Your API key was rejected — update it in Settings."
        case 429: return "Rate limited — try again in a moment."
        case 529: return "Claude is overloaded right now — try again shortly."
        default: return msg ?? "API error \(status)."
        }
    }

    // MARK: Local Claude Code (`claude -p`)

    @MainActor
    private func streamCLI(path: String, index: Int) async throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        var args = ["-p", turns[index].question,
                    "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                    "--append-system-prompt", systemPrompt]
        if let sid = cliSessionID { args += ["--resume", sid] }
        p.arguments = args

        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let workdir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Notchi/claude", isDirectory: true)
        try? fm.createDirectory(at: workdir, withIntermediateDirectories: true)
        p.currentDirectoryURL = workdir

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        p.environment = env

        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        try p.run()
        process = p

        var gotText = false
        var resultError: String?
        for try await line in out.fileHandleForReading.bytes.lines {
            try Task.checkCancellation()
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let type = obj["type"] as? String else { continue }
            if let sid = obj["session_id"] as? String { cliSessionID = sid }
            switch type {
            case "stream_event":
                guard let ev = obj["event"] as? [String: Any], let et = ev["type"] as? String else { break }
                if et == "message_start", gotText {
                    turns[index].answer += "\n\n"
                } else if et == "content_block_delta", let d = ev["delta"] as? [String: Any],
                          d["type"] as? String == "text_delta", let text = d["text"] as? String {
                    gotText = true
                    turns[index].answer += text
                }
            case "result":
                if obj["is_error"] as? Bool == true {
                    resultError = obj["result"] as? String ?? "Claude Code reported an error."
                } else if !gotText, let r = obj["result"] as? String {
                    turns[index].answer = r
                    gotText = true
                }
            default:
                break
            }
        }
        p.waitUntilExit()
        if let resultError { throw ClaudeError.message(resultError) }
        if !gotText && p.terminationStatus != 0 {
            let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw ClaudeError.message(e.isEmpty ? "Claude Code exited with status \(p.terminationStatus)." : e)
        }
    }
}

enum ClaudeError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
}
