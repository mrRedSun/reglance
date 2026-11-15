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

/// Runs one `claude -p` subprocess per message and streams the reply.
/// User settings, MCP servers and slash commands are disabled, and the only tools are
/// web search and web fetch, so the CLI behaves as a chat model that can read the web.
public struct ClaudeClient: Sendable {
    /// WebSearch runs on Anthropic's servers; WebFetch downloads a page and summarises it.
    /// Neither can change anything on the Mac.
    public static let tools = "WebSearch,WebFetch"

    public let workingDirectory: URL

    public init(workingDirectory: URL = AppPaths.claudeWorkdir) {
        self.workingDirectory = workingDirectory
    }

    public static func arguments(model: ClaudeModel, resume sessionID: String?) -> [String] {
        var args = [
            "-p",                            // the message comes from stdin (see `userMessageLine`)
            "--input-format", "stream-json", // so it can carry images and documents
            "--system-prompt", SystemPrompt.make(),
            "--tools", tools,
            "--allowedTools", tools,         // print mode can't ask for permission
            "--setting-sources", "",
            "--strict-mcp-config",
            "--disable-slash-commands",
            "--model", model.rawValue,
            "--output-format", "stream-json",
            "--verbose",                     // required by stream-json in print mode
            "--include-partial-messages",    // token-level text deltas
        ]
        // Fork so every turn gets its own session id and earlier ids stay unchanged.
        // Regenerate resumes the id from before the last turn.
        if let sessionID { args += ["--resume", sessionID, "--fork-session"] }
        return args
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
    public func send(_ content: [ContentBlock], model: ClaudeModel, resume sessionID: String?) -> AsyncThrowingStream<ClaudeEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached {
                do {
                    try await run(content: content, model: model, resume: sessionID, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(
        content: [ContentBlock], model: ClaudeModel, resume sessionID: String?,
        continuation: AsyncThrowingStream<ClaudeEvent, Error>.Continuation
    ) async throws {
        guard let executable = ClaudeLocator.executableURL() else { throw ClaudeError.cliNotFound }
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = executable
        process.arguments = Self.arguments(model: model, resume: sessionID)
        process.currentDirectoryURL = workingDirectory
        var environment = ProcessInfo.processInfo.environment
        // npm installs need `node` on PATH; GUI apps get a minimal PATH.
        let extraPath = [executable.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin"]
        environment["PATH"] = (extraPath + [environment["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
        process.environment = environment

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
private final class ProcessHandle: @unchecked Sendable {
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
                let detail = (input["query"] ?? input["url"]) as? String ?? ""
                return .tool(name: name == "web_search" ? "WebSearch" : name, detail: detail)
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
