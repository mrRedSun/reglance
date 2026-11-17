import Foundation

/// Finds the `claude` binary.
public enum ClaudeLocator {
    public static func executableURL() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return CLILocator.executableURL(named: "claude", candidates: [
            "\(home)/.local/bin/claude",          // native installer
            "\(home)/.claude/local/claude",       // older local install
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.npm-global/bin/claude",
            "\(home)/.bun/bin/claude",
        ])
    }
}

/// Claude Code's models, from the list it sends in answer to the stream-json `initialize`
/// control request: the same list its own `/model` picker shows, including models a
/// gateway adds. The CLI answers and exits without sending anything to a model.
public enum ClaudeBackend {
    static let modelListArguments = [
        "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
        "--setting-sources", "", "--strict-mcp-config", "--disable-slash-commands", "--tools", "",
        "--no-session-persistence",
    ]
    static let initializeRequest = #"{"type":"control_request","request_id":"models","request":{"subtype":"initialize"}}"# + "\n"

    public static func models() async -> [ModelOption]? {
        await Task.detached {
            guard let executable = ClaudeLocator.executableURL() else { return nil }
            let workingDirectory = AppPaths.workdir(for: .claude)
            try? FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
            let process = ClaudeClient.process(executable: executable, arguments: modelListArguments,
                                               workingDirectory: workingDirectory)
            let stdin = Pipe(), stdout = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return nil }
            _ = Subprocess.ignoreBrokenPipe
            try? stdin.fileHandleForWriting.write(contentsOf: Data(initializeRequest.utf8))
            try? stdin.fileHandleForWriting.close()
            // It answers within a second or two; don't let a stuck CLI hold the picker.
            let watchdog = Task {
                try await Task.sleep(for: .seconds(20))
                if process.isRunning { process.terminate() }
            }
            let output = await Subprocess.readAll(stdout.fileHandleForReading)
            watchdog.cancel()
            process.waitUntilExit()
            return modelOptions(fromOutput: output)
        }.value
    }

    /// The models from the `control_response` line of the CLI's output, or nil without one.
    static func modelOptions(fromOutput output: String) -> [ModelOption]? {
        for line in output.split(whereSeparator: \.isNewline) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["type"] as? String == "control_response",
                  let response = object["response"] as? [String: Any] else { continue }
            let body = response["response"] as? [String: Any] ?? response
            guard let models = body["models"] as? [[String: Any]] else { return nil }
            return modelOptions(from: models)
        }
        return nil
    }

    /// Maps the `initialize` models to picker options. Pure, so tests cover it without a CLI.
    /// The "default" row repeats another model and is skipped. A description reads
    /// "Opus 5.5 · Best for everyday, complex tasks · $4/$20 per Mtok": the first part is the
    /// name, the second the detail, and the price is left out. A gateway's rows say only
    /// "Claude Fable 5.2" and "From gateway": they become "Fable 5.2", like the others, with
    /// no detail, as there's nothing to say about the model.
    static func modelOptions(from models: [[String: Any]]) -> [ModelOption] {
        var seen = Set<String>()
        return models.compactMap { model in
            guard let value = model["value"] as? String, value != "default" else { return nil }
            let id = (model["resolvedModel"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? value
            guard seen.insert(id).inserted else { return nil }
            let displayName = (model["displayName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id
            let parts = (model["description"] as? String ?? "").components(separatedBy: " · ")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            let name = parts.count > 1 && !parts[0].isEmpty
                ? parts[0]
                : displayName.hasPrefix("Claude ") ? String(displayName.dropFirst("Claude ".count)) : displayName
            let detail = parts.count > 1 ? parts[1] : (parts[0] == "From gateway" ? "" : parts[0])
            let efforts = (model["supportedEffortLevels"] as? [String] ?? [])
                .compactMap(Effort.init(rawValue:)).filter { $0 != .automatic }
            return ModelOption(model: ChatModel(backend: .claude, id: id), name: name,
                               detail: detail == name ? "" : detail, efforts: [.automatic] + efforts)
        }
    }
}

extension ClaudeBackend: BackendDescriptor {
    public static let displayName = "Claude Code"
    public static let workdirName = "ClaudeWorkdir"
    public static let notFoundMessage =
        "Couldn't find the claude CLI. Install Claude Code and run `claude` once in a terminal to log in."
    public static var supportsAgentMode: Bool { true }

    public static func executableURL() -> URL? { ClaudeLocator.executableURL() }

    public static func doctor() async -> DoctorReport {
        await ClaudeDoctor.run(executable: Task.detached { ClaudeLocator.executableURL() }.value)
    }

    public static func makeClient() -> any ChatStreamingClient { ClaudeClient() }
}
