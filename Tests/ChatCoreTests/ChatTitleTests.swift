import Foundation
import Testing
@testable import ChatCore

private func titling(_ title: String?) -> ScriptedClient {
    ScriptedClient(replying: "Basenjis yodel instead of barking.", session: "title-session") { _, _, _ in title }
}

@MainActor @Test func firstReplyReplacesTheFirstMessageTitle() async throws {
    let store = ChatStore.temporary()
    defer { store.removeDirectory() }
    let controller = ChatController(store: store, client: titling("Dogs that can't bark"))
    let id = controller.send("which dogs cannot bark", model: .sonnet, to: nil)
    await controller.waitForReply(id)
    await controller.waitForTitle(id)
    #expect(controller.chat(id)?.title == "Dogs that can't bark")
    #expect(store.loadAll().first?.title == "Dogs that can't bark", "The generated title is saved")

    // Follow-ups keep the title.
    let followUp = ChatController(store: store, client: titling("Something else"))
    followUp.send("and cats?", model: .sonnet, to: id)
    await followUp.waitForReply(id)
    await followUp.waitForTitle(id)
    #expect(followUp.chat(id)?.title == "Dogs that can't bark")
}

@MainActor @Test func renamedChatsKeepTheirName() async throws {
    let store = ChatStore.temporary()
    defer { store.removeDirectory() }
    let controller = ChatController(store: store, client: titling("Generated"))
    let id = controller.send("question", model: .sonnet, to: nil)
    controller.rename(id, to: "Mine")
    await controller.waitForReply(id)
    await controller.waitForTitle(id)
    #expect(controller.chat(id)?.title == "Mine")
}

@MainActor @Test func aFailedTitleKeepsTheFirstMessage() async throws {
    let store = ChatStore.temporary()
    defer { store.removeDirectory() }
    let controller = ChatController(store: store, client: titling(nil))
    let id = controller.send("which dogs cannot bark", model: .sonnet, to: nil)
    await controller.waitForReply(id)
    await controller.waitForTitle(id)
    #expect(controller.chat(id)?.title == "which dogs cannot bark")
}

@Test func titleRequestIsToolFreeHaikuWithoutASavedSession() {
    let args = ClaudeClient.titleArguments
    #expect(args.contains("--no-session-persistence"))
    #expect(args.firstIndex(of: "--model").map { args[$0 + 1] } == ClaudeModel.haiku.rawValue)
    #expect(args.firstIndex(of: "--tools").map { args[$0 + 1] } == "")
}

@Test func titleOutputIsCleanedToOneLine() {
    #expect(ChatTitle.clean("\"Dogs that can't bark.\"\n") == "Dogs that can't bark")
    #expect(ChatTitle.clean("  \n") == nil)
    #expect(ChatTitle.clean(String(repeating: "a", count: 80))?.count == 61)
}

@Test func legacyChatsDontGetRetitled() throws {
    let data = Data("""
        {"id":"\(UUID())","title":"Old chat","createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-02T00:00:00Z","model":"claude-sonnet-5-5","messages":[]}
        """.utf8)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    #expect(try decoder.decode(Chat.self, from: data).titleIsAutomatic == false)
}

@MainActor @Test func aFinishedTitleRequestIsForgottenHoweverItEnded() async throws {
    let store = ChatStore.temporary()
    defer { store.removeDirectory() }
    let controller = ChatController(store: store, client: titling(nil))
    let id = controller.send("which dogs cannot bark", model: .sonnet, to: nil)
    await controller.waitForReply(id)
    await controller.waitForTitle(id)
    for _ in 0..<10 { await Task.yield() }
    #expect(controller.pendingTitleCount == 0)
}
