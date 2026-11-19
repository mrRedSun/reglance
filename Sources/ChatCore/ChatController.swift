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
    /// The reply streaming in each chat that has one, by chat id.
    public private(set) var streamingReplies: [UUID: UUID] = [:]
    /// Chats with a reply currently streaming.
    public var streaming: Set<UUID> { Set(streamingReplies.keys) }

    @ObservationIgnored private let store: ChatStore
    @ObservationIgnored private let client: any ChatStreamingClient
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var titleTasks: [UUID: Task<Void, Never>] = [:]
    /// A callback may mutate a chat only while its turn is the chat's current one.
    @ObservationIgnored private var activeTurns: [UUID: ActiveTurn] = [:]
    /// Messages steered into a chat's running turn that its CLI hasn't taken yet, oldest
    /// first. Whatever is left when the turn ends is sent as the next turn.
    @ObservationIgnored private var pendingSteers: [UUID: [UUID]] = [:]

    /// One turn streaming in a chat: the reply it writes into now (a steered message starts
    /// a new one) and the channel for steered messages.
    private struct ActiveTurn {
        let id = UUID()
        let firstReplyID: UUID
        var replyID: UUID
        let steering = Steering()
    }

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
        id.map { streamingReplies[$0] != nil } ?? false
    }

    /// The reply streaming in `id` right now, if any.
    public func streamingReply(in id: UUID?) -> UUID? {
        id.flatMap { streamingReplies[$0] }
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
        pendingSteers[chatID] = nil
        cancel(chatID)
        if let turn = activeTurns[chatID] {
            finish(chatID: chatID, turnID: turn.id, error: "Stopped")
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
    /// chat also keeps its backend: a model from another backend is ignored. While the chat
    /// is replying, the message steers the running turn instead (its model and effort stay).
    @discardableResult
    public func send(_ text: String, attachments: [AttachmentDraft] = [], model: ChatModel, effort: Effort = .automatic,
                     agentDirectory: URL? = nil, agentPermissions: AgentPermissions = .auto, to chatID: UUID?) -> UUID {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var chat = chat(chatID) ?? Chat(firstMessage: prompt.isEmpty ? attachments.first?.name ?? "" : prompt, model: model,
                                        agentDirectory: agentDirectory, agentPermissions: agentPermissions)
        guard !prompt.isEmpty || !attachments.isEmpty else { return chat.id }
        let steers = activeTurns[chat.id] != nil

        if model.backend == chat.backend, !steers {
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
        if steers {
            steer(message, into: chat)
        } else {
            startReply(in: chat, to: [message], resume: chat.sessionID)
        }
        return chat.id
    }

    /// Shows `message` at once and hands it to the running turn. The reply splits when the
    /// CLI takes it (`.steered`); if the turn ends first, `finish` sends it as the next turn.
    private func steer(_ message: Message, into chat: Chat) {
        guard let turn = activeTurns[chat.id] else { return }
        put(chat)
        pendingSteers[chat.id, default: []].append(message.id)
        // A file that can't be read back goes with the next turn, which reports it.
        guard let content = try? store.contentBlocks(for: message) else { return }
        Task { _ = await turn.steering.steer(content) }
    }

    /// Where an attachment's copy lives.
    public func url(for attachment: Attachment) -> URL {
        attachment.url(in: store.directory)
    }

    /// Whether the last reply can be regenerated: it must follow a user message, and the
    /// session from before that turn must be known (chats saved before per-reply session
    /// ids existed don't have it).
    public func canRegenerate(_ chatID: UUID) -> Bool {
        guard let chat = chat(chatID), !isStreaming(chatID) else { return false }
        return regenerateSession(of: chat) != nil
    }

    /// Replaces the last reply with a new answer to the same question.
    public func regenerate(_ chatID: UUID, model: ChatModel? = nil, effort: Effort? = nil) {
        guard var chat = chat(chatID), !isStreaming(chatID),
              let resume = regenerateSession(of: chat) else { return }
        // Like `send`, the chat stays on its own backend.
        if let model, model.backend == chat.backend {
            chat.model = model
            if let effort { chat.effort = effort }
        } else if model == nil, let effort {
            chat.effort = effort
        }
        chat.messages.removeLast()
        startReply(in: chat, to: [chat.messages[chat.messages.count - 1]], resume: resume)
    }

    /// `.some(nil)` means the last turn was the first one, so the CLI starts a fresh session.
    private func regenerateSession(of chat: Chat) -> String?? {
        let messages = chat.messages
        guard messages.count >= 2, messages[messages.count - 1].role == .assistant,
              messages[messages.count - 2].role == .user else { return nil }
        guard let previous = messages.dropLast(2).last(where: { $0.role == .assistant }) else { return .some(nil) }
        return previous.sessionID.map { .some($0) }
    }

    /// Appends an empty assistant message to `chat` and streams the reply to `questions` (one
    /// message, or steered messages a turn ended without taking) into it.
    private func startReply(in chat: Chat, to questions: [Message], resume: String?) {
        var chat = chat
        let model = chat.model
        let effort = chat.effort
        chat.messages.append(Message(role: .assistant, text: ""))
        chat.updatedAt = Date()
        let id = chat.id
        let replyID = chat.messages[chat.messages.count - 1].id
        put(chat)
        let turn = ActiveTurn(firstReplyID: replyID, replyID: replyID)
        activeTurns[id] = turn
        streamingReplies[id] = replyID

        let content: [ContentBlock]
        do {
            content = try questions.flatMap { try store.contentBlocks(for: $0) }
        } catch {
            finish(chatID: id, turnID: turn.id, error: error.localizedDescription)
            return
        }
        let stream = client.send(content, model: model, effort: effort, resume: resume, agentDirectory: chat.agentDirectory,
                                 permissions: chat.agentPermissions, steering: turn.steering)
        tasks[id] = Task { [weak self] in
            var failure: String?
            do {
                for try await event in stream {
                    try Task.checkCancellation()
                    self?.apply(event, chatID: id, turnID: turn.id)
                }
                if Task.isCancelled { failure = "Stopped" }
            } catch is CancellationError {
                failure = "Stopped"
            } catch {
                failure = Task.isCancelled ? "Stopped" : error.localizedDescription
            }
            self?.finish(chatID: id, turnID: turn.id, error: failure)
        }
    }

    public func cancel(_ chatID: UUID) {
        tasks[chatID]?.cancel()
    }

    /// Waits for the in-flight reply of `chatID` (used by the CLI).
    public func waitForReply(_ chatID: UUID) async {
        await tasks[chatID]?.value
    }

    private func apply(_ event: ChatEvent, chatID: UUID, turnID: UUID) {
        guard let turn = activeTurns[chatID], turn.id == turnID else { return }
        if event == .steered { return startSteeredReply(chatID: chatID) }
        let replyID = turn.replyID
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
            case .steered:
                break
            }
        }
    }

    /// The CLI took the oldest steered message: the reply so far ends there and a new one,
    /// placed right after that message, gets the rest of the turn.
    private func startSteeredReply(chatID: UUID) {
        guard var turn = activeTurns[chatID], var pending = pendingSteers[chatID], !pending.isEmpty,
              var chat = chat(chatID) else { return }
        let messageID = pending.removeFirst()
        pendingSteers[chatID] = pending.isEmpty ? nil : pending
        guard let index = chat.messages.firstIndex(where: { $0.id == messageID }) else { return }
        // The earlier reply's session already holds the steered message and what follows, so
        // regenerate can't go back to it: it keeps no session of its own.
        if let previous = chat.messages.firstIndex(where: { $0.id == turn.replyID }) {
            chat.messages[previous].sessionID = nil
        }
        let reply = Message(role: .assistant, text: "")
        chat.messages.insert(reply, at: index + 1)
        turn.replyID = reply.id
        activeTurns[chatID] = turn
        streamingReplies[chatID] = reply.id
        put(chat)
    }

    private func finish(chatID: UUID, turnID: UUID, error: String?) {
        guard let turn = activeTurns[chatID], turn.id == turnID else { return }
        turn.steering.end()
        activeTurns[chatID] = nil
        tasks[chatID] = nil
        streamingReplies[chatID] = nil
        update(chatID) { chat in
            chat.updatedAt = Date()
            if let error, let index = chat.messages.firstIndex(where: { $0.id == turn.replyID }) {
                chat.messages[index].error = error
            }
        }
        guard let chat = chat(chatID) else { return }
        put(chat)
        if error == nil { generateTitle(for: chat, firstReplyID: turn.firstReplyID) }
        // Steered messages the turn ended without taking (it finished, failed or was
        // stopped first) are answered next, together.
        if let pending = pendingSteers.removeValue(forKey: chatID) {
            let questions = chat.messages.filter { pending.contains($0.id) }
            if !questions.isEmpty { startReply(in: chat, to: questions, resume: chat.sessionID) }
        }
    }

    /// After the chat's first reply succeeds, replace the first-message title with a
    /// generated one, unless the person renamed the chat in the meantime.
    private func generateTitle(for chat: Chat, firstReplyID: UUID) {
        guard chat.titleIsAutomatic,
              let answer = chat.messages.first(where: { $0.role == .assistant }), answer.id == firstReplyID,
              let question = chat.messages.first(where: { $0.role == .user }), !answer.text.isEmpty else { return }
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
