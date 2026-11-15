import Foundation

public enum ClaudeModel: String, Codable, CaseIterable, Identifiable, Sendable {
    case haiku = "claude-haiku-5-5"
    case sonnet = "claude-sonnet-5-5"
    case opus = "claude-opus-5-5"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .haiku: "Haiku"
        case .sonnet: "Sonnet"
        case .opus: "Opus"
        }
    }
}

public struct Message: Codable, Identifiable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable { case user, assistant }

    public var id: UUID
    public var role: Role
    public var text: String
    public var createdAt: Date
    /// Set when the reply failed or was cancelled; shown under the (possibly partial) text.
    public var error: String?
    /// Assistant only: the CLI session right after this reply. Resuming it continues the
    /// conversation from this point, which is what regenerate relies on.
    public var sessionID: String?
    /// Assistant only: streamed extended-thinking text, if the model produced any.
    public var thinking: String?
    /// Assistant only: seconds from sending until the first reply text ("Thought for Ns").
    public var thinkingDuration: TimeInterval?
    /// Assistant only: web searches and page fetches made while answering, in order.
    public var toolSteps: [ToolStep]?
    /// User only: files sent with the message.
    public var attachments: [Attachment]?

    public init(role: Role, text: String, error: String? = nil) {
        self.id = UUID()
        self.role = role
        self.text = text
        self.createdAt = Date()
        self.error = error
    }
}

/// One tool call shown as progress, e.g. a search query or a fetched URL.
public struct ToolStep: Codable, Equatable, Sendable {
    /// `WebSearch` or `WebFetch`.
    public var name: String
    /// The search query or URL.
    public var detail: String
    /// Length of the reply text (UTF-8) when the call started. While the text is still
    /// this long, the tool is running; any text after it means Claude moved on.
    public var textOffset: Int?

    public init(name: String, detail: String, textOffset: Int? = nil) {
        self.name = name
        self.detail = detail
        self.textOffset = textOffset
    }
}

public struct Chat: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    /// Claude CLI session id, used with `--resume` for follow-ups.
    public var sessionID: String?
    public var model: ClaudeModel
    public var messages: [Message]

    public init(firstMessage: String, model: ClaudeModel) {
        let now = Date()
        self.id = UUID()
        self.title = Chat.makeTitle(from: firstMessage)
        self.createdAt = now
        self.updatedAt = now
        self.sessionID = nil
        self.model = model
        self.messages = []
    }

    static func makeTitle(from text: String) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 80 ? String(trimmed.prefix(80)) + "…" : trimmed
    }
}
