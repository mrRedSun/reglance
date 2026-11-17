import Foundation

/// A backend that plays back scripted events instead of running a CLI, and records what it
/// was asked. For tests in both targets, like `DemoClient` is for demo mode.
public final class ScriptedClient: ChatStreamingClient, @unchecked Sendable {
    /// One `send` call, as the controller made it.
    public struct Request: Equatable, Sendable {
        public let content: [ContentBlock]
        public let model: ChatModel
        public let effort: Effort
        public let resume: String?
        public let agentDirectory: URL?
        public let permissions: AgentPermissions

        /// The text the person sent.
        public var text: String {
            content.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined(separator: "\n")
        }
    }

    public typealias Title = @Sendable (_ question: String, _ answer: String, _ model: ChatModel) async -> String?

    private let reply: @Sendable (Request) -> AsyncThrowingStream<ChatEvent, Error>
    private let makeTitle: Title?
    private let lock = NSLock()
    private var recorded: [Request] = []

    /// Answers every request with `reply(request)`.
    public init(title: Title? = nil, reply: @escaping @Sendable (Request) -> AsyncThrowingStream<ChatEvent, Error>) {
        self.reply = reply
        self.makeTitle = title
    }

    /// Answers every request with the same events, then finishes.
    public convenience init(_ events: [ChatEvent], title: Title? = nil) {
        self.init(title: title) { _ in Self.stream(events) }
    }

    /// A reply with `text` on session `session`.
    public convenience init(replying text: String, session: String = "scripted-session", title: Title? = nil) {
        self.init(Self.reply(text, session: session), title: title)
    }

    /// Answers the first request with `stream`, which the test drives itself; later requests
    /// get the same stream, already consumed.
    public convenience init(stream: AsyncThrowingStream<ChatEvent, Error>) {
        self.init { _ in stream }
    }

    /// The events of a plain reply.
    public static func reply(_ text: String, session: String = "scripted-session") -> [ChatEvent] {
        [.session(id: session), .text(text), .finished(sessionID: session)]
    }

    /// A stream that yields `events` and finishes.
    public static func stream(_ events: [ChatEvent]) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }

    /// Every `send` so far, in order.
    public var requests: [Request] { lock.withLock { recorded } }

    public func send(_ content: [ContentBlock], model: ChatModel, effort: Effort, resume sessionID: String?,
                     agentDirectory: URL?, permissions: AgentPermissions) -> AsyncThrowingStream<ChatEvent, Error> {
        let request = Request(content: content, model: model, effort: effort, resume: sessionID,
                              agentDirectory: agentDirectory, permissions: permissions)
        lock.withLock { recorded.append(request) }
        return reply(request)
    }

    public func title(question: String, answer: String, model: ChatModel) async -> String? {
        await makeTitle?(question, answer, model)
    }
}
