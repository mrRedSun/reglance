import Foundation

/// How an ordinary Codex chat is kept to web search. Codex reads the person's own
/// `~/.codex` (that's where its sign-in lives, and Reglance never copies credentials), so
/// everything there that could act on the Mac is switched off at launch, and anything that
/// still slips through ends the turn (`CodexClient.allowedItemTypes`).
enum CodexLockdown {
    /// Features that add tools beyond web search or run code: the shell and hooks, apps,
    /// plugins and skills (MCP), sub-agents and goals, image tools, sleep, the browser and
    /// computer use, and memories. Codex turns most of them on by default. `unified_exec`
    /// isn't listed: Codex ignores disabling it, and with `shell_tool` off no exec tool exists.
    static let disabledFeatures = [
        "shell_tool", "hooks", "apps", "plugins", "skill_search", "tool_suggest",
        "multi_agent", "goals", "image_generation", "view_image", "sleep_tool",
        "browser_use", "browser_use_external", "in_app_browser", "computer_use", "memories",
    ]

    /// `codex app-server` arguments: each MCP server from the config disabled by name
    /// (an empty `mcp_servers` table doesn't replace the configured ones), the features
    /// above off, and web search on.
    static func arguments(config: String) -> [String] {
        var arguments = ["app-server"]
        for name in mcpServerNames(in: config) {
            arguments += ["-c", "mcp_servers.\(name).enabled=false"]
        }
        for feature in disabledFeatures { arguments += ["--disable", feature] }
        arguments += ["-c", "tools.web_search=true"]
        return arguments
    }

    /// Server names from `[mcp_servers.<name>]` headers, including sub-tables like
    /// `[mcp_servers.<name>.env]`. Quoted names keep their quotes so `-c` parses them.
    static func mcpServerNames(in config: String) -> [String] {
        let pattern = /^\s*\[\s*mcp_servers\.("[^"]+"|[A-Za-z0-9_-]+)/
        var names: [String] = []
        for line in config.split(whereSeparator: \.isNewline) {
            guard let match = String(line).firstMatch(of: pattern) else { continue }
            let name = String(match.output.1)
            if !names.contains(name) { names.append(name) }
        }
        return names
    }

    /// The person's Codex config, in `CODEX_HOME` when it's set, like the CLI.
    static func configURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let home = environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : URL(filePath: $0, directoryHint: .isDirectory) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex", directoryHint: .isDirectory)
        return home.appending(path: "config.toml")
    }

    static func currentArguments() -> [String] {
        arguments(config: (try? String(contentsOf: configURL(), encoding: .utf8)) ?? "")
    }
}

/// One `codex app-server` subprocess speaking newline-delimited JSON-RPC 2.0 over stdio.
/// Responses are matched to requests by id; notifications and server requests arrive on
/// one stream for a single consumer. `terminate()` ends the process.
final class CodexServer: @unchecked Sendable {
    private let process: Process
    let handle: ProcessHandle
    private let stdin = Pipe()
    private let lock = NSLock()
    private var nextID = 1
    private var responses: [Int: [String: Any]] = [:]
    private var errorOutput = ""
    private let notificationContinuation: AsyncStream<SendableJSON>.Continuation
    let notifications: AsyncStream<SendableJSON>

