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

    /// The models the picker offers. Only read-only CLI commands; nothing is sent to a model.
    public func models() async -> [ModelOption] {
        switch self {
        case .claude: ClaudeBackend.models
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

    /// Short name for the pill and the chat list.
    public var displayName: String {
        switch backend {
        case .claude: ClaudeModel(rawValue: id)?.displayName ?? id
        case .codex, .opencode: id.split(separator: "/").last.map(String.init) ?? id
        }
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

/// One row of the model picker.
public struct ModelOption: Identifiable, Hashable, Sendable {
    public var model: ChatModel
    public var name: String
    /// A few words under the name, or empty.
    public var detail: String
    /// An SF Symbol.
    public var symbol: String
    /// The efforts this model accepts; `.automatic` first. Only `.automatic` hides the column.
    public var efforts: [Effort]

    public var id: ChatModel { model }

    public init(model: ChatModel, name: String, detail: String = "", symbol: String = "sparkles", efforts: [Effort] = [.automatic]) {
        self.model = model
        self.name = name
        self.detail = detail
        self.symbol = symbol
        self.efforts = efforts
    }
}

public enum ClaudeBackend {
    public static let models: [ModelOption] = [
        ModelOption(model: .haiku, name: "Haiku 5.5", detail: "Quick answers", symbol: "bolt", efforts: claudeEfforts),
        ModelOption(model: .sonnet, name: "Sonnet 5.5", detail: "Everyday balance", symbol: "sparkles", efforts: claudeEfforts),
        ModelOption(model: .opus, name: "Opus 5.5", detail: "Deeper reasoning", symbol: "brain", efforts: claudeEfforts),
    ]

    static let claudeEfforts: [Effort] = [.automatic, .low, .medium, .high, .xhigh, .max]
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
