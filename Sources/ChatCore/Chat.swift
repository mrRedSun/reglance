import Foundation

/// Claude model ids the app needs before or without Claude Code's model list: the default
/// for a new chat, titles, and demo mode. Names and descriptions come from the CLI.
public enum ClaudeModel: String, Codable, CaseIterable, Identifiable, Sendable {
    case haiku = "claude-haiku-5-5"
    case sonnet = "claude-sonnet-5-5"
    case opus = "claude-opus-5-5"

    public var id: String { rawValue }
}

/// Reasoning effort. Each backend maps it to its own option and accepts a subset
/// (`ModelOption.efforts`). Automatic leaves the CLI default unchanged.
public enum Effort: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic, minimal, low, medium, high, xhigh, max

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .automatic: "Automatic"
        case .minimal: "Minimal"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .xhigh: "Extra high"
        case .max: "Max"
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
    /// Assistant only: tool calls made while answering, in order.
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

/// How an agent chat's actions are approved. Print mode can't ask, so the CLI decides.
public enum AgentPermissions: String, Codable, Sendable {
    /// Claude Code's auto mode: a classifier runs actions it judges safe and blocks risky ones.
    case auto
    /// Every action runs without asking. Opt-in from Settings.
    case bypass

    /// The CLI's `--permission-mode` value.
    public var cliMode: String {
        switch self {
        case .auto: "auto"
        case .bypass: "bypassPermissions"
        }
    }
}

/// One tool call shown as progress, e.g. a search query or a fetched URL.
public struct ToolStep: Codable, Equatable, Sendable {
    /// The CLI's tool name: `WebSearch` or `WebFetch` in chats, any tool in agent chats.
    public var name: String
    /// The search query, URL, command or file path.
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
    /// The title still comes from the app (the first message, then a generated title).
    /// False once the person renames the chat, so a generated title never overwrites theirs.
    public var titleIsAutomatic: Bool
    public var createdAt: Date
    public var updatedAt: Date
    /// The backend CLI's session id, used to resume for follow-ups.
    public var sessionID: String?
    /// Its backend is fixed when the chat is created; only the model on that backend changes.
    public var model: ChatModel
    public var effort: Effort
    public var isPinned: Bool
    public var isArchived: Bool
    /// Set for agent chats: the folder the CLI runs in, with the normal Claude Code
    /// environment. Nil for ordinary chats, which stay limited to web search and fetch.
    /// Fixed when the chat is created; a CLI session can only be resumed from the folder
    /// it was created in.
    public var agentDirectory: URL?
    /// How an agent chat's actions are approved, fixed when the chat is created.
    /// Ignored for ordinary chats.
    public var agentPermissions: AgentPermissions
    public var messages: [Message]

    public var isAgent: Bool { agentDirectory != nil }
    public var backend: Backend { model.backend }

    public init(firstMessage: String, model: ChatModel, effort: Effort = .automatic, agentDirectory: URL? = nil,
                agentPermissions: AgentPermissions = .auto) {
        let now = Date()
        self.id = UUID()
        self.title = Chat.makeTitle(from: firstMessage)
        self.titleIsAutomatic = true
        self.createdAt = now
        self.updatedAt = now
        self.sessionID = nil
        self.model = model
        self.effort = effort
        self.isPinned = false
        self.isArchived = false
        self.agentDirectory = agentDirectory
        self.agentPermissions = agentPermissions
        self.messages = []
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, titleIsAutomatic, createdAt, updatedAt, sessionID, model, effort, isPinned, isArchived, agentDirectory, agentPermissions, messages
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        // Chats saved before generated titles keep the title they have.
        titleIsAutomatic = try values.decodeIfPresent(Bool.self, forKey: .titleIsAutomatic) ?? false
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        sessionID = try values.decodeIfPresent(String.self, forKey: .sessionID)
        model = try values.decode(ChatModel.self, forKey: .model)
        effort = try values.decodeIfPresent(Effort.self, forKey: .effort) ?? .automatic
        isPinned = try values.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        isArchived = try values.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        agentDirectory = try values.decodeIfPresent(URL.self, forKey: .agentDirectory)
        // Agent chats saved before auto mode were created with permissions bypassed.
        agentPermissions = try values.decodeIfPresent(AgentPermissions.self, forKey: .agentPermissions) ?? .bypass
        messages = try values.decode([Message].self, forKey: .messages)
    }

    /// Stable library ordering, shared by disk loading and in-memory updates.
    static func precedes(_ lhs: Chat, _ rhs: Chat) -> Bool {
        if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    static func makeTitle(from text: String) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 80 ? String(trimmed.prefix(80)) + "…" : trimmed
    }
}
