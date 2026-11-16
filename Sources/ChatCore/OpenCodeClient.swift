import Foundation

/// The process id of the running `opencode serve`, so it is stopped when Reglance exits.
private nonisolated(unsafe) var openCodeServerPID: pid_t = 0
private let stopServerAtExit: Void = {
    atexit {
        if openCodeServerPID > 0 { kill(openCodeServerPID, SIGTERM) }
    }
}()

/// Reglance's own `opencode serve` (OpenCode 2's v2 API), shared by every OpenCode chat.
///
/// It listens on 127.0.0.1 only, on a free port, behind a random per-launch password,
/// because the API can run shell commands. It reads a private config folder
/// (`XDG_CONFIG_HOME`), so the person's MCP servers, plugins and instructions stay out,
/// while their sign-ins (in OpenCode's data folder) still work. The config defines one
/// agent, `reglance`, whose system prompt is Reglance's and whose permissions deny
/// everything except web fetch and search.
///
/// The system prompt holds the date and the person's preferences, so the server restarts
/// (about a second) when it changes, but never while a reply is streaming.
public actor OpenCodeServer {
    public static let shared = OpenCodeServer()

    /// Everything but fetching and searching the web is denied. Later rules win.
    static let permissionRules: [[String: String]] = [
        ["action": "*", "resource": "*", "effect": "deny"],
        ["action": "webfetch", "resource": "*", "effect": "allow"],
        ["action": "websearch", "resource": "*", "effect": "allow"],
    ]
    static let agentID = "reglance"

    /// The config the server runs with, passed as `OPENCODE_CONFIG_CONTENT`.
    static func config(systemPrompt: String) -> [String: Any] {
        [
            "agents": [agentID: [
                "mode": "primary",
                "description": "Reglance chat",
                "system": systemPrompt,
                "permissions": permissionRules,
            ]],
            "default_agent": agentID,
            "permissions": permissionRules,
            "mcp": [String: Any](),
            "plugins": [Any](),
            "instructions": [Any](),
            "share": "disabled",
        ]
    }

    static func environment(inherited: [String: String], executable: URL, configHome: URL,
                            systemPrompt: String, password: String) -> [String: String] {
        var environment = inherited
        let extraPath = [executable.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin"]
        environment["PATH"] = (extraPath + [environment["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
        environment["XDG_CONFIG_HOME"] = configHome.path
        let config = try! JSONSerialization.data(withJSONObject: config(systemPrompt: systemPrompt))
        environment["OPENCODE_CONFIG_CONTENT"] = String(decoding: config, as: UTF8.self)
        environment["OPENCODE_SERVER_PASSWORD"] = password
        // No CLAUDE.md or Claude Code skills, no project config or skills, no updates.
        for flag in ["OPENCODE_DISABLE_CLAUDE_CODE", "OPENCODE_DISABLE_PROJECT_CONFIG",
                     "OPENCODE_DISABLE_EXTERNAL_SKILLS", "OPENCODE_DISABLE_AUTOUPDATE"] {
            environment[flag] = "1"
        }
        return environment
    }

    private var process: Process?
    private var connection: Connection?
    private var systemPrompt: String?
    private var activeTurns = 0
    private var starting: Task<Connection, Error>?

    /// A running server, started or restarted as needed. `systemPrompt` nil (listing
    /// models) accepts whatever prompt a running server has.
    public func connect(executable: URL, systemPrompt: String? = nil) async throws -> Connection {
        if let starting { return try await starting.value }
        if let connection, process?.isRunning == true,
           systemPrompt == nil || systemPrompt == self.systemPrompt || activeTurns > 0 {
            return connection
        }
        let prompt = systemPrompt ?? OpenCodeClient.systemPrompt()
        let task = Task { try await start(executable: executable, systemPrompt: prompt) }
        starting = task
        defer { starting = nil }
        return try await task.value
    }

    /// Like `connect`, and keeps the server from restarting until `endTurn()`.
    func beginTurn(executable: URL, systemPrompt: String) async throws -> Connection {
        let connection = try await connect(executable: executable, systemPrompt: systemPrompt)
        activeTurns += 1
        return connection
    }

    func endTurn() { activeTurns = max(0, activeTurns - 1) }

    private func start(executable: URL, systemPrompt: String) async throws -> Connection {
        stop()
        _ = stopServerAtExit
        let workdir = AppPaths.workdir(for: .opencode)
        let configHome = workdir.appending(path: "Config", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: configHome, withIntermediateDirectories: true)
        let password = (0..<2).map { _ in UUID().uuidString }.joined().replacingOccurrences(of: "-", with: "")

        let process = Process()
        process.executableURL = executable
        process.arguments = ["serve", "--hostname", "127.0.0.1", "--port", "0"]
        process.currentDirectoryURL = workdir
        process.environment = Self.environment(inherited: ProcessInfo.processInfo.environment, executable: executable,
                                               configHome: configHome, systemPrompt: systemPrompt, password: password)
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        try process.run()
        self.process = process
        openCodeServerPID = process.processIdentifier

        // The first line names the URL; the rest is drained so the pipe never fills.
        let (urls, urlContinuation) = AsyncStream.makeStream(of: URL.self)
        Task.detached {
            var log = ""
            var found = false
            for await chunk in ClaudeClient.chunks(of: output.fileHandleForReading) where !found {
                log += String(decoding: chunk, as: UTF8.self)
                if let url = Self.listeningURL(in: log) {
                    found = true
                    urlContinuation.yield(url)
                    urlContinuation.finish()
                }
            }
            urlContinuation.finish()
        }
        let url = try await withThrowingTaskGroup(of: URL?.self) { group in
            group.addTask { await urls.first { _ in true } }
            group.addTask { try await Task.sleep(for: .seconds(20)); return nil }
            defer { group.cancelAll() }
            return try await group.next() ?? nil
        }
        guard let url else {
            stop()
            throw ChatError.failed("OpenCode's server didn't start. Check it in Settings.")
        }
        let connection = Connection(baseURL: url, password: password)
        // Agents load just after the server starts listening.
        for _ in 0..<60 {
            if let agents = try? await connection.send("GET", "/api/agent")["data"] as? [[String: Any]],
               agents.contains(where: { $0["id"] as? String == Self.agentID }) {
                self.connection = connection
                self.systemPrompt = systemPrompt
                return connection
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        stop()
        throw ChatError.failed("OpenCode's server started without Reglance's chat agent. Is OpenCode 2 installed?")
    }

    /// The URL from OpenCode's "server listening on http://127.0.0.1:61061" line.
    static func listeningURL(in log: String) -> URL? {
        guard let match = log.firstMatch(of: /listening on (http:\/\/127\.0\.0\.1:\d+)/) else { return nil }
        return URL(string: String(match.output.1))
    }

    private func stop() {
        if let process, process.isRunning { process.terminate() }
        process = nil
        connection = nil
        openCodeServerPID = 0
    }

    /// The server's address and password.
    public struct Connection: Sendable {
        let baseURL: URL
        let password: String

        /// Long reads: a reply's events can pause while a model thinks.
        private static let session: URLSession = {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 300
            configuration.timeoutIntervalForResource = 24 * 60 * 60
            return URLSession(configuration: configuration)
        }()

        func request(_ method: String, _ path: String, body: [String: Any]? = nil) -> URLRequest {
            var request = URLRequest(url: baseURL.appending(path: path))
            request.httpMethod = method
            request.setValue("Basic " + Data("opencode:\(password)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
            if let body {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            }
            return request
        }

        /// One API call; the JSON object it returns (empty for no content).
        @discardableResult
        func send(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
            let (data, response) = try await Self.session.data(for: request(method, path, body: body))
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let message = object["message"] as? String ?? (object["error"] as? [String: Any])?["message"] as? String
                throw ChatError.failed("OpenCode: \(message ?? "request failed (\((response as? HTTPURLResponse)?.statusCode ?? 0))").")
            }
            return object
        }

        /// Server-sent events from `/api/event`, subscribed by the time this returns.
        func events() async throws -> AsyncThrowingStream<SendableJSON, Error> {
            let (bytes, response) = try await Self.session.bytes(for: request("GET", "/api/event"))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw ChatError.failed("OpenCode didn't open its event stream.")
            }
            return AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        for try await line in bytes.lines {
                            guard line.hasPrefix("data:"),
                                  let object = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(5).utf8)) as? [String: Any]
                            else { continue }
                            continuation.yield(SendableJSON(object))
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }
}

/// OpenCode as a streaming chat, through `OpenCodeServer`: every reply is its own
/// session (new, or forked from the previous reply's), prompted with the restricted
/// `reglance` agent. Agent mode is refused by `BackendRouter`.
public struct OpenCodeClient: ChatStreamingClient {
    public let preferences: @Sendable () -> String

    public init(preferences: @escaping @Sendable () -> String = {
        UserDefaults.standard.string(forKey: SystemPrompt.preferencesKey) ?? ""
    }) {
        self.preferences = preferences
    }

    /// The models behind OpenCode vary, so the assistant doesn't claim a name.
    static func systemPrompt(preferences: String = UserDefaults.standard.string(forKey: SystemPrompt.preferencesKey) ?? "") -> String {
        SystemPrompt.make(preferences: preferences, assistant: "an AI assistant")
    }

    /// `provider/model` and effort as the API's model reference.
    static func modelRef(_ model: ChatModel, effort: Effort) throws -> [String: Any] {
        let parts = model.id.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { throw ChatError.failed("OpenCode models are named provider/model, not \(model.id).") }
        var ref: [String: Any] = ["providerID": parts[0], "id": parts[1]]
        if effort != .automatic { ref["variant"] = effort.rawValue }
        return ref
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
        guard let executable = OpenCodeBackend.executableURL() else { throw ChatError.cliNotFound(.opencode) }
        let modelRef = try Self.modelRef(model, effort: effort)
        let files = try Self.writeFiles(content)
        defer { for file in files { try? FileManager.default.removeItem(at: file.url) } }

        let server = OpenCodeServer.shared
        let connection = try await server.beginTurn(executable: executable, systemPrompt: Self.systemPrompt(preferences: preferences()))
        defer { Task { await server.endTurn() } }

        // Each reply gets its own session, so earlier ids stay resumable for regenerate.
        let session: [String: Any]
        if let sessionID {
            session = try await connection.send("POST", "/api/session/\(sessionID)/fork", body: [:])
        } else {
            session = try await connection.send("POST", "/api/session", body: [
                "agent": OpenCodeServer.agentID, "model": modelRef, "permissions": OpenCodeServer.permissionRules,
            ])
        }
        guard let id = (session["data"] as? [String: Any])?["id"] as? String else {
            throw ChatError.failed("OpenCode didn't start a conversation.")
        }
        // A follow-up may pick another model or effort than the forked session had.
        if sessionID != nil {
            try await connection.send("POST", "/api/session/\(id)/model", body: ["model": modelRef])
        }
        continuation.yield(.session(id: id))

        let events = try await connection.events()
        try await connection.send("POST", "/api/session/\(id)/prompt", body: Self.promptBody(content, files: files))

        var parser = OpenCodeStreamParser(sessionID: id)
        try await withTaskCancellationHandler {
            for try await event in events {
                for chatEvent in parser.consume(event.value) { continuation.yield(chatEvent) }
                if let violation = parser.violation {
                    try? await connection.send("POST", "/api/session/\(id)/interrupt")
                    throw ChatError.failed(violation)
                }
                if parser.isFinished { break }
            }
        } onCancel: {
            Task { _ = try? await connection.send("POST", "/api/session/\(id)/interrupt") }
        }
        try Task.checkCancellation()
        if let message = parser.errorMessage { throw ChatError.failed(message) }
        guard parser.isFinished else { throw ChatError.failed("OpenCode stopped before the reply was complete.") }
    }

    struct TemporaryFile {
        let url: URL
        let name: String
    }

    /// Images and PDFs as temp files, passed by URI (OpenCode reads them itself).
    static func writeFiles(_ content: [ContentBlock]) throws -> [TemporaryFile] {
        try content.compactMap { block -> TemporaryFile? in
            let (data, ext, name): (Data, String, String)
            switch block {
            case .text: return nil
            case .image(let mediaType, let bytes):
                (data, ext, name) = (bytes, mediaType.split(separator: "/").last.map(String.init) ?? "png", "image")
            case .document(_, let bytes, let title):
                (data, ext, name) = (bytes, "pdf", title)
            }
            let url = FileManager.default.temporaryDirectory.appending(path: "reglance-opencode-\(UUID().uuidString).\(ext)")
            try data.write(to: url)
            return TemporaryFile(url: url, name: name)
        }
    }

    static func promptBody(_ content: [ContentBlock], files: [TemporaryFile]) -> [String: Any] {
        let text = content.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined(separator: "\n\n")
        var body: [String: Any] = ["text": text]
        if !files.isEmpty {
            body["files"] = files.map { ["uri": $0.url.absoluteString, "name": $0.name] }
        }
        return body
    }

    /// A short title from a throwaway session on the chat's own model, deleted afterwards.
    public func title(question: String, answer: String, model: ChatModel) async -> String? {
        guard let executable = OpenCodeBackend.executableURL(),
              let modelRef = try? Self.modelRef(model, effort: .automatic),
              let connection = try? await OpenCodeServer.shared.connect(executable: executable),
              let session = try? await connection.send("POST", "/api/session", body: [
                  "agent": OpenCodeServer.agentID, "model": modelRef, "permissions": OpenCodeServer.permissionRules,
              ]),
              let id = (session["data"] as? [String: Any])?["id"] as? String else { return nil }
        defer { Task { _ = try? await connection.send("DELETE", "/api/session/\(id)") } }
        let prompt = SystemPrompt.titleInstructions
            + "\n\nQuestion:\n\(question.prefix(1500))\n\nStart of the answer:\n\(answer.prefix(1500))"
        guard let response = try? await connection.send("POST", "/api/session/\(id)/generate", body: ["prompt": prompt]),
              let text = Self.generatedText(response) else { return nil }
        return ClaudeClient.cleanTitle(text)
    }

    /// The text of a `generate` response, whichever shape it has.
    static func generatedText(_ response: [String: Any]) -> String? {
        if let text = response["data"] as? String { return text }
        if let data = response["data"] as? [String: Any] {
            return data["text"] as? String ?? data["output"] as? String
        }
        return response["text"] as? String
    }
}

/// Turns v2 `/api/event` events for one session into `ChatEvent`s.
struct OpenCodeStreamParser {
    let sessionID: String
    private(set) var text = ""
    private(set) var isFinished = false
    private(set) var errorMessage: String?
    /// Set when OpenCode starts anything but a web fetch or search; the reply then stops.
    private(set) var violation: String?
    private var toolNames: [String: String] = [:]

    static let allowedTools: [String: String] = ["webfetch": "WebFetch", "websearch": "WebSearch"]

    init(sessionID: String) { self.sessionID = sessionID }

    mutating func consume(_ event: [String: Any]) -> [ChatEvent] {
        guard let type = event["type"] as? String,
              let data = event["data"] as? [String: Any],
              data["sessionID"] as? String == sessionID else { return [] }
        switch type {
        case "session.text.started":
            // A new text part after a tool call starts a new paragraph.
            guard !text.isEmpty, !text.hasSuffix("\n\n") else { return [] }
            let separator = text.hasSuffix("\n") ? "\n" : "\n\n"
            text += separator
            return [.text(separator)]
        case "session.text.delta":
            guard let delta = data["delta"] as? String, !delta.isEmpty else { return [] }
            text += delta
            return [.text(delta)]
        case "session.reasoning.delta":
            guard let delta = data["delta"] as? String, !delta.isEmpty else { return [] }
            return [.thinking(delta)]
        case "session.tool.input.started":
            let name = data["name"] as? String ?? ""
            if let id = data["id"] as? String { toolNames[id] = name }
            if Self.allowedTools[name] == nil {
                violation = "OpenCode tried to use a tool (\(name.isEmpty ? "unknown" : name)) that Reglance chats don't allow, so the reply was stopped."
            }
            return []
        case "session.tool.called":
            let name = (data["id"] as? String).flatMap { toolNames[$0] } ?? data["name"] as? String ?? ""
            guard let display = Self.allowedTools[name] else {
                violation = "OpenCode tried to use a tool (\(name.isEmpty ? "unknown" : name)) that Reglance chats don't allow, so the reply was stopped."
                return []
            }
            let input = data["input"] as? [String: Any] ?? [:]
            return [.tool(name: display, detail: input["url"] as? String ?? input["query"] as? String ?? "")]
        case "session.execution.succeeded":
            isFinished = true
            return [.finished(sessionID: sessionID, fullText: text)]
        case "session.execution.failed":
            isFinished = true
            errorMessage = (data["error"] as? [String: Any])?["message"] as? String ?? "OpenCode couldn't answer."
            return []
        case "session.execution.interrupted":
            isFinished = true
            errorMessage = "Stopped"
            return []
        default:
            if type.contains("permission") {
                violation = "OpenCode asked for a permission Reglance chats don't grant, so the reply was stopped."
            }
            return []
        }
    }
}
