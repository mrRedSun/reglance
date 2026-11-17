import AppKit
import ChatCore
import Testing
@testable import Reglance

@MainActor
@Suite(.headlessWindows)
struct ComposerSessionTests {
    /// An agent chat, finished, so the composer can leave it.
    private func agentChat(in chats: ChatController) async -> UUID {
        let id = chats.send("List the files", model: .sonnet, agentDirectory: testDirectory("agent"), to: nil)
        await chats.waitForReply(id)
        return id
    }

    @Test func turningAgentModeOffInTheChatsWindowKeepsTheDraft() async throws {
        let chats = makeChats(client: DemoClient(wordDelay: .zero))
        let window = MainWindowModel(chats: chats)
        let agent = await agentChat(in: chats)
        window.selection = agent
        let composer = window.composer
        composer.text = "half-written"
        let tray = composer.attachments

        composer.toggleAgentMode()

        #expect(window.selection == nil, "Leaving an agent chat starts a new chat")
        #expect(composer.agentDirectory == nil)
        #expect(composer.text == "half-written")
        #expect(composer.attachments === tray)
    }

    @Test func openingAnotherChatDropsTheDraftAndFollowsItsModel() async throws {
        let chats = makeChats(client: DemoClient(wordDelay: .zero))
        let composer = makeComposer(chats: chats)
        let first = chats.send("Hi", model: .opus, effort: .high, to: nil)
        await chats.waitForReply(first)
        composer.model = .haiku
        composer.text = "draft"
        let tray = composer.attachments

        composer.open(first)

        #expect(composer.text.isEmpty)
        #expect(composer.attachments !== tray, "A late attachment must land in the old tray")
        #expect(composer.model == .opus && composer.effort == .high)
        // Opening a chat isn't a choice: new chats still start on the last chosen model.
        composer.open(nil)
        #expect(composer.model == .haiku)
    }

    @Test func aNewChatClearsEverythingAndRefocuses() {
        let composer = makeComposer()
        composer.chatID = UUID()
        composer.agentDirectory = testDirectory()
        composer.text = "draft"
        composer.pickerIsPresented = true
        let focus = composer.focusToken

        composer.startNewChat()

        #expect(composer.chatID == nil && composer.agentDirectory == nil && composer.text.isEmpty)
        #expect(!composer.pickerIsPresented)
        #expect(composer.focusToken == focus + 1)
    }

    @Test func sendingStartsAChatAndClearsTheText() async {
        let chats = makeChats(client: DemoClient(wordDelay: .zero))
        let composer = makeComposer(chats: chats)
        composer.text = "Hello"
        composer.send()
        #expect(composer.text.isEmpty)
        guard let id = composer.chatID else { Issue.record("Sending should start a chat"); return }
        await chats.waitForReply(id)
        #expect(chats.chat(id)?.messages.first?.text == "Hello")
    }

    @Test func aNewAgentChatLocksTheModelToClaudeAndGivesItBack() {
        let composer = makeComposer()
        let codex = ChatModel(backend: .codex, id: "gpt-5.5")
        composer.model = codex
        composer.agentDirectory = testDirectory()
        composer.applyModelLock()
        #expect(composer.model.backend == .claude)
        #expect(composer.modelLock.switchedFrom == codex)
        composer.agentDirectory = nil
        composer.applyModelLock()
        #expect(composer.model == codex)
    }
}