    init(executable: URL, workingDirectory: URL, arguments: [String] = CodexLockdown.currentArguments()) throws {
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        // Not ClaudeClient's environment: that adds Claude Code's settings variables.
        var environment = ProcessInfo.processInfo.environment
        let extraPath = [executable.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin"]
        environment["PATH"] = (extraPath + [environment["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
        process.environment = environment
        let stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        handle = ProcessHandle(process)
        (notifications, notificationContinuation) = AsyncStream.makeStream()
        try process.run()
        _ = ClaudeClient.ignoreBrokenPipe

        let continuation = notificationContinuation
        Task.detached { [weak self] in
            var buffer = Data()
            for await chunk in ClaudeClient.chunks(of: stdout.fileHandleForReading) {
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = buffer[..<newline]
                    buffer.removeSubrange(...newline)
                    guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                    self?.receive(object, continuation: continuation)
                }
            }
            continuation.finish()
        }
        Task.detached { [weak self] in
            let text = await ClaudeClient.readAll(stderr.fileHandleForReading)
            self?.lock.withLock { self?.errorOutput = text }
        }
    }

    /// A response answers one of our requests; anything with a method is a notification
    /// or a server request (such as an approval) for the consumer.
    private func receive(_ object: [String: Any], continuation: AsyncStream<SendableJSON>.Continuation) {
        if object["method"] == nil, let id = Self.rpcID(object) {
            lock.withLock { responses[id] = object }
        } else {
            continuation.yield(SendableJSON(object))
        }
    }

    static func rpcID(_ object: [String: Any]) -> Int? {
        if let int = object["id"] as? Int { return int }
        if let string = object["id"] as? String { return Int(string) }
        return nil
    }

    /// `initialize` and the `initialized` notification, which must precede everything else.
    func handshake() async throws {
        _ = try await request("initialize", params: ["clientInfo": ["name": "Reglance", "version": "1"]])
        send(["jsonrpc": "2.0", "method": "initialized", "params": [String: Any]()])
    }

    /// Sends a request and waits for its response.
    @discardableResult
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        let id = post(method, params: params)
        while true {
            try Task.checkCancellation()
            if let response = lock.withLock({ responses.removeValue(forKey: id) }) {
                if let error = response["error"] as? [String: Any] {
                    throw ChatError.failed("Codex: \(error["message"] as? String ?? "the request failed").")
                }
                return response["result"] as? [String: Any] ?? [:]
            }
            guard process.isRunning else { throw ChatError.failed(exitMessage) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Sends a request without waiting for the response; returns its id.
    @discardableResult
    func post(_ method: String, params: [String: Any]) -> Int {
        let id = lock.withLock {
            defer { nextID += 1 }
            return nextID
        }
        send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        return id
    }

    /// Answers a server request (an approval) by declining it.
    func decline(_ request: [String: Any]) {
        guard let id = request["id"] else { return }
        send(["jsonrpc": "2.0", "id": id, "result": ["decision": "decline"]])
    }

    private func send(_ object: [String: Any]) {
        guard var line = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return }
        line.append(UInt8(ascii: "\n"))
        try? stdin.fileHandleForWriting.write(contentsOf: line)
    }

    /// Why the process ended, from its stderr when it said anything.
    var exitMessage: String {
        let detail = lock.withLock { errorOutput }.trimmingCharacters(in: .whitespacesAndNewlines)
        let lastLine = detail.split(whereSeparator: \.isNewline).last.map(String.init)
        return lastLine.map { "Codex stopped: \($0)" } ?? "Codex stopped unexpectedly."
    }

    func terminate() {
        notificationContinuation.finish()
        handle.terminate()
    }

    deinit { terminate() }
}

/// A JSON object from `JSONSerialization`, handed from the reader task to one consumer.
struct SendableJSON: @unchecked Sendable {
    let value: [String: Any]
    init(_ value: [String: Any]) { self.value = value }
}

/// The `codex` CLI as a streaming chat: one `codex app-server` per turn (it starts in a
/// fraction of a second), restricted to web search by `CodexLockdown`, with Reglance's
/// system prompt replacing Codex's own. Agent mode is refused by `BackendRouter`.
public struct CodexClient: ChatStreamingClient {
    public let workingDirectory: URL
    /// The person's preferences from Settings, read for every message.
    public let preferences: @Sendable () -> String

    public init(workingDirectory: URL = AppPaths.workdir(for: .codex),
                preferences: @escaping @Sendable () -> String = {
                    UserDefaults.standard.string(forKey: SystemPrompt.preferencesKey) ?? ""
                }) {
        self.workingDirectory = workingDirectory
        self.preferences = preferences
    }

    /// Thread items an ordinary chat may produce. Anything else (a command, a file change,
    /// an MCP or dynamic tool call, a sub-agent) means the lockdown didn't hold.
    static let allowedItemTypes: Set<String> = [
        "userMessage", "agentMessage", "reasoning", "plan", "webSearch", "contextCompaction",
    ]

    /// Thread settings for every chat turn. The person's own config may default to full
    /// access, so the sandbox and approvals are always set here.
    static func threadParams(cwd: URL, model: ChatModel, instructions: String) -> [String: Any] {
        [
            "cwd": cwd.path,
            "model": model.id,
            "sandbox": "read-only",
            "approvalPolicy": "never",
            "baseInstructions": instructions,
            // Forked by the next turn and by regenerate, so it must be saved.
            "ephemeral": false,
        ]
    }

    public func send(_ content: [ContentBlock], model: ChatModel, effort: Effort = .automatic, resume sessionID: String?,
                     agentDirectory: URL? = nil, permissions: AgentPermissions = .auto) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached {
                do {
                    try await run(content: content, model: model, effort: effort, resume: sessionID, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(content: [ContentBlock], model: ChatModel, effort: Effort, resume sessionID: String?,
                     continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation) async throws {
        guard let executable = CodexBackend.executableURL() else { throw ChatError.cliNotFound(.codex) }
        if content.contains(where: { if case .document = $0 { true } else { false } }) {
            throw ChatError.failed("Codex chats can't read PDFs. Remove the PDF, or ask in a Claude chat.")
        }
        let images = try Self.writeImages(content)
        defer { for url in images.values { try? FileManager.default.removeItem(at: url) } }

        let server = try CodexServer(executable: executable, workingDirectory: workingDirectory)
        defer { server.terminate() }
        let turn = TurnHandle(server: server)
        try await withTaskCancellationHandler {
            try await server.handshake()
            var params = Self.threadParams(cwd: workingDirectory, model: model,
                                           instructions: SystemPrompt.make(preferences: preferences(), assistant: "Codex"))
            // Each turn gets its own thread: a new one, or a fork of the previous reply's.
            // Earlier ids stay unchanged, which regenerate relies on.
            let thread: [String: Any]
            if let sessionID {
                params["threadId"] = sessionID
                thread = try await server.request("thread/fork", params: params)
            } else {
                thread = try await server.request("thread/start", params: params)
            }
            guard let threadID = (thread["thread"] as? [String: Any])?["id"] as? String else {
                throw ChatError.failed("Codex didn't start a conversation.")
            }
            continuation.yield(.session(id: threadID))

            var turnParams: [String: Any] = ["threadId": threadID, "input": Self.userInput(content, images: images)]
            if effort != .automatic { turnParams["effort"] = effort.rawValue }
            let started = try await server.request("turn/start", params: turnParams)
            turn.set(threadID: threadID, turnID: (started["turn"] as? [String: Any])?["id"] as? String)

            var parser = CodexStreamParser()
            for await notification in server.notifications {
                let object = notification.value
                if Self.isServerRequest(object) {
                    // A plain chat never approves anything.
                    server.decline(object)
                    continue
                }
                for event in parser.consume(object) { continuation.yield(event) }
                if let violation = parser.violation { throw ChatError.failed(violation) }
                if parser.isFinished { break }
            }
            try Task.checkCancellation()
            if let message = parser.errorMessage { throw ChatError.failed(message) }
            guard parser.isFinished else { throw ChatError.failed(server.exitMessage) }
        } onCancel: {
            turn.interrupt()
        }
    }

    /// The running turn, so cancelling can interrupt it before the process ends.
    private final class TurnHandle: @unchecked Sendable {
        private let server: CodexServer
        private let lock = NSLock()
        private var ids: (thread: String, turn: String)?

        init(server: CodexServer) { self.server = server }

        func set(threadID: String, turnID: String?) {
            guard let turnID else { return }
            lock.withLock { ids = (threadID, turnID) }
        }

        func interrupt() {
            if let ids = lock.withLock({ ids }) {
                server.post("turn/interrupt", params: ["threadId": ids.thread, "turnId": ids.turn])
            }
            server.terminate()
        }
    }

    /// A request from the server (it has both an id and a method), such as an approval.
    static func isServerRequest(_ object: [String: Any]) -> Bool {
        object["method"] != nil && object["id"] != nil
    }

    /// Images as temp files, keyed by their position in `content`.
    static func writeImages(_ content: [ContentBlock]) throws -> [Int: URL] {
        var urls: [Int: URL] = [:]
        for (index, block) in content.enumerated() {
            guard case .image(let mediaType, let data) = block else { continue }
            let ext = mediaType.split(separator: "/").last.map(String.init) ?? "png"
            let url = FileManager.default.temporaryDirectory.appending(path: "reglance-codex-\(UUID().uuidString).\(ext)")
            try data.write(to: url)
            urls[index] = url
        }
        return urls
    }

    /// `turn/start` input: text as text, images as the temp files written for them.
    static func userInput(_ content: [ContentBlock], images: [Int: URL]) -> [[String: Any]] {
        content.enumerated().compactMap { index, block in
            switch block {
            case .text(let text): ["type": "text", "text": text]
            case .image: images[index].map { ["type": "localImage", "path": $0.path] }
            case .document: nil
            }
        }
    }

    /// A short title on the chat's own model: an ephemeral thread, low effort.
    public func title(question: String, answer: String, model: ChatModel) async -> String? {
        guard let executable = CodexBackend.executableURL() else { return nil }
        let prompt = "Question:\n\(question.prefix(1500))\n\nStart of the answer:\n\(answer.prefix(1500))"
        let workingDirectory = workingDirectory
        return await Task.detached {
            guard let server = try? CodexServer(executable: executable, workingDirectory: workingDirectory) else { return nil }
            defer { server.terminate() }
            do {
                try await server.handshake()
                var params = Self.threadParams(cwd: workingDirectory, model: model, instructions: SystemPrompt.titleInstructions)
                params["ephemeral"] = true
                let thread = try await server.request("thread/start", params: params)
                guard let threadID = (thread["thread"] as? [String: Any])?["id"] as? String else { return nil }
                try await server.request("turn/start", params: [
                    "threadId": threadID, "input": [["type": "text", "text": prompt]], "effort": "low",
                ])
                var parser = CodexStreamParser()
                for await notification in server.notifications {
                    if Self.isServerRequest(notification.value) { server.decline(notification.value); continue }
                    _ = parser.consume(notification.value)
                    if parser.isFinished || parser.violation != nil { break }
                }
                guard parser.isFinished, parser.errorMessage == nil, parser.violation == nil else { return nil }
                return ClaudeClient.cleanTitle(parser.text)
            } catch {
                return nil
            }
        }.value
    }
}

/// Turns `codex app-server` notifications into `ChatEvent`s, like `StreamParser` does for Claude.
struct CodexStreamParser {
    private(set) var text = ""
    private(set) var isFinished = false
    private(set) var errorMessage: String?
    /// Set when Codex starts something an ordinary chat must not do; the turn then stops.
    private(set) var violation: String?
    private var messageCount = 0
    /// The turn's usage so far: one `last` breakdown per model call, added up.
    private var usage: TokenUsage?

    mutating func consume(_ notification: [String: Any]) -> [ChatEvent] {
        guard let method = notification["method"] as? String else { return [] }
        let params = notification["params"] as? [String: Any] ?? [:]
        switch method {
        case "mcpServer/startupStatus/updated":
            let name = params["name"] as? String ?? "an MCP server"
            violation = "Codex started \(name), which Reglance chats don't allow. Remove it from ~/.codex/config.toml or ask in a Claude chat."
            return []
        case "item/started":
            return itemStarted(params["item"] as? [String: Any] ?? [:])
        case "item/agentMessage/delta":
            guard let delta = params["delta"] as? String, !delta.isEmpty else { return [] }
            text += delta
            return [.text(delta)]
        case "item/reasoning/summaryTextDelta", "item/reasoning/textDelta":
            guard let delta = params["delta"] as? String, !delta.isEmpty else { return [] }
            return [.thinking(delta)]
        case "thread/tokenUsage/updated":
            guard let tokens = params["tokenUsage"] as? [String: Any],
                  let last = tokens["last"] as? [String: Any] else { return [] }
            var turn = usage ?? TokenUsage(input: 0, output: 0)
            // Codex counts cached and reasoning tokens inside input and output.
            turn.input += Int(json: last["inputTokens"]) ?? 0
            turn.cachedInput += Int(json: last["cachedInputTokens"]) ?? 0
            turn.output += Int(json: last["outputTokens"]) ?? 0
            turn.context = Int(json: last["totalTokens"])
            turn.contextWindow = Int(json: tokens["modelContextWindow"])
            usage = turn
            return [.usage(turn)]
        case "error":
            // A retried error (a dropped connection) isn't final.
            if params["willRetry"] as? Bool != true {
                errorMessage = (params["error"] as? [String: Any])?["message"] as? String ?? "Codex couldn't answer."
            }
            return []
        case "turn/completed":
            isFinished = true
            let turn = params["turn"] as? [String: Any] ?? [:]
            switch turn["status"] as? String {
            case "failed":
                errorMessage = errorMessage ?? ((turn["error"] as? [String: Any])?["message"] as? String) ?? "Codex couldn't answer."
                return []
            case "interrupted":
                errorMessage = "Stopped"
                return []
            default:
                guard errorMessage == nil else { return [] }
                return [.finished(sessionID: params["threadId"] as? String, fullText: text)]
            }
        default:
            return []
        }
    }

    private mutating func itemStarted(_ item: [String: Any]) -> [ChatEvent] {
        let type = item["type"] as? String ?? ""
        guard CodexClient.allowedItemTypes.contains(type) else {
            violation = "Codex tried to use a tool (\(type)) that Reglance chats don't allow, so the reply was stopped."
            return []
        }
        switch type {
        case "agentMessage":
            messageCount += 1
            // A later message starts a new paragraph.
            guard messageCount > 1, !text.isEmpty, !text.hasSuffix("\n\n") else { return [] }
            let separator = text.hasSuffix("\n") ? "\n" : "\n\n"
            text += separator
            return [.text(separator)]
        case "webSearch":
            return [.tool(name: "WebSearch", detail: item["query"] as? String ?? "")]
        default:
            return []
        }
    }
}
