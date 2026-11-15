import Foundation

public enum ChatEvent: Equatable, Sendable {
    /// Session id from the CLI's init event; pass it back as `resume` for follow-ups.
    case session(id: String)
    /// A streamed chunk of the reply.
    case text(String)
    /// A streamed chunk of extended thinking (models that think, e.g. Opus).
    case thinking(String)
    /// Claude started using a tool: `WebSearch` (detail = query) or `WebFetch` (detail = URL).
    case tool(name: String, detail: String)
    /// The reply is complete.
    case finished(sessionID: String?, fullText: String)
}

/// A piece of a user message: maps to an Anthropic API content block.
public enum ContentBlock: Equatable, Sendable {
    case text(String)
    case image(mediaType: String, data: Data)
    case document(mediaType: String, data: Data, title: String)
}

public enum ChatError: LocalizedError, Equatable, Sendable {
    case cliNotFound(Backend)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .cliNotFound(.claude):
            "Couldn't find the claude CLI. Install Claude Code and run `claude` once in a terminal to log in."
        case .cliNotFound(.codex):
            "Couldn't find the codex CLI. Install Codex and run `codex` once in a terminal to sign in."
        case .cliNotFound(.opencode):
            "Couldn't find the opencode CLI. Install OpenCode and run `opencode auth login` in a terminal to sign in."
        case .failed(let message):
            message
        }
    }
}

/// Streaming boundary used by the controller, one per backend (see `BackendRouter`), also
/// allowing tests without CLI subprocesses.
public protocol ChatStreamingClient: Sendable {
    /// `agentDirectory` is nil for an ordinary chat; otherwise the turn runs as an agent in
    /// that folder, approving actions with `permissions`. `resume` is the session id from the
    /// reply before this turn; the stream reports the new turn's own session id, so earlier
    /// ids stay resumable for regenerate.
    func send(_ content: [ContentBlock], model: ChatModel, effort: Effort, resume sessionID: String?,
              agentDirectory: URL?, permissions: AgentPermissions) -> AsyncThrowingStream<ChatEvent, Error>
    /// A short title for a new chat, or nil if none could be made. Runs on the chat's own
    /// backend; `model` is the chat's model.
    func title(question: String, answer: String, model: ChatModel) async -> String?
}

