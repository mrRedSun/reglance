import Foundation

/// The CLI a chat runs on. Fixed when the chat is created: a conversation is never sent
/// to another provider, because its session only exists in that CLI's own store.
public enum Backend: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude, codex, opencode

    public var id: String { rawValue }

    /// Where everything about this backend lives. The only switch over backends.
    public var descriptor: any BackendDescriptor.Type {
        switch self {
        case .claude: ClaudeBackend.self
        case .codex: CodexBackend.self
        case .opencode: OpenCodeBackend.self
        }
    }

    public var displayName: String { descriptor.displayName }

    /// The CLI's path, or nil when it isn't installed.
    public func executableURL() -> URL? { descriptor.executableURL() }

    /// The models the picker offers, or nil when the CLI couldn't be asked (not installed,
    /// or the call failed). Only read-only requests; nothing is sent to a model.
    public func models() async -> [ModelOption]? { await descriptor.models() }

    /// Installed, signed in, and the version, using only read-only commands.
    public func doctor() async -> DoctorReport { await descriptor.doctor() }

    /// Agent chats run Claude Code only for now (GitHub issue #2).
    public var supportsAgentMode: Bool { descriptor.supportsAgentMode }
}

/// Everything Reglance knows about one CLI backend. Each backend's enum (`ClaudeBackend`,
/// `CodexBackend`, `OpenCodeBackend`) conforms in its own file, so adding a backend is one
/// new file plus a `Backend` case.
public protocol BackendDescriptor {
    static var displayName: String { get }
    /// The empty folder under `AppPaths.root` the CLI runs in for ordinary chats, so no
    /// project files or instructions get picked up.
    static var workdirName: String { get }
    /// What `ChatError.cliNotFound` says: how to install the CLI and sign in.
    static var notFoundMessage: String { get }
    /// Whether agent chats can run on it.
    static var supportsAgentMode: Bool { get }
    /// The CLI's path, or nil when it isn't installed.
    static func executableURL() -> URL?
    /// The picker's models, or nil when the CLI couldn't be asked. Read-only requests only.
    static func models() async -> [ModelOption]?
    /// Installed, signed in, and the version, using only read-only commands.
    static func doctor() async -> DoctorReport
    /// The client that streams this backend's turns (see `BackendRouter.live`).
    static func makeClient() -> any ChatStreamingClient
}

public extension BackendDescriptor {
    static var supportsAgentMode: Bool { false }
}

/// Sends each turn to the CLI of the chat's own backend, including title requests, so a
/// conversation never reaches another provider.
public struct BackendRouter: ChatStreamingClient {
    public let clients: [Backend: any ChatStreamingClient]

    public init(clients: [Backend: any ChatStreamingClient]) {
        self.clients = clients
    }

    public static let live = BackendRouter(clients: Dictionary(uniqueKeysWithValues: Backend.allCases.map {
        ($0, $0.descriptor.makeClient())
    }))

    public func send(_ content: [ContentBlock], model: ChatModel, effort: Effort, resume sessionID: String?,
                     agentDirectory: URL?, permissions: AgentPermissions, steering: Steering) -> AsyncThrowingStream<ChatEvent, Error> {
        guard let client = clients[model.backend] else {
            return AsyncThrowingStream { $0.finish(throwing: ChatError.failed("\(model.backend.displayName) isn't available.")) }
        }
        if agentDirectory != nil, !model.backend.supportsAgentMode {
            return AsyncThrowingStream {
                $0.finish(throwing: ChatError.failed("Agent mode works with Claude Code only for now."))
            }
        }
        return client.send(content, model: model, effort: effort, resume: sessionID,
                           agentDirectory: agentDirectory, permissions: permissions, steering: steering)
    }

    public func title(question: String, answer: String, model: ChatModel) async -> String? {
        await clients[model.backend]?.title(question: question, answer: answer, model: model)
    }
}
