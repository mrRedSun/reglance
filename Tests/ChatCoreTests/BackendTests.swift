import Foundation
import Testing
@testable import ChatCore

private func backendStore() -> ChatStore {
    ChatStore(directory: FileManager.default.temporaryDirectory.appending(path: "reglance-backend-tests-\(UUID().uuidString)"))
}

/// Records which backend each request reached.
private actor Calls {
    private(set) var sends: [Backend] = []
    private(set) var titles: [Backend] = []
    func send(_ backend: Backend) { sends.append(backend) }
    func title(_ backend: Backend) { titles.append(backend) }
}

private struct FakeBackendClient: ChatStreamingClient {
    let backend: Backend
    let calls: Calls

    func send(_ content: [ContentBlock], model: ChatModel, effort: Effort, resume sessionID: String?,
              agentDirectory: URL?, permissions: AgentPermissions) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await calls.send(backend)
                continuation.yield(.text("reply"))
                continuation.yield(.finished(sessionID: "\(backend.rawValue)-session", fullText: "reply"))
                continuation.finish()
            }
        }
    }

    func title(question: String, answer: String, model: ChatModel) async -> String? {
        await calls.title(backend)
        return "\(backend.rawValue) title"
    }
}

private func router(_ calls: Calls) -> BackendRouter {
    BackendRouter(clients: Dictionary(uniqueKeysWithValues: Backend.allCases.map { ($0, FakeBackendClient(backend: $0, calls: calls)) }))
}

@Test func legacyChatsLoadAsClaude() throws {
    let data = Data("""
        {"id":"\(UUID())","title":"Old","createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-02T00:00:00Z","model":"claude-opus-5-5","messages":[]}
        """.utf8)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let chat = try decoder.decode(Chat.self, from: data)
    #expect(chat.model == .opus)
    #expect(chat.backend == .claude)
}

@Test func backendIsSavedWithTheChat() throws {
    let store = backendStore()
    defer { try? FileManager.default.removeItem(at: store.directory) }
    let chat = Chat(firstMessage: "Hi", model: ChatModel(backend: .opencode, id: "openai/gpt-5.5"))
    try store.save(chat)
    let loaded = try #require(store.loadAll().first)
    #expect(loaded.model == ChatModel(backend: .opencode, id: "openai/gpt-5.5"))
}

@Test func modelArguments() {
    #expect(ChatModel(argument: "opus") == .opus)
    #expect(ChatModel(argument: "codex:gpt-5.5") == ChatModel(backend: .codex, id: "gpt-5.5"))
    #expect(ChatModel(argument: "opencode:openai/gpt-5.5") == ChatModel(backend: .opencode, id: "openai/gpt-5.5"))
    #expect(ChatModel(argument: "gpt-5.5") == nil)
    #expect(ChatModel(argument: "codex:") == nil)
}

@MainActor @Test func aChatNeverMovesToAnotherBackend() async throws {
    let store = backendStore()
    defer { try? FileManager.default.removeItem(at: store.directory) }
    let calls = Calls()
    let controller = ChatController(store: store, client: router(calls))
    let codex = ChatModel(backend: .codex, id: "gpt-5.5")
    let id = controller.send("First", model: codex, to: nil)
    await controller.waitForReply(id)
    await controller.waitForTitle(id)

    // A follow-up and a regenerate with a Claude model still go to Codex.
    controller.send("Follow-up", model: .opus, effort: .max, to: id)
    await controller.waitForReply(id)
    controller.regenerate(id, model: .sonnet, effort: .high)
    await controller.waitForReply(id)

    #expect(await calls.sends == [.codex, .codex, .codex])
    #expect(await calls.titles == [.codex])
    let chat = try #require(controller.chat(id))
    #expect(chat.model == codex)
    #expect(chat.effort == .automatic)
    #expect(chat.title == "codex title")
}

@MainActor @Test func agentChatsRunOnClaudeOnly() async throws {
    let store = backendStore()
    defer { try? FileManager.default.removeItem(at: store.directory) }
    let calls = Calls()
    let controller = ChatController(store: store, client: router(calls))
    let id = controller.send("Run the tests", model: ChatModel(backend: .codex, id: "gpt-5.5"),
                             agentDirectory: FileManager.default.temporaryDirectory, to: nil)
    await controller.waitForReply(id)
    #expect(await calls.sends.isEmpty)
    #expect(controller.chat(id)?.messages.last?.error == "Agent mode works with Claude Code only for now.")
}
