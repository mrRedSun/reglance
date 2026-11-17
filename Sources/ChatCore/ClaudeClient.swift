import Foundation

/// Runs one `claude -p` subprocess per message and streams the reply.
/// In a chat, user settings, MCP servers and slash commands are disabled, and the only
/// tools are web search and web fetch, so the CLI behaves as a chat model that can read
/// the web. In an agent chat, the CLI runs as it normally would in the chosen folder,
/// approving actions with auto mode or, if the person opted in, bypassing permissions.
public struct ClaudeClient: ChatStreamingClient {
    /// WebSearch runs on Anthropic's servers; WebFetch downloads a page and summarises it.
    /// Neither can change anything on the Mac.
    public static let tools = "WebSearch,WebFetch"

    public let workingDirectory: URL
    /// The person's preferences from Settings, read for every message so edits apply to
    /// the next one.
    public let preferences: @Sendable () -> String

    public init(workingDirectory: URL = AppPaths.workdir(for: .claude),
                preferences: @escaping @Sendable () -> String = {
                    UserDefaults.standard.string(forKey: SystemPrompt.preferencesKey) ?? ""
                }) {
        self.workingDirectory = workingDirectory
        self.preferences = preferences
    }

    public static func arguments(model: String, effort: Effort = .automatic, resume sessionID: String?,
                                 agent: AgentPermissions? = nil, preferences: String = "") -> [String] {
        var args = [
            "-p",                            // the message comes from stdin (see `userMessageLine`)
            "--input-format", "stream-json", // so it can carry images and documents
        ]
        if let agent {
            // Claude Code's own system prompt, settings, CLAUDE.md, skills, hooks, plugins
            // and MCP servers, plus the widget instructions. Print mode can't ask for
            // permission, so auto mode or (opted in) bypassing decides instead.
            args += [
                "--append-system-prompt", SystemPrompt.agentAppendix(preferences: preferences),
                "--permission-mode", agent.cliMode,
            ]
        } else {
            args += [
                "--system-prompt", SystemPrompt.make(preferences: preferences),
                "--tools", tools,
                "--allowedTools", tools,     // print mode can't ask for permission
                "--setting-sources", "",
                "--strict-mcp-config",
                "--disable-slash-commands",
            ]
        }
        args += [
            "--model", model,
            "--output-format", "stream-json",
            "--verbose",                     // required by stream-json in print mode
            "--include-partial-messages",    // token-level text deltas
        ]
        if effort != .automatic { args += ["--effort", effort.rawValue] }
        // Fork so every turn gets its own session id and earlier ids stay unchanged.
        // Regenerate resumes the id from before the last turn.
        if let sessionID { args += ["--resume", sessionID, "--fork-session"] }
        return args
    }

    /// Headless `claude -p` sessions get no title (only interactive ones do), so a title
    /// is a separate, tool-free Haiku request that isn't saved as a session.
    public static let titleArguments: [String] = [
        "-p",
        "--system-prompt", SystemPrompt.titleInstructions,
        "--tools", "",
        "--setting-sources", "",
        "--strict-mcp-config",
        "--disable-slash-commands",
        "--no-session-persistence",
        "--model", ClaudeModel.haiku.rawValue,
        "--output-format", "text",
    ]

