import Foundation

public enum ClaudeEvent: Equatable, Sendable {
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

public enum ClaudeError: LocalizedError, Equatable, Sendable {
    case cliNotFound
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .cliNotFound:
            "Couldn't find the claude CLI. Install Claude Code and run `claude` once in a terminal to log in."
        case .failed(let message):
            message
        }
    }
}

/// Streaming boundary used by the controller, also allowing tests without Claude subprocesses.
public protocol ClaudeStreamingClient: Sendable {
    /// `agentDirectory` is nil for an ordinary chat; otherwise the turn runs as an agent in that folder.
    func send(_ content: [ContentBlock], model: ClaudeModel, effort: ClaudeEffort, resume sessionID: String?,
              agentDirectory: URL?) -> AsyncThrowingStream<ClaudeEvent, Error>
    /// A short title for a new chat, or nil if none could be made.
    func title(question: String, answer: String) async -> String?
}

public extension ClaudeStreamingClient {
    func title(question: String, answer: String) async -> String? { nil }
}

/// Runs one `claude -p` subprocess per message and streams the reply.
/// In a chat, user settings, MCP servers and slash commands are disabled, and the only
/// tools are web search and web fetch, so the CLI behaves as a chat model that can read
/// the web. In an agent chat, the CLI runs as it normally would in the chosen folder,
/// with permission prompts bypassed.
public struct ClaudeClient: ClaudeStreamingClient {
    /// WebSearch runs on Anthropic's servers; WebFetch downloads a page and summarises it.
    /// Neither can change anything on the Mac.
    public static let tools = "WebSearch,WebFetch"

    public let workingDirectory: URL

    public init(workingDirectory: URL = AppPaths.claudeWorkdir) {
        self.workingDirectory = workingDirectory
    }

    public static func arguments(model: ClaudeModel, effort: ClaudeEffort = .automatic, resume sessionID: String?,
                                 agent: Bool = false) -> [String] {
        var args = [
            "-p",                            // the message comes from stdin (see `userMessageLine`)
            "--input-format", "stream-json", // so it can carry images and documents
        ]
        if agent {
            // Claude Code's own system prompt, settings, CLAUDE.md, skills, hooks, plugins
            // and MCP servers, plus the widget instructions. Print mode can't ask for
            // permission, so the person opted in to bypassing it.
            args += [
                "--append-system-prompt", SystemPrompt.agentAppendix,
                "--permission-mode", "bypassPermissions",
            ]
        } else {
            args += [
                "--system-prompt", SystemPrompt.make(),
                "--tools", tools,
                "--allowedTools", tools,     // print mode can't ask for permission
                "--setting-sources", "",
                "--strict-mcp-config",
                "--disable-slash-commands",
            ]
        }
        args += [
            "--model", model.rawValue,
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

    public func title(question: String, answer: String) async -> String? {
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
    public func send(_ content: [ContentBlock], model: ClaudeModel, effort: ClaudeEffort = .automatic, resume sessionID: String?,
                     agentDirectory: URL? = nil) -> AsyncThrowingStream<ClaudeEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached {
                do {
                    try await run(content: content, model: model, effort: effort, resume: sessionID,
                                  agentDirectory: agentDirectory, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(
        content: [ContentBlock], model: ClaudeModel, effort: ClaudeEffort, resume sessionID: String?,
        agentDirectory: URL?, continuation: AsyncThrowingStream<ClaudeEvent, Error>.Continuation
    ) async throws {
        guard let executable = ClaudeLocator.executableURL() else { throw ClaudeError.cliNotFound }
        let directory: URL
        if let agentDirectory {
            // Never create or substitute the person's folder; a missing one is an error.
            guard (try? agentDirectory.checkResourceIsReachable()) == true else {
                throw ClaudeError.failed("The agent folder \(agentDirectory.path) no longer exists.")
            }
            directory = agentDirectory
        } else {
            try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
            directory = workingDirectory
        }

        let arguments = Self.arguments(model: model, effort: effort, resume: sessionID, agent: agentDirectory != nil)
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

            if let message = parser.errorMessage { throw ClaudeError.failed(message) }
            if !parser.isFinished {
                let detail = stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
                throw ClaudeError.failed(detail.isEmpty ? "claude exited with status \(process.terminationStatus)" : detail)
            }
        } onCancel: {
            handle.terminate()
        }
    }

    /// Writing to a pipe whose reader exited (claude quit early or was cancelled) raises
    /// SIGPIPE, which would kill the app. Ignored, the write then just fails.
    private static let ignoreBrokenPipe: Void = { signal(SIGPIPE, SIG_IGN) }()

    /// Pipe data as soon as it's written. (`FileHandle.bytes` buffers, which delays streaming.)
    private static func chunks(of handle: FileHandle) -> AsyncStream<Data> {
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

    private static func readAll(_ handle: FileHandle) async -> String {
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

/// Turns `--output-format stream-json` lines into `ClaudeEvent`s.
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

    public mutating func consume(_ line: String) -> [ClaudeEvent] {
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
            var events: [ClaudeEvent] = []
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
