import Foundation
import Observation

/// Owns all chats and in-flight replies. The floating bar and the main window share one
/// instance, so a chat can be continued from either place.
@MainActor
@Observable
public final class ChatController {
    /// All chats, pinned first, then most recently updated. Includes archived chats.
    public private(set) var chats: [Chat]
    public var activeChats: [Chat] { chats.filter { !$0.isArchived } }
    public var archivedChats: [Chat] { chats.filter(\.isArchived) }
    /// Chats with a reply currently streaming.
    public private(set) var streaming: Set<UUID> = []

    @ObservationIgnored private let store: ChatStore
    @ObservationIgnored private let client: any ChatStreamingClient
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var titleTasks: [UUID: Task<Void, Never>] = [:]
    /// A callback may mutate a chat only while it owns that chat's current reply.
    @ObservationIgnored private var activeReplies: [UUID: UUID] = [:]

    public init(store: ChatStore = ChatStore(), client: any ChatStreamingClient = BackendRouter.live) {
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

    public func rename(_ chatID: UUID, to title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        editMetadata(chatID) {
            $0.title = title
            $0.titleIsAutomatic = false
        }
    }

    public func setPinned(_ pinned: Bool, for chatID: UUID) {
        editMetadata(chatID) { $0.isPinned = pinned }
    }

    public func setArchived(_ archived: Bool, for chatID: UUID) {
        editMetadata(chatID) { $0.isArchived = archived }
    }

    /// The UI must confirm first. Invalidate callbacks before removing files so a late
    /// reply cannot recreate the JSON or interfere with another in-flight reply.
    public func delete(_ chatID: UUID) throws {
        guard chat(chatID) != nil else { return }
        cancel(chatID)
        if let replyID = activeReplies[chatID] {
            finish(chatID: chatID, replyID: replyID, error: "Stopped")
        }
        try store.delete(chatID)
        chats.removeAll { $0.id == chatID }
    }

    private func editMetadata(_ chatID: UUID, _ edit: (inout Chat) -> Void) {
        guard var chat = chat(chatID) else { return }
        edit(&chat)
        put(chat)
    }

    /// Sends `text` and `attachments` to an existing chat, or starts a new chat when
    /// `chatID` is nil. Returns the chat id. `agentDirectory` and `agentPermissions` only
    /// apply to a new chat: an existing chat keeps the mode it was created with. An existing
    /// chat also keeps its backend: a model from another backend is ignored.
    @discardableResult
    public func send(_ text: String, attachments: [AttachmentDraft] = [], model: ChatModel, effort: Effort = .automatic,
                     agentDirectory: URL? = nil, agentPermissions: AgentPermissions = .auto, to chatID: UUID?) -> UUID {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var chat = chat(chatID) ?? Chat(firstMessage: prompt.isEmpty ? attachments.first?.name ?? "" : prompt, model: model,
                                        agentDirectory: agentDirectory, agentPermissions: agentPermissions)
        guard !prompt.isEmpty || !attachments.isEmpty, !streaming.contains(chat.id) else { return chat.id }

        if model.backend == chat.backend {
            chat.model = model
            chat.effort = effort
        }
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
    public func regenerate(_ chatID: UUID, model: ChatModel? = nil, effort: Effort? = nil) {
        guard var chat = chat(chatID), !streaming.contains(chatID),
              let resume = regenerateSession(of: chat) else { return }
        // Like `send`, the chat stays on its own backend.
        if let model, model.backend == chat.backend {
            chat.model = model
            if let effort { chat.effort = effort }
        } else if model == nil, let effort {
            chat.effort = effort
        }
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
        let effort = chat.effort
        chat.messages.append(Message(role: .assistant, text: ""))
        chat.updatedAt = Date()
        let id = chat.id
        let replyID = chat.messages[chat.messages.count - 1].id
        put(chat)
        streaming.insert(id)
        activeReplies[id] = replyID

        let content: [ContentBlock]
        do {
            content = try store.contentBlocks(for: question)
        } catch {
            finish(chatID: id, replyID: replyID, error: error.localizedDescription)
            return
        }
        let stream = client.send(content, model: model, effort: effort, resume: resume, agentDirectory: chat.agentDirectory,
                                 permissions: chat.agentPermissions)
        tasks[id] = Task { [weak self] in
            var failure: String?
            do {
                for try await event in stream {
                    try Task.checkCancellation()
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

    private func apply(_ event: ChatEvent, chatID: UUID, replyID: UUID) {
        guard activeReplies[chatID] == replyID else { return }
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
            case .usage(var usage):
                usage.duration = Date().timeIntervalSince(chat.messages[index].createdAt)
                chat.messages[index].usage = usage
            case .finished(let sessionID):
                if let sessionID {
                    chat.sessionID = sessionID
                    chat.messages[index].sessionID = sessionID
                }
            }
        }
    }

    private func finish(chatID: UUID, replyID: UUID, error: String?) {
        guard activeReplies[chatID] == replyID else { return }
        activeReplies[chatID] = nil
        tasks[chatID] = nil
        streaming.remove(chatID)
        update(chatID) { chat in
            chat.updatedAt = Date()
            if let error, let index = chat.messages.firstIndex(where: { $0.id == replyID }) {
                chat.messages[index].error = error
            }
        }
        if let chat = chat(chatID) {
            put(chat)
            if error == nil { generateTitle(for: chat) }
        }
    }

    /// After the first successful reply, replace the first-message title with a generated
    /// one, unless the person renamed the chat in the meantime.
    private func generateTitle(for chat: Chat) {
        guard chat.titleIsAutomatic,
              chat.messages.count(where: { $0.role == .assistant }) == 1,
              let question = chat.messages.first(where: { $0.role == .user }),
              let answer = chat.messages.last, answer.role == .assistant, !answer.text.isEmpty else { return }
        let id = chat.id
        let model = chat.model
        let client = client
        let task = Task { [weak self] in
            let title = await client.title(question: question.text, answer: answer.text, model: model)
            guard let self, let title, self.chat(id)?.titleIsAutomatic == true else { return }
            self.editMetadata(id) { $0.title = title }
        }
        titleTasks[id] = task
        // Forget the task however it ended, unless a regenerated reply started a newer one.
        Task { [weak self] in
            await task.value
            if self?.titleTasks[id] == task { self?.titleTasks[id] = nil }
        }
    }

    /// Chats with a title still being generated (for tests).
    var pendingTitleCount: Int { titleTasks.count }

    /// Waits for a pending generated title (used by tests and the CLI).
    public func waitForTitle(_ chatID: UUID) async {
        await titleTasks[chatID]?.value
    }

    private func update(_ chatID: UUID, _ body: (inout Chat) -> Void) {
        guard let index = chats.firstIndex(where: { $0.id == chatID }) else { return }
        body(&chats[index])
    }

    /// Inserts or replaces the chat, restores library ordering, and saves it.
    private func put(_ chat: Chat) {
        chats.removeAll { $0.id == chat.id }
        chats.append(chat)
        chats.sort(by: Chat.precedes)
        persist(chat)
    }

    private func persist(_ chat: Chat) {
        do { try store.save(chat) } catch { NSLog("Reglance: failed to save chat \(chat.id): \(error)") }
    }
}