    public func title(question: String, answer: String, model: ChatModel) async -> String? {
        let prompt = ChatTitle.prompt(question: question, answer: answer)
        return await Task.detached {
            guard let executable = ClaudeLocator.executableURL() else { return nil }
            try? FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
            let process = Self.process(executable: executable, arguments: Self.titleArguments,
                                       workingDirectory: workingDirectory)
            let stdin = Pipe(), stdout = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return nil }
            _ = Subprocess.ignoreBrokenPipe
            try? stdin.fileHandleForWriting.write(contentsOf: Data(prompt.utf8))
            try? stdin.fileHandleForWriting.close()
            let output = await Subprocess.readAll(stdout.fileHandleForReading)
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return ChatTitle.clean(output)
        }.value
    }

    /// A `claude` process with a PATH that can find `node` (GUI apps get a minimal PATH).
    static func process(executable: URL, arguments: [String], workingDirectory: URL) -> Process {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = childEnvironment(inherited: ProcessInfo.processInfo.environment,
                                               settingsEnvironment: settingsEnvironment(), executable: executable)
        return process
    }

    /// Chats pass `--setting-sources ""`, which also drops the `env` block of the user's
    /// `~/.claude/settings.json`. That block can hold how they sign in (a gateway's
    /// ANTHROPIC_BASE_URL and ANTHROPIC_AUTH_TOKEN), so the child gets it as variables.
    static func childEnvironment(inherited: [String: String], settingsEnvironment: [String: String],
                                 executable: URL) -> [String: String] {
        Subprocess.environment(inherited: inherited.merging(settingsEnvironment) { _, setting in setting },
                               executable: executable)
    }

    /// The string values of the `env` block in a Claude Code settings file; empty when the
    /// file is missing or unreadable.
    static func settingsEnvironment(at url: URL = settingsURL(environment: ProcessInfo.processInfo.environment)) -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let env = settings["env"] as? [String: Any] else { return [:] }
        return env.compactMapValues { $0 as? String }
    }

    /// The user settings file, in `CLAUDE_CONFIG_DIR` when it's set, like the CLI.
    static func settingsURL(environment: [String: String]) -> URL {
        let directory = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : URL(filePath: $0, directoryHint: .isDirectory) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude", directoryHint: .isDirectory)
        return directory.appending(path: "settings.json")
    }

    /// One `--input-format stream-json` user message, newline-terminated.
    public static func userMessageLine(_ content: [ContentBlock]) -> Data {
        let blocks: [[String: Any]] = content.map { block in
            switch block {
            case .text(let text):
                return ["type": "text", "text": text]
            case .image(let mediaType, let data):
                return ["type": "image", "source": ["type": "base64", "media_type": mediaType, "data": data.base64EncodedString()]]
            case .document(let mediaType, let data, let title):
                return ["type": "document", "title": title,
                        "source": ["type": "base64", "media_type": mediaType, "data": data.base64EncodedString()]]
            }
        }
        let message: [String: Any] = ["type": "user", "message": ["role": "user", "content": blocks]]
        // Only strings, arrays and dictionaries, so serialization can't fail.
        var line = try! JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes])
        line.append(UInt8(ascii: "\n"))
        return line
    }

    /// Cancelling the consuming task (or dropping the stream) terminates the subprocess.
    public func send(_ content: [ContentBlock], model: ChatModel, effort: Effort = .automatic, resume sessionID: String?,
                     agentDirectory: URL? = nil, permissions: AgentPermissions = .auto) -> AsyncThrowingStream<ChatEvent, Error> {
        .turn { continuation in
            try await run(content: content, model: model, effort: effort, resume: sessionID,
                          agentDirectory: agentDirectory, permissions: permissions, continuation: continuation)
        }
    }

    private func run(
        content: [ContentBlock], model: ChatModel, effort: Effort, resume sessionID: String?,
        agentDirectory: URL?, permissions: AgentPermissions, continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation
    ) async throws {
        guard let executable = ClaudeLocator.executableURL() else { throw ChatError.cliNotFound(.claude) }
        let directory: URL
        if let agentDirectory {
            // Never create or substitute the person's folder; a missing one is an error.
            guard (try? agentDirectory.checkResourceIsReachable()) == true else {
                throw ChatError.failed("The agent folder \(agentDirectory.path) no longer exists.")
            }
            directory = agentDirectory
        } else {
            try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
            directory = workingDirectory
        }

        let arguments = Self.arguments(model: model.id, effort: effort, resume: sessionID,
                                       agent: agentDirectory == nil ? nil : permissions, preferences: preferences())
        let process = Self.process(executable: executable, arguments: arguments, workingDirectory: directory)

        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = stdin
        try process.run()

        // Write on another thread: a large image can exceed the pipe buffer, and the CLI
        // starts writing to stdout before it has read all of stdin. EOF ends the turn.
        _ = Subprocess.ignoreBrokenPipe
        let line = Self.userMessageLine(content)
        let input = stdin.fileHandleForWriting
        Thread.detachNewThread {
            try? input.write(contentsOf: line)
            try? input.close()
        }

        let handle = ProcessHandle(process)
        try await withTaskCancellationHandler {
            async let errorOutput = Subprocess.readAll(stderr.fileHandleForReading)
            var parser = StreamParser()
            for await line in Subprocess.lines(of: stdout.fileHandleForReading) {
                try parser.turn.deliver(parser.consume(String(decoding: line, as: UTF8.self)), to: continuation)
            }
            let detail = await errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            process.waitUntilExit()
            try parser.turn.finish(orElse: detail.isEmpty ? "claude exited with status \(process.terminationStatus)" : detail)
        } onCancel: {
            handle.terminate()
        }
    }
}

/// Turns `--output-format stream-json` lines into `ChatEvent`s.
public struct StreamParser: Sendable {
    public private(set) var sessionID: String?
    private(set) var turn = TurnState()
    public var text: String { turn.text }
    public var isFinished: Bool { turn.isFinished }
    public var errorMessage: String? { turn.errorMessage }
    /// Tokens in the latest model call: its prompt (cached or not) plus its output.
    private var lastCallContext: Int?

