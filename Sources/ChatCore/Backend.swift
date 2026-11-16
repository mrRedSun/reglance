import Foundation

/// The CLI a chat runs on. Fixed when the chat is created: a conversation is never sent
/// to another provider, because its session only exists in that CLI's own store.
public enum Backend: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude, codex, opencode

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .opencode: "OpenCode"
        }
    }

    /// The CLI's path, or nil when it isn't installed.
    public func executableURL() -> URL? {
        switch self {
        case .claude: ClaudeLocator.executableURL()
        case .codex: CodexBackend.executableURL()
        case .opencode: OpenCodeBackend.executableURL()
        }
    }

    /// The models the picker offers, or nil when the CLI couldn't be asked (not installed,
    /// or the call failed). Only read-only requests; nothing is sent to a model.
    public func models() async -> [ModelOption]? {
        switch self {
        case .claude: await ClaudeBackend.models()
        case .codex: await CodexBackend.models()
        case .opencode: await OpenCodeBackend.models()
        }
    }

    /// Installed, signed in, and the version, using only read-only commands.
    public func doctor() async -> DoctorReport {
        switch self {
        case .claude: await ClaudeDoctor.run(executable: Task.detached { ClaudeLocator.executableURL() }.value)
        case .codex: await CodexBackend.doctor()
        case .opencode: await OpenCodeBackend.doctor()
        }
    }

    /// Agent chats run Claude Code only for now (GitHub issue #2).
    public var supportsAgentMode: Bool { self == .claude }
}

/// A model on a backend, saved with each chat.
public struct ChatModel: Codable, Hashable, Sendable {
    public var backend: Backend
    /// What the CLI's `--model` / `-m` option takes, e.g. `claude-opus-5-5`, `gpt-5.5`
    /// or OpenCode's `provider/model`.
    public var id: String

    public init(backend: Backend, id: String) {
        self.backend = backend
        self.id = id
    }

    public static func claude(_ model: ClaudeModel) -> ChatModel { ChatModel(backend: .claude, id: model.rawValue) }
    public static let haiku = claude(.haiku)
    public static let sonnet = claude(.sonnet)
    public static let opus = claude(.opus)

    /// A readable name made from the id, for a model its CLI no longer lists:
    /// `claude-sonnet-5-5` becomes "Sonnet 5.5" and `openai/gpt-5.5` "GPT-5.5".
    /// The CLI's own name (`ModelOption.name`) wins whenever it's known.
    public var fallbackName: String {
        let name = id.split(separator: "/").last.map(String.init) ?? id
        if name.hasPrefix("claude-") {
            var parts = name.dropFirst("claude-".count).split(separator: "-").map(String.init)
            // A dated snapshot (`claude-sonnet-4-5-20250929`) reads as its version.
            if let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) { parts.removeLast() }
            guard let family = parts.first else { return name }
            return ([family.capitalized] + [parts.dropFirst().joined(separator: ".")]).filter { !$0.isEmpty }
                .joined(separator: " ")
        }
        if name.hasPrefix("gpt-") { return "GPT-" + name.dropFirst("gpt-".count) }
        return name
    }

    private enum CodingKeys: String, CodingKey { case backend, id }

    /// Chats saved before backends stored the Claude model id as a plain string.
    public init(from decoder: any Decoder) throws {
        if let legacy = try? decoder.singleValueContainer().decode(String.self) {
            self.init(backend: .claude, id: legacy)
            return
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(backend: try values.decode(Backend.self, forKey: .backend), id: try values.decode(String.self, forKey: .id))
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(backend, forKey: .backend)
        try values.encode(id, forKey: .id)
    }
}

/// One row of the model picker. Names, details and efforts come from each backend's CLI;
/// the app caches them between launches.
public struct ModelOption: Identifiable, Hashable, Codable, Sendable {
    public var model: ChatModel
    public var name: String
    /// A few words under the name, or empty.
    public var detail: String
    /// The efforts this model accepts; `.automatic` first. Only `.automatic` hides the column.
    public var efforts: [Effort]

    public var id: ChatModel { model }
    /// An SF Symbol for the model's family (`ModelSymbol`).
    public var symbol: String { ModelSymbol.symbol(for: model.id) }

    public init(model: ChatModel, name: String, detail: String = "", efforts: [Effort] = [.automatic]) {
        self.model = model
        self.name = name
        self.detail = detail
        self.efforts = efforts
    }
}

/// No CLI says how a model should look, so the popular Claude and OpenAI families get a
/// symbol from their id, on any backend (`openai/gpt-5.5` on OpenCode too). Others sparkle.
public enum ModelSymbol {
    public static func symbol(for id: String) -> String {
        let name = (id.split(separator: "/").last.map(String.init) ?? id).lowercased()
        if name.contains("codex") { return "chevron.left.forwardslash.chevron.right" }
        if name.contains("-mini") || name.contains("-nano") { return "hare" }
        if name.contains("-pro") { return "crown" }
        if name.firstMatch(of: /^o\d/) != nil { return "lightbulb" }
        if name.hasPrefix("gpt") { return "atom" }
        if name.contains("haiku") { return "bolt" }
        if name.contains("sonnet") { return "wand.and.stars" }
        if name.contains("opus") { return "brain" }
        if name.contains("fable") { return "book.closed" }
        return "sparkles"
    }
}

