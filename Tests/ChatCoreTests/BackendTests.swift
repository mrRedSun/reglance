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

@Test func claudeModelsComeFromTheCLIsInitializeResponse() throws {
    // The shape Claude Code answers the stream-json `initialize` request with.
    let models: [[String: Any]] = [
        ["value": "default", "resolvedModel": "claude-opus-5-5", "displayName": "Default (recommended)",
         "description": "Use the default model (currently Opus 5.5) · $4/$20 per Mtok", "supportedEffortLevels": ["low", "high"]],
        ["value": "opus", "resolvedModel": "claude-opus-5-5", "displayName": "Opus",
         "description": "Opus 5.5 · Best for everyday, complex tasks · $4/$20 per Mtok",
         "supportedEffortLevels": ["low", "medium", "high", "xhigh", "max"]],
        ["value": "claude-fable-5-2", "resolvedModel": "claude-fable-5-2", "displayName": "Claude Fable 5.2",
         "description": "From gateway", "supportedEffortLevels": ["low", "ultra"]],
        ["value": "haiku", "displayName": "Haiku", "description": "Haiku 5.5 · Fastest for quick answers · $0.10/$0.50 per Mtok"],
    ]
    let response: [String: Any] = ["type": "control_response",
                                   "response": ["subtype": "success", "request_id": "models", "response": ["models": models]]]
    let line = String(decoding: try JSONSerialization.data(withJSONObject: response), as: UTF8.self)
    let options = try #require(ClaudeBackend.modelOptions(fromOutput: #"{"type":"system"}"# + "\n" + line + "\n"))
    // The default row repeats Opus; the pinned id is saved, not the alias.
    #expect(options.map(\.model.id) == ["claude-opus-5-5", "claude-fable-5-2", "haiku"])
    #expect(options.allSatisfy { $0.model.backend == .claude })
    // Name and detail come from the description; the price is left out.
    #expect(options[0].name == "Opus 5.5" && options[0].detail == "Best for everyday, complex tasks")
    #expect(options[0].efforts == [.automatic, .low, .medium, .high, .xhigh, .max])
    // A gateway's row has no such description: it's named like the others, with no detail.
    #expect(options[1].name == "Fable 5.2" && options[1].detail.isEmpty)
    #expect(options[1].efforts == [.automatic, .low])
    #expect(options[2].name == "Haiku 5.5" && options[2].efforts == [.automatic])
    #expect(ClaudeBackend.modelOptions(fromOutput: #"{"type":"result"}"#) == nil)
}

@Test func aModelTheCLINoLongerListsGetsANameFromItsID() {
    #expect(ChatModel.sonnet.fallbackName == "Sonnet 5.5")
    #expect(ChatModel(backend: .claude, id: "claude-sonnet-4-5-20250929").fallbackName == "Sonnet 4.5")
    #expect(ChatModel(backend: .claude, id: "claude-sonnet-5").fallbackName == "Sonnet 5")
    #expect(ChatModel(backend: .codex, id: "gpt-5.5").fallbackName == "GPT-5.5")
    #expect(ChatModel(backend: .opencode, id: "openai/gpt-5.5-mini").fallbackName == "GPT-5.5-mini")
    #expect(ChatModel(backend: .opencode, id: "zai/glm-5.3").fallbackName == "glm-5.3")
}

@Test func popularClaudeAndOpenAIFamiliesGetTheirOwnSymbol() {
    #expect(ModelSymbol.symbol(for: "claude-haiku-5-5") == "bolt")
    #expect(ModelSymbol.symbol(for: "claude-sonnet-5-5") == "wand.and.stars")
    #expect(ModelSymbol.symbol(for: "claude-opus-5-5") == "brain")
    #expect(ModelSymbol.symbol(for: "claude-fable-5-2") == "book.closed")
    #expect(ModelSymbol.symbol(for: "gpt-5.5") == "atom")
    #expect(ModelSymbol.symbol(for: "openai/gpt-5.5") == "atom")
    #expect(ModelSymbol.symbol(for: "gpt-5.5-codex-mini") == "chevron.left.forwardslash.chevron.right")
    #expect(ModelSymbol.symbol(for: "gpt-5.5-mini") == "hare")
    #expect(ModelSymbol.symbol(for: "gpt-5.5-pro") == "crown")
    #expect(ModelSymbol.symbol(for: "o3") == "lightbulb")
    #expect(ModelSymbol.symbol(for: "zai/glm-5.3") == "sparkles")
}

@Test func thePickerOffersOnlyTheNewestClaudeAndOpenAIModelOfEachFamily() {
    func options(_ backend: Backend, _ ids: [String]) -> [ModelOption] {
        ids.map { ModelOption(model: ChatModel(backend: backend, id: $0), name: $0) }
    }
    let claude = options(.claude, ["claude-opus-5-5", "claude-fable-5-2", "claude-sonnet-5-5", "claude-haiku-5-5",
                                   "claude-sonnet-5", "claude-opus-4-5-20251101"])
    #expect(ModelFamily.latest(claude).map(\.model.id)
            == ["claude-opus-5-5", "claude-fable-5-2", "claude-sonnet-5-5", "claude-haiku-5-5"])
    // A chat on an older model still finds it.
    let sonnet5 = ChatModel(backend: .claude, id: "claude-sonnet-5")
    #expect(ModelFamily.latest(claude, keeping: sonnet5).map(\.model.id).contains("claude-sonnet-5"))

    let codex = options(.codex, ["gpt-6-astra", "gpt-6-sol", "gpt-6-luna", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"])
    // Terra has no newer version, so it stays.
    #expect(ModelFamily.latest(codex).map(\.model.id) == ["gpt-6-astra", "gpt-6-sol", "gpt-6-luna", "gpt-5.6-terra"])

    let openCode = options(.opencode, ["openai/gpt-5.5", "openai/gpt-5", "openai/gpt-5.5-mini", "openai/o3", "openai/o4-mini",
                                       "openai/o3-mini", "zai-coding-plan/glm-5.3", "zai-coding-plan/glm-5.2"])
    // Other providers aren't filtered.
    #expect(ModelFamily.latest(openCode).map(\.model.id)
            == ["openai/gpt-5.5", "openai/gpt-5.5-mini", "openai/o3", "openai/o4-mini",
                "zai-coding-plan/glm-5.3", "zai-coding-plan/glm-5.2"])
}