    public init() {}

    /// The prompt plus output of one API `usage` object.
    static func callTokens(_ usage: [String: Any]) -> Int {
        ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens"]
            .reduce(0) { $0 + (Int(json: usage[$1]) ?? 0) }
    }

    /// The turn's usage from the `result` line: `usage` sums every call of the turn and
    /// `modelUsage` has the context window. Side calls (a search summary on a small model)
    /// get their own `modelUsage` entry; the one with the most prompt tokens is the chat's.
    func usage(fromResult object: [String: Any]) -> TokenUsage? {
        guard let usage = object["usage"] as? [String: Any] else { return nil }
        let cached = Int(json: usage["cache_read_input_tokens"]) ?? 0
        let input = (Int(json: usage["input_tokens"]) ?? 0) + (Int(json: usage["cache_creation_input_tokens"]) ?? 0) + cached
        let models = (object["modelUsage"] as? [String: [String: Any]] ?? [:]).values
        let main = models.max { a, b in
            let prompt = { (m: [String: Any]) in
                ["inputTokens", "cacheReadInputTokens", "cacheCreationInputTokens"].reduce(0) { $0 + (Int(json: m[$1]) ?? 0) }
            }
            return prompt(a) < prompt(b)
        }
        return TokenUsage(input: input, cachedInput: cached, output: Int(json: usage["output_tokens"]) ?? 0,
                          context: lastCallContext, contextWindow: main.flatMap { Int(json: $0["contextWindow"]) },
                          cost: object["total_cost_usd"] as? Double)
    }

    /// The most telling input of a tool call: a search query, URL, shell command or path.
    static func toolDetail(_ input: [String: Any]) -> String {
        for key in ["query", "url", "command", "file_path", "notebook_path", "pattern", "path", "description", "prompt"] {
            if let value = input[key] as? String, !value.isEmpty {
                return value.split(whereSeparator: \.isNewline).first.map(String.init) ?? value
            }
        }
        return ""
    }

    public mutating func consume(_ line: String) -> [ChatEvent] {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let type = object["type"] as? String else { return [] }

        switch type {
        case "system" where object["subtype"] as? String == "init":
            guard let id = object["session_id"] as? String else { return [] }
            sessionID = id
            return [.session(id: id)]

        case "assistant":
            // Complete assistant messages; only tool calls matter here (text arrives as deltas).
            guard let message = object["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { return [] }
            return content.compactMap { block in
                guard ["tool_use", "server_tool_use"].contains(block["type"] as? String),
                      let name = block["name"] as? String else { return nil }
                let input = block["input"] as? [String: Any] ?? [:]
                return .tool(name: name == "web_search" ? "WebSearch" : name, detail: Self.toolDetail(input))
            }

        case "stream_event":
            guard let event = object["event"] as? [String: Any] else { return [] }
            // Each model call reports its usage at the start and, with the final output count, at the end.
            if let usage = event["usage"] as? [String: Any] ?? (event["message"] as? [String: Any])?["usage"] as? [String: Any] {
                lastCallContext = Self.callTokens(usage)
            }
            // A new text block after a tool call starts a new paragraph.
            if event["type"] as? String == "content_block_start",
               (event["content_block"] as? [String: Any])?["type"] as? String == "text" {
                return turn.startParagraph()
            }
            guard event["type"] as? String == "content_block_delta",
                  let delta = event["delta"] as? [String: Any] else { return [] }
            switch delta["type"] as? String {
            case "text_delta":
                return turn.append(delta["text"] as? String ?? "")
            case "thinking_delta":
                // The CLI currently sends empty thinking text (progress updates only).
                guard let chunk = delta["thinking"] as? String, !chunk.isEmpty else { return [] }
                return [.thinking(chunk)]
            default:
                return []
            }

        case "result":
            turn.isFinished = true
            let id = object["session_id"] as? String ?? sessionID
            sessionID = id
            let result = object["result"] as? String ?? ""
            if object["is_error"] as? Bool == true {
                turn.errorMessage = result.isEmpty ? "claude returned an error (\(object["subtype"] as? String ?? "unknown"))" : result
                return []
            }
            var events: [ChatEvent] = []
            if let usage = usage(fromResult: object) { events.append(.usage(usage)) }
            // No partial messages arrived (e.g. an older CLI): emit the whole reply at once.
            if text.isEmpty { events += turn.append(result) }
            events.append(.finished(sessionID: id))
            return events

        default:
            return []
        }
    }
}
