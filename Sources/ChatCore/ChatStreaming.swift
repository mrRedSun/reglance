import Foundation

/// What a backend reports while it answers, in the order it happens.
public enum ChatEvent: Equatable, Sendable {
    /// Session id from the CLI's init event; pass it back as `resume` for follow-ups.
    case session(id: String)
    /// A streamed chunk of the reply.
    case text(String)
    /// A streamed chunk of extended thinking (models that think, e.g. Opus).
    case thinking(String)
    /// The model started using a tool: `WebSearch` (detail = query), `WebFetch` (detail = URL),
    /// or in agent chats any Claude Code tool.
    case tool(name: String, detail: String)
    /// Token usage of the turn so far; a later report replaces an earlier one.
    case usage(TokenUsage)
    /// The reply is complete.
    case finished(sessionID: String?)
    /// The CLI took the oldest message steered into this turn (`Steering`); what follows
    /// answers it, in a new reply.
    case steered
}

/// Messages the person sends while a reply streams, added to the running turn (steering).
/// The controller makes one per turn. The client opens it once its CLI can take a message
/// mid-turn, reports each message the CLI takes with a `.steered` event, and closes it
/// when the turn is done.
public final class Steering: @unchecked Sendable {
    public typealias Deliver = @Sendable ([ContentBlock]) async -> Bool

    private let lock = NSLock()
    private var deliver: Deliver?
    private var isClosed = false
    /// Messages being handed to the CLI.
    private var inFlight = 0
    /// Messages the CLI accepted but hasn't taken yet.
    private var queued = 0

    public init() {}

    /// The turn can take messages now; `deliver` hands one to the CLI and says whether it
    /// accepted it.
    public func open(_ deliver: @escaping Deliver) {
        lock.withLock { self.deliver = deliver }
    }

    /// Adds `content` to the running turn, waiting for it to open. False when the turn
    /// ended first or the CLI refused; the message then belongs to the next turn.
    public func steer(_ content: [ContentBlock]) async -> Bool {
        var deliver: Deliver?
        while deliver == nil {
            let state: (closed: Bool, deliver: Deliver?) = lock.withLock {
                guard !isClosed else { return (true, nil) }
                if let deliver = self.deliver { inFlight += 1 }
                return (false, self.deliver)
            }
            if state.closed { return false }
            deliver = state.deliver
            if deliver == nil { try? await Task.sleep(for: .milliseconds(10)) }
        }
        let accepted = await deliver!(content)
        lock.withLock {
            inFlight -= 1
            if accepted { queued += 1 }
        }
        return accepted
    }

    /// Counts the messages the CLI took (`.steered` among `events`).
    func noteTaken(_ events: [ChatEvent]) {
        let taken = events.count { $0 == .steered }
        guard taken > 0 else { return }
        lock.withLock { queued = max(0, queued - taken) }
    }

    /// The CLI says the turn is done. Waits for messages still being handed over, then
    /// closes, unless the CLI holds a message it hasn't taken: the turn then goes on.
    func close() async -> Bool {
        while true {
            let state: Bool? = lock.withLock {
                guard inFlight == 0 else { return nil }
                if queued == 0 { isClosed = true }
                return isClosed
            }
            if let state { return state }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// The turn is over: later messages wait for the next one.
    public func end() {
        lock.withLock { isClosed = true }
    }
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
        case .cliNotFound(let backend): backend.descriptor.notFoundMessage
        case .failed(let message): message
        }
    }
}

/// Streaming boundary used by the controller, one per backend (see `BackendRouter`), also
/// allowing tests without CLI subprocesses (`ScriptedClient`).
public protocol ChatStreamingClient: Sendable {
    /// `agentDirectory` is nil for an ordinary chat; otherwise the turn runs as an agent in
    /// that folder, approving actions with `permissions`. `resume` is the session id from the
    /// reply before this turn; the stream reports the new turn's own session id, so earlier
    /// ids stay resumable for regenerate. A client that can add messages to a running turn
    /// opens `steering`; one that can't leaves it, and those messages wait for the next turn.
    func send(_ content: [ContentBlock], model: ChatModel, effort: Effort, resume sessionID: String?,
              agentDirectory: URL?, permissions: AgentPermissions, steering: Steering) -> AsyncThrowingStream<ChatEvent, Error>
    /// A short title for a new chat, or nil if none could be made. Runs on the chat's own
    /// backend; `model` is the chat's model.
    func title(question: String, answer: String, model: ChatModel) async -> String?
}

public extension ChatStreamingClient {
    func title(question: String, answer: String, model: ChatModel) async -> String? { nil }
}

extension AsyncThrowingStream where Element == ChatEvent, Failure == Error {
    /// A turn's event stream: `body` runs detached and yields into it; returning finishes the
    /// stream, throwing fails it, and cancelling the consumer (or dropping the stream)
    /// cancels `body`, which is how each client stops its CLI.
    static func turn(_ body: @escaping @Sendable (Continuation) async throws -> Void) -> Self {
        AsyncThrowingStream { continuation in
            let task = Task.detached {
                do {
                    try await body(continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// What every backend's parser tracks for one reply: the text so far and how the turn ended.
/// The parsers only map their CLI's wire format onto it.
struct TurnState: Sendable {
    private(set) var text = ""
    var isFinished = false
    /// Set when the CLI reported a failure (or the person stopped the reply).
    var errorMessage: String?
    /// Set when the CLI started something an ordinary chat must not do; the turn then stops.
    var violation: String?

    /// Adds a streamed chunk of reply text. Empty chunks are dropped.
    mutating func append(_ chunk: String) -> [ChatEvent] {
        guard !chunk.isEmpty else { return [] }
        text += chunk
        return [.text(chunk)]
    }

    /// The CLI took a steered message: a new reply starts, with its own text and ending.
    mutating func steered() -> [ChatEvent] {
        text = ""
        isFinished = false
        errorMessage = nil
        return [.steered]
    }

    /// Text after a tool call or a second message starts a new paragraph.
    mutating func startParagraph() -> [ChatEvent] {
        guard !text.isEmpty, !text.hasSuffix("\n\n") else { return [] }
        return append(text.hasSuffix("\n") ? "\n" : "\n\n")
    }

    /// Yields `events`, then throws if the turn hit something it must not do.
    func deliver(_ events: [ChatEvent], to continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation) throws {
        for event in events { continuation.yield(event) }
        if let violation { throw ChatError.failed(violation) }
    }

    /// After the CLI's output ends: throws the error the turn ended with, or `unfinished`
    /// when it never said it was done.
    func finish(orElse unfinished: @autoclosure () -> String) throws {
        try Task.checkCancellation()
        if let violation { throw ChatError.failed(violation) }
        if let errorMessage { throw ChatError.failed(errorMessage) }
        guard isFinished else { throw ChatError.failed(unfinished()) }
    }
}
