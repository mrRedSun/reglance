import ChatCore
import Foundation
import Testing
@testable import Reglance

@MainActor
struct ModelLibraryTests {
    private let codex = ModelOption(model: ChatModel(backend: .codex, id: "gpt-6-luna"), name: "GPT-6-Luna")

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "model-library-test-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    @Test func thePillShowsTheCLIsNameOrOneMadeFromTheID() throws {
        try withDefaults { defaults in
            let library = ModelLibrary(fixed: [.claude: DemoContent.models, .codex: [codex]], defaults: defaults)
            #expect(library.name(for: codex.model) == "GPT-6-Luna")
            #expect(library.name(for: .opus) == "Opus 5.5")
            #expect(library.name(for: ChatModel(backend: .codex, id: "gpt-4.1")) == "GPT-4.1")
        }
    }

    @Test func aSwitchedOffBackendLeavesThePickerAndNewChats() throws {
        try withDefaults { defaults in
            let library = ModelLibrary(fixed: [.claude: DemoContent.models, .codex: [codex]], defaults: defaults)
            #expect(library.backends == [.claude, .codex])
            library.setEnabled(.codex, false)
            #expect(library.backends == [.claude])
            // A remembered Codex model starts the next new chat on Claude's default.
            #expect(library.usable(codex.model) == .sonnet)
            // Its name is still known for chats already on it.
            #expect(library.name(for: codex.model) == "GPT-6-Luna")
            // Claude can't be switched off, and the choice survives a relaunch.
            library.setEnabled(.claude, false)
            let relaunched = ModelLibrary(fixed: [.claude: DemoContent.models, .codex: [codex]], defaults: defaults)
            #expect(relaunched.isEnabled(.claude) && !relaunched.isEnabled(.codex))
        }
    }

    @Test func aNewChatMovesARememberedOlderModelToTheNewestOfItsFamily() throws {
        try withDefaults { defaults in
            let sonnet5 = ModelOption(model: ChatModel(backend: .claude, id: "claude-sonnet-5"), name: "Claude Sonnet 5")
            let library = ModelLibrary(fixed: [.claude: DemoContent.models + [sonnet5]], defaults: defaults)
            #expect(library.usable(sonnet5.model) == .sonnet)
            #expect(library.usable(.opus) == .opus)
            // A model outside the Claude and OpenAI families stays as it is.
            let glm = ChatModel(backend: .opencode, id: "zai/glm-5.2")
            #expect(library.usable(glm) == glm)
        }
    }

    @Test func modelsLoadFromTheCacheWithoutAskingACLI() throws {
        try withDefaults { defaults in
            let cache = FileManager.default.temporaryDirectory.appending(path: "models-cache-test-\(UUID()).json")
            defer { try? FileManager.default.removeItem(at: cache) }
            let byName = ["claude": DemoContent.models, "codex": [codex]]
            try JSONEncoder().encode(byName).write(to: cache)
            let library = ModelLibrary(cacheURL: cache, defaults: defaults)
            #expect(library.options[.claude] == DemoContent.models)
            #expect(library.option(for: codex.model) == codex)
            #expect(library.defaultModel(for: .claude) == .sonnet)
        }
    }
}

@MainActor
struct ModelLockTests {
    private let codex = ModelOption(model: ChatModel(backend: .codex, id: "gpt-6-luna"), name: "GPT-6-Luna",
                                    efforts: [.automatic, .high])

    @Test func agentModeSwitchesToClaudeVisiblyAndGivesTheModelBack() {
        let library = ModelLibrary(fixed: [.claude: DemoContent.models, .codex: [codex]],
                                   defaults: UserDefaults(suiteName: "model-lock-test-\(UUID())")!)
        var lock = ModelLock()
        var model = codex.model, effort = Effort.high
        lock.apply(nil, chat: nil, model: &model, effort: &effort, library: library)
        #expect(model == codex.model && lock.switchedFrom == nil)

        // Agent mode on: Claude Code only, and the composer says what it replaced.
        lock.apply(.claude, chat: nil, model: &model, effort: &effort, library: library)
        #expect(model == .sonnet && effort == .automatic)
        #expect(lock.switchedFrom == codex.model)

        // Agent mode off: the earlier choice comes back.
        lock.apply(nil, chat: nil, model: &model, effort: &effort, library: library)
        #expect(model == codex.model && effort == .high && lock.switchedFrom == nil)
    }

    @Test func aClaudeModelStaysWhenAgentModeTurnsOn() {
        let library = ModelLibrary(fixed: [.claude: DemoContent.models],
                                   defaults: UserDefaults(suiteName: "model-lock-test-\(UUID())")!)
        var lock = ModelLock()
        var model = ChatModel.opus, effort = Effort.max
        lock.apply(.claude, chat: nil, model: &model, effort: &effort, library: library)
        #expect(model == .opus && effort == .max && lock.switchedFrom == nil)
    }

    @Test func anOpenChatUsesItsOwnModel() {
        let library = ModelLibrary(fixed: [.claude: DemoContent.models, .codex: [codex]],
                                   defaults: UserDefaults(suiteName: "model-lock-test-\(UUID())")!)
        var chat = Chat(firstMessage: "Hi", model: codex.model)
        chat.effort = .high
        var lock = ModelLock()
        var model = ChatModel.opus, effort = Effort.automatic
        lock.apply(.codex, chat: chat, model: &model, effort: &effort, library: library)
        #expect(model == codex.model && effort == .high && lock.switchedFrom == nil)
    }
}
