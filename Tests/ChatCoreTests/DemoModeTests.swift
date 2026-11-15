import Foundation
import Testing
@testable import ChatCore

@Test func demoModeIsOffByDefault() {
    #expect(DemoMode.directory(environment: [:], arguments: ["Reglance"]) == nil)
    #expect(DemoMode.directory(environment: ["REGLANCE_DEMO": "0"], arguments: []) == nil)
    #expect(DemoMode.directory(environment: ["REGLANCE_DEMO": ""], arguments: []) == nil)
}

@Test func demoModeUsesAFreshTemporaryFolderOrTheGivenOne() throws {
    let temporary = try #require(DemoMode.directory(environment: ["REGLANCE_DEMO": "1"], arguments: []))
    #expect(temporary.path.hasPrefix(FileManager.default.temporaryDirectory.path))
    let fromArgument = try #require(DemoMode.directory(environment: [:], arguments: ["Reglance", "--demo"]))
    #expect(fromArgument != temporary)
    #expect(DemoMode.directory(environment: ["REGLANCE_DEMO": "/tmp/reglance-demo"], arguments: [])?.path == "/tmp/reglance-demo")
}

@Test func demoSeedWritesMadeUpChatsOnce() throws {
    let store = ChatStore(directory: FileManager.default.temporaryDirectory.appending(path: "reglance-demo-tests-\(UUID().uuidString)"))
    defer { try? FileManager.default.removeItem(at: store.directory) }
    try DemoMode.seed(store)
    let chats = store.loadAll()
    #expect(chats.count == DemoContent.chats(now: Date()).count)
    #expect(chats.first?.title == DemoContent.lisbon.title) // pinned first
    #expect(chats.contains { $0.isAgent })
    #expect(chats.contains { $0.isArchived })
    try DemoMode.seed(store)
    #expect(store.loadAll().count == chats.count)
}

@MainActor @Test func demoClientStreamsTheCannedReply() async throws {
    let controller = ChatController(
        store: ChatStore(directory: FileManager.default.temporaryDirectory.appending(path: "reglance-demo-tests-\(UUID().uuidString)")),
        client: DemoClient(wordDelay: .zero)
    )
    let id = controller.send(DemoContent.heroQuestion, model: .sonnet, to: nil)
    await controller.waitForReply(id)
    await controller.waitForTitle(id)
    let chat = try #require(controller.chat(id))
    let reply = try #require(chat.messages.last)
    #expect(reply.text == DemoContent.caffeine.text)
    #expect(reply.error == nil)
    #expect(reply.toolSteps?.map(\.name) == ["WebSearch"])
    #expect(chat.title == DemoContent.caffeine.title)
    #expect(DemoContent.reply(to: "Something unrelated").title == DemoContent.fallback.title)
}
