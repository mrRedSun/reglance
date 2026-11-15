import Foundation
import Observation

/// Owns all chats and in-flight replies. The floating bar and the main window share one
/// instance, so a chat can be continued from either place.
@MainActor
@Observable
public final class ChatController {
    /// Most recently updated first.
    public private(set) var chats: [Chat]
    /// Chats with a reply currently streaming.
    public private(set) var streaming: Set<UUID> = []

    @ObservationIgnored private let store: ChatStore
    @ObservationIgnored private let client: ClaudeClient
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]

    public init(store: ChatStore = ChatStore(), client: ClaudeClient = ClaudeClient()) {
        self.store = store
        self.client = client
        self.chats = store.loadAll()
    }

    public func chat(_ id: UUID?) -> Chat? {
        guard let id else { return nil }
        return chats.first { $0.id == id }
    }

    public func isStreaming(_ id: UUID?) -> Bool {
        id.map(streaming.contains) ?? false
    }

    /// Sends `text` and `attachments` to an existing chat, or starts a new chat when
    /// `chatID` is nil. Returns the chat id.
    @discardableResult
    public func send(_ text: String, attachments: [AttachmentDraft] = [], model: ClaudeModel, to chatID: UUID?) -> UUID {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var chat = chat(chatID) ?? Chat(firstMessage: prompt.isEmpty ? attachments.first?.name ?? "" : prompt, model: model)
        guard !prompt.isEmpty || !attachments.isEmpty, !streaming.contains(chat.id) else { return chat.id }

        chat.model = model
        var message = Message(role: .user, text: prompt)
        if !attachments.isEmpty {
            // A failed copy surfaces when the reply starts (the file can't be read back).
            message.attachments = attachments.map { draft in
                (try? store.saveAttachment(draft, chatID: chat.id))
                    ?? Attachment(id: draft.id, kind: draft.kind, name: draft.name, mediaType: draft.mediaType, path: "")
            }
        }
        chat.messages.append(message)
        startReply(in: chat, to: message, resume: chat.sessionID)
        return chat.id
    }

    /// Where an attachment's copy lives.
    public func url(for attachment: Attachment) -> URL {
        attachment.url(in: store.directory)
    }

    /// Whether the last reply can be regenerated: it must follow a user message, and the
    /// session from before that turn must be known (chats saved before per-reply session
    /// ids existed don't have it).
    public func canRegenerate(_ chatID: UUID) -> Bool {
        guard let chat = chat(chatID), !streaming.contains(chatID) else { return false }
        return regenerateSession(of: chat) != nil
    }

    /// Replaces the last reply with a new answer to the same question.
    public func regenerate(_ chatID: UUID) {
        guard var chat = chat(chatID), !streaming.contains(chatID),
              let resume = regenerateSession(of: chat) else { return }
        chat.messages.removeLast()
        startReply(in: chat, to: chat.messages[chat.messages.count - 1], resume: resume)
    }

    /// `.some(nil)` means the last turn was the first one, so the CLI starts a fresh session.
    private func regenerateSession(of chat: Chat) -> String?? {
        let messages = chat.messages
        guard messages.count >= 2, messages[messages.count - 1].role == .assistant,
              messages[messages.count - 2].role == .user else { return nil }
        guard let previous = messages.dropLast(2).last(where: { $0.role == .assistant }) else { return .some(nil) }
        return previous.sessionID.map { .some($0) }
    }

    /// Appends an empty assistant message to `chat` and streams the reply to `question` into it.
    private func startReply(in chat: Chat, to question: Message, resume: String?) {
        var chat = chat
        let model = chat.model
        chat.messages.append(Message(role: .assistant, text: ""))
        chat.updatedAt = Date()
        let id = chat.id
        let replyID = chat.messages[chat.messages.count - 1].id
        put(chat)
        streaming.insert(id)

        let content: [ContentBlock]
        do {
            content = try store.contentBlocks(for: question)
        } catch {
            finish(chatID: id, replyID: replyID, error: error.localizedDescription)
            return
        }
        let stream = client.send(content, model: model, resume: resume)
        tasks[id] = Task { [weak self] in
            var failure: String?
            do {
                for try await event in stream {
                    self?.apply(event, chatID: id, replyID: replyID)
                }
                if Task.isCancelled { failure = "Stopped" }
            } catch is CancellationError {
                failure = "Stopped"
            } catch {
                failure = Task.isCancelled ? "Stopped" : error.localizedDescription
            }
            self?.finish(chatID: id, replyID: replyID, error: failure)
        }
    }

    public func cancel(_ chatID: UUID) {
        tasks[chatID]?.cancel()
    }

    /// Waits for the in-flight reply of `chatID` (used by the CLI).
    public func waitForReply(_ chatID: UUID) async {
        await tasks[chatID]?.value
    }

    private func apply(_ event: ClaudeEvent, chatID: UUID, replyID: UUID) {
        update(chatID) { chat in
            guard let index = chat.messages.firstIndex(where: { $0.id == replyID }) else { return }
            switch event {
            case .session(let sessionID):
                chat.sessionID = sessionID
                chat.messages[index].sessionID = sessionID
            case .text(let chunk):
                // "Thought for Ns" / "Searched … · Ns": time until the first text, or until
                // the text that follows the last tool call.
                let reply = chat.messages[index]
                let resumesAfterTool = reply.toolSteps?.last?.textOffset == reply.text.utf8.count
                if reply.thinkingDuration == nil || resumesAfterTool {
                    chat.messages[index].thinkingDuration = Date().timeIntervalSince(reply.createdAt)
                }
                chat.messages[index].text += chunk
            case .thinking(let chunk):
                chat.messages[index].thinking = (chat.messages[index].thinking ?? "") + chunk
            case .tool(let name, let detail):
                chat.messages[index].toolSteps = (chat.messages[index].toolSteps ?? []) + [ToolStep(name: name, detail: detail, textOffset: chat.messages[index].text.utf8.count)]
            case .finished(let sessionID, _):
                if let sessionID {
                    chat.sessionID = sessionID
                    chat.messages[index].sessionID = sessionID
                }
            }
        }
    }

    private func finish(chatID: UUID, replyID: UUID, error: String?) {
        tasks[chatID] = nil
        streaming.remove(chatID)
        update(chatID) { chat in
            chat.updatedAt = Date()
            if let error, let index = chat.messages.firstIndex(where: { $0.id == replyID }) {
                chat.messages[index].error = error
            }
        }
        if let chat = chat(chatID) { persist(chat) }
    }

    private func update(_ chatID: UUID, _ body: (inout Chat) -> Void) {
        guard let index = chats.firstIndex(where: { $0.id == chatID }) else { return }
        body(&chats[index])
    }

    /// Inserts or replaces the chat, moves it to the top, and saves it.
    private func put(_ chat: Chat) {
        chats.removeAll { $0.id == chat.id }
        chats.insert(chat, at: 0)
        persist(chat)
    }

    private func persist(_ chat: Chat) {
        do { try store.save(chat) } catch { NSLog("Reglance: failed to save chat \(chat.id): \(error)") }
    }
}