public extension ChatStreamingClient {
    func title(question: String, answer: String, model: ChatModel) async -> String? { nil }
}

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

    public init(workingDirectory: URL = AppPaths.claudeWorkdir,
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
        "--system-prompt", """
            You name chat conversations. Reply with only a title of 2 to 6 words that says \
            what the conversation is about, in the language of the question. Sentence case. \
            No quotes, no trailing punctuation, no emoji.
            """,
        "--tools", "",
        "--setting-sources", "",
        "--strict-mcp-config",
        "--disable-slash-commands",
        "--no-session-persistence",
        "--model", ClaudeModel.haiku.rawValue,
        "--output-format", "text",
    ]

    /// Trims a model reply to one plain line, or nil when it's empty.
    public static func cleanTitle(_ output: String) -> String? {
        let line = output.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let title = line.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\"'“”‘’.#*")))
        guard !title.isEmpty else { return nil }
        return title.count > 60 ? String(title.prefix(60)) + "…" : title
    }

    public func title(question: String, answer: String, model: ChatModel) async -> String? {
        let prompt = "Question:\n\(question.prefix(1500))\n\nStart of the answer:\n\(answer.prefix(1500))"
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
            _ = Self.ignoreBrokenPipe
            try? stdin.fileHandleForWriting.write(contentsOf: Data(prompt.utf8))
            try? stdin.fileHandleForWriting.close()
            let output = await Self.readAll(stdout.fileHandleForReading)
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return Self.cleanTitle(output)
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
        var environment = inherited.merging(settingsEnvironment) { _, setting in setting }
        let extraPath = [executable.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin"]
        environment["PATH"] = (extraPath + [environment["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
        return environment
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
        AsyncThrowingStream { continuation in
            let task = Task.detached {
                do {
                    try await run(content: content, model: model, effort: effort, resume: sessionID,
                                  agentDirectory: agentDirectory, permissions: permissions, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
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
        _ = Self.ignoreBrokenPipe
        let line = Self.userMessageLine(content)
        let input = stdin.fileHandleForWriting
        Thread.detachNewThread {
            try? input.write(contentsOf: line)
            try? input.close()
        }

        let handle = ProcessHandle(process)
        try await withTaskCancellationHandler {
            async let errorOutput = Self.readAll(stderr.fileHandleForReading)
            var parser = StreamParser()
            var buffer = Data()
            for await chunk in Self.chunks(of: stdout.fileHandleForReading) {
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = String(decoding: buffer[..<newline], as: UTF8.self)
                    buffer.removeSubrange(...newline)
                    for event in parser.consume(line) { continuation.yield(event) }
                }
            }
            let stderrText = await errorOutput
            process.waitUntilExit()
            try Task.checkCancellation()

            if let message = parser.errorMessage { throw ChatError.failed(message) }
            if !parser.isFinished {
                let detail = stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
                throw ChatError.failed(detail.isEmpty ? "claude exited with status \(process.terminationStatus)" : detail)
            }
        } onCancel: {
            handle.terminate()
        }
    }

    /// Writing to a pipe whose reader exited (claude quit early or was cancelled) raises
    /// SIGPIPE, which would kill the app. Ignored, the write then just fails.
    static let ignoreBrokenPipe: Void = { signal(SIGPIPE, SIG_IGN) }()

    /// Pipe data as soon as it's written. (`FileHandle.bytes` buffers, which delays streaming.)
    static func chunks(of handle: FileHandle) -> AsyncStream<Data> {
        AsyncStream { continuation in
            handle.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    continuation.finish()
                } else {
                    continuation.yield(data)
                }
            }
        }
    }

    static func readAll(_ handle: FileHandle) async -> String {
        var data = Data()
        do { for try await byte in handle.bytes { data.append(byte) } } catch {}
        return String(decoding: data, as: UTF8.self)
    }
}

/// `Process` isn't Sendable; this only exposes `terminate()`, which is safe from any thread.
final class ProcessHandle: @unchecked Sendable {
    private let process: Process
    init(_ process: Process) { self.process = process }
    func terminate() { if process.isRunning { process.terminate() } }
}

/// Turns `--output-format stream-json` lines into `ChatEvent`s.
public struct StreamParser: Sendable {
    public private(set) var sessionID: String?
    public private(set) var text = ""
    public private(set) var isFinished = false
    public private(set) var errorMessage: String?

    public init() {}

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
            // A new text block after a tool call starts a new paragraph.
            if event["type"] as? String == "content_block_start",
               (event["content_block"] as? [String: Any])?["type"] as? String == "text",
               !text.isEmpty, !text.hasSuffix("\n\n") {
                let separator = text.hasSuffix("\n") ? "\n" : "\n\n"
                text += separator
                return [.text(separator)]
            }
            guard event["type"] as? String == "content_block_delta",
                  let delta = event["delta"] as? [String: Any] else { return [] }
            switch delta["type"] as? String {
            case "text_delta":
                guard let chunk = delta["text"] as? String else { return [] }
                text += chunk
                return [.text(chunk)]
            case "thinking_delta":
                // The CLI currently sends empty thinking text (progress updates only).
                guard let chunk = delta["thinking"] as? String, !chunk.isEmpty else { return [] }
                return [.thinking(chunk)]
            default:
                return []
            }

        case "result":
            isFinished = true
            let id = object["session_id"] as? String ?? sessionID
            sessionID = id
            let result = object["result"] as? String ?? ""
            if object["is_error"] as? Bool == true {
                errorMessage = result.isEmpty ? "claude returned an error (\(object["subtype"] as? String ?? "unknown"))" : result
                return []
            }
            var events: [ChatEvent] = []
            // No partial messages arrived (e.g. an older CLI): emit the whole reply at once.
            if text.isEmpty, !result.isEmpty {
                text = result
                events.append(.text(result))
            }
            events.append(.finished(sessionID: id, fullText: text))
            return events

        default:
            return []
        }
    }
}