/// Claude and OpenAI model families, so the picker offers only the newest of each:
/// `claude-sonnet-5-5` replaces `claude-sonnet-5`, and `gpt-6-sol` replaces `gpt-5.6-sol`.
/// Other providers' models are always shown.
public enum ModelFamily {
    /// The family and version of a Claude or OpenAI model id, or nil for any other model.
    static func parse(_ id: String) -> (family: String, version: [Int])? {
        let name = (id.split(separator: "/").last.map(String.init) ?? id).lowercased()
        if name.hasPrefix("claude-") {
            // claude-<family>-<major>-<minor>[-<date>]
            var parts = name.dropFirst("claude-".count).split(separator: "-").map(String.init)
            if let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) { parts.removeLast() }
            guard let family = parts.first else { return nil }
            let version = parts.dropFirst().compactMap { Int($0) }
            guard !version.isEmpty, version.count == parts.count - 1 else { return nil }
            return ("claude-" + family, version)
        }
        // gpt-<version>[-<variant>] and o<version>[-<variant>]: the variant is the family.
        let prefix: String
        var rest: Substring
        if name.hasPrefix("gpt-") {
            prefix = "gpt"; rest = name.dropFirst("gpt-".count)
        } else if name.first == "o", name.dropFirst().first?.isNumber == true {
            prefix = "o"; rest = name.dropFirst()
        } else {
            return nil
        }
        let versionText = rest.prefix { $0.isNumber || $0 == "." }
        let version = versionText.split(separator: ".").compactMap { Int($0) }
        guard !version.isEmpty else { return nil }
        rest = rest.dropFirst(versionText.count)
        return (prefix + rest, version)
    }

    /// The newest model of each family, in the original order. `keeping` stays even when
    /// it's older, so a chat on it still finds its model in the picker.
    public static func latest(_ options: [ModelOption], keeping kept: ChatModel? = nil) -> [ModelOption] {
        var newest: [String: [Int]] = [:]
        for option in options {
            guard let (family, version) = parse(option.model.id) else { continue }
            if newest[family].map({ isOlder($0, than: version) }) ?? true { newest[family] = version }
        }
        return options.filter { option in
            guard option.model != kept, let (family, version) = parse(option.model.id),
                  let top = newest[family] else { return true }
            return !isOlder(version, than: top)
        }
    }

    /// The newest model in `options` of the same family as `model`, or `model` itself when
    /// it's already the newest or isn't a Claude or OpenAI model.
    public static func newest(_ model: ChatModel, in options: [ModelOption]) -> ChatModel {
        guard let (family, version) = parse(model.id) else { return model }
        var best = (model: model, version: version)
        for option in options where option.model.backend == model.backend {
            guard let (otherFamily, otherVersion) = parse(option.model.id), otherFamily == family,
                  isOlder(best.version, than: otherVersion) else { continue }
            best = (option.model, otherVersion)
        }
        return best.model
    }

    /// Compares versions part by part; a missing part counts as 0, so 5 is older than 5.5.
    static func isOlder(_ a: [Int], than b: [Int]) -> Bool {
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0, y = index < b.count ? b[index] : 0
            if x != y { return x < y }
        }
        return false
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
            let workingDirectory = AppPaths.claudeWorkdir
            try? FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
            let process = ClaudeClient.process(executable: executable, arguments: modelListArguments,
                                               workingDirectory: workingDirectory)
            let stdin = Pipe(), stdout = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return nil }
            _ = ClaudeClient.ignoreBrokenPipe
            try? stdin.fileHandleForWriting.write(contentsOf: Data(initializeRequest.utf8))
            try? stdin.fileHandleForWriting.close()
            // It answers within a second or two; don't let a stuck CLI hold the picker.
            let watchdog = Task {
                try await Task.sleep(for: .seconds(20))
                if process.isRunning { process.terminate() }
            }
            let output = await ClaudeClient.readAll(stdout.fileHandleForReading)
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

/// Sends each turn to the CLI of the chat's own backend, including title requests, so a
/// conversation never reaches another provider.
public struct BackendRouter: ChatStreamingClient {
    public let clients: [Backend: any ChatStreamingClient]

    public init(clients: [Backend: any ChatStreamingClient]) {
        self.clients = clients
    }

    public static let live = BackendRouter(clients: [
        .claude: ClaudeClient(),
        .codex: CodexClient(),
        .opencode: OpenCodeClient(),
    ])

    public func send(_ content: [ContentBlock], model: ChatModel, effort: Effort, resume sessionID: String?,
                     agentDirectory: URL?, permissions: AgentPermissions) -> AsyncThrowingStream<ChatEvent, Error> {
        guard let client = clients[model.backend] else {
            return AsyncThrowingStream { $0.finish(throwing: ChatError.failed("\(model.backend.displayName) isn't available.")) }
        }
        if agentDirectory != nil, !model.backend.supportsAgentMode {
            return AsyncThrowingStream {
                $0.finish(throwing: ChatError.failed("Agent mode works with Claude Code only for now."))
            }
        }
        return client.send(content, model: model, effort: effort, resume: sessionID,
                           agentDirectory: agentDirectory, permissions: permissions)
    }

    public func title(question: String, answer: String, model: ChatModel) async -> String? {
        await clients[model.backend]?.title(question: question, answer: answer, model: model)
    }
}
