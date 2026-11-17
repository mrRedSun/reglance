import Foundation
import Testing
@testable import ChatCore

@Test func legacyChatMetadataDefaults() throws {
    let id = UUID()
    let data = Data("""
        {"id":"\(id)","title":"Old chat","createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-02T00:00:00Z","model":"claude-sonnet-5-5","messages":[]}
        """.utf8)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let chat = try decoder.decode(Chat.self, from: data)
    #expect(chat.id == id)
    #expect(chat.effort == .automatic)
    #expect(!chat.isPinned)
    #expect(!chat.isArchived)
}

@Test func chatMetadataRoundTrip() throws {
    let store = ChatStore.temporary()
    defer { store.removeDirectory() }
    var chat = Chat(firstMessage: "Metadata", model: .opus, effort: .xhigh)
    chat.isPinned = true
    chat.isArchived = true
    try store.save(chat)
    let loaded = try #require(store.loadAll().first)
    #expect(loaded.effort == .xhigh)
    #expect(loaded.isPinned && loaded.isArchived)
}

@Test func effortArgumentsPreserveEveryModel() {
    for model in ClaudeModel.allCases.map(\.rawValue) {
        for effort in Effort.allCases {
            let args = ClaudeClient.arguments(model: model, effort: effort, resume: "session")
            #expect(args[args.firstIndex(of: "--model")! + 1] == model)
            #expect(!args.contains("--fallback-model"))
            if effort == .automatic {
                #expect(!args.contains("--effort"))
            } else {
                #expect(args[args.firstIndex(of: "--effort")! + 1] == effort.rawValue)
            }
            #expect(args.suffix(3) == ["--resume", "session", "--fork-session"])
        }
    }
    #expect(!ClaudeClient.arguments(model: ClaudeModel.sonnet.rawValue, resume: nil).contains("--effort"))
}

@MainActor @Test func libraryOperationsPersistAndSort() throws {
    let store = ChatStore.temporary()
    defer { store.removeDirectory() }
    var older = Chat(firstMessage: "Older", model: .sonnet)
    older.updatedAt = Date(timeIntervalSince1970: 100)
    var newer = Chat(firstMessage: "Newer", model: .haiku)
    newer.updatedAt = Date(timeIntervalSince1970: 200)
    try store.save(older)
    try store.save(newer)
    let controller = ChatController(store: store)
    #expect(controller.activeChats.map(\.id) == [newer.id, older.id])

    controller.setPinned(true, for: older.id)
    #expect(controller.activeChats.map(\.id) == [older.id, newer.id])
    // Library actions should not pretend a new conversation turn happened.
    #expect(controller.chat(older.id)?.updatedAt == older.updatedAt)
    controller.rename(older.id, to: "  Renamed chat\n")
    #expect(controller.chat(older.id)?.title == "Renamed chat")
    controller.rename(older.id, to: " \n ")
    #expect(controller.chat(older.id)?.title == "Renamed chat")
    controller.setArchived(true, for: older.id)
    #expect(controller.activeChats.map(\.id) == [newer.id])
    #expect(controller.archivedChats.map(\.id) == [older.id])

    let reloaded = ChatController(store: store)
    #expect(reloaded.chat(older.id)?.isPinned == true)
    #expect(reloaded.chat(older.id)?.isArchived == true)
    #expect(reloaded.chat(older.id)?.title == "Renamed chat")
    reloaded.setArchived(false, for: older.id)
    reloaded.setPinned(false, for: older.id)
    #expect(reloaded.activeChats.map(\.id) == [newer.id, older.id])
}

@Test func deletionRemovesOnlySelectedChatFiles() throws {
    let store = ChatStore.temporary()
    defer { store.removeDirectory() }
    let selected = Chat(firstMessage: "Delete", model: .sonnet)
    let other = Chat(firstMessage: "Keep", model: .opus)
    let draft = AttachmentDraft(kind: .text, name: "notes.txt", mediaType: "text/plain", data: Data("notes".utf8))
    for chat in [selected, other] {
        try store.save(chat)
        _ = try store.saveAttachment(draft, chatID: chat.id)
    }
    let session = store.directory.appending(path: "cli-session.jsonl")
    try Data("CLI owned".utf8).write(to: session)
    try store.delete(selected.id)
    try store.delete(selected.id) // Idempotent when files have already gone.
    #expect(!FileManager.default.fileExists(atPath: store.fileURL(for: selected.id).path))
    #expect(!FileManager.default.fileExists(atPath: store.directory.appending(path: selected.id.uuidString).path))
    #expect(FileManager.default.fileExists(atPath: store.fileURL(for: other.id).path))
    #expect(FileManager.default.fileExists(atPath: store.directory.appending(path: other.id.uuidString).path))
    #expect(try Data(contentsOf: session) == Data("CLI owned".utf8))
}

@MainActor @Test func deletingStreamingChatCannotResaveIt() async throws {
    let store = ChatStore.temporary()
    defer { store.removeDirectory() }
    let (stream, continuation) = AsyncThrowingStream<ChatEvent, Error>.makeStream()
    let controller = ChatController(store: store, client: ScriptedClient(stream: stream))
    let other = Chat(firstMessage: "Keep", model: .haiku)
    try store.save(other)
    let id = controller.send("Delete during reply", model: .opus, effort: .max, to: nil)
    #expect(controller.isStreaming(id))
    try controller.delete(id)
    continuation.yield(.session(id: "late-session"))
    continuation.yield(.text("Late text"))
    continuation.finish()
    // Let the cancelled task run its completion callback.
    for _ in 0..<10 { await Task.yield() }
    #expect(controller.chat(id) == nil)
    #expect(!controller.isStreaming(id))
    #expect(!FileManager.default.fileExists(atPath: store.fileURL(for: id).path))
    #expect(FileManager.default.fileExists(atPath: store.fileURL(for: other.id).path))
}

@MainActor @Test func sendAndRegenerateHonorSavedChoices() async throws {
    let store = ChatStore.temporary()
    defer { store.removeDirectory() }
    let client = ScriptedClient([.finished(sessionID: "recorded-session")])
    let controller = ChatController(store: store, client: client)
    let id = controller.send("Question", model: .haiku, effort: .max, to: nil)
    await controller.waitForReply(id)
    #expect(controller.chat(id)?.model == .haiku)
    #expect(controller.chat(id)?.effort == .max)
    controller.regenerate(id)
    await controller.waitForReply(id)
    let recorded = client.requests
    #expect(recorded.count == 2)
    #expect(recorded.allSatisfy { $0.model == .haiku && $0.effort == .max && $0.resume == nil })
    let saved = try #require(store.loadAll().first)
    #expect(saved.model == .haiku && saved.effort == .max)

    controller.regenerate(id, model: .opus, effort: .xhigh)
    await controller.waitForReply(id)
    let overridden = try #require(client.requests.last)
    #expect(overridden.model == .opus && overridden.effort == .xhigh)
    #expect(controller.chat(id)?.model == .opus && controller.chat(id)?.effort == .xhigh)

    controller.send("Follow-up", model: .sonnet, effort: .low, to: id)
    await controller.waitForReply(id)
    let continued = try #require(client.requests.last)
    #expect(continued.model == .sonnet && continued.effort == .low)
    #expect(continued.resume == "recorded-session")
}

@MainActor @Test func finishingReplyReordersWithinPinnedGroup() async throws {
    let store = ChatStore.temporary()
    defer { store.removeDirectory() }
    var pinned = Chat(firstMessage: "Pinned", model: .opus)
    pinned.isPinned = true
    var older = Chat(firstMessage: "Older", model: .sonnet)
    older.updatedAt = Date(timeIntervalSince1970: 100)
    var newer = Chat(firstMessage: "Newer", model: .haiku)
    newer.updatedAt = Date(timeIntervalSince1970: 200)
    for chat in [pinned, older, newer] { try store.save(chat) }
    let client = ScriptedClient([.finished(sessionID: "recorded-session")])
    let controller = ChatController(store: store, client: client)
    controller.send("Continue", model: .sonnet, effort: .low, to: older.id)
    await controller.waitForReply(older.id)
    #expect(controller.activeChats.map(\.id) == [pinned.id, older.id, newer.id])
    #expect(store.loadAll().map(\.id) == [pinned.id, older.id, newer.id])
}

@MainActor @Test func metadataEditsDuringStreamingSurviveCompletion() async throws {
    let store = ChatStore.temporary()
    defer { store.removeDirectory() }
    let (stream, continuation) = AsyncThrowingStream<ChatEvent, Error>.makeStream()
    let controller = ChatController(store: store, client: ScriptedClient(stream: stream))
    let id = controller.send("Original title", model: .opus, effort: .high, to: nil)
    controller.rename(id, to: "Renamed while streaming")
    controller.setPinned(true, for: id)
    controller.setArchived(true, for: id)
    continuation.yield(.text("Completed reply"))
    continuation.finish()
    await controller.waitForReply(id)
    let chat = try #require(store.loadAll().first)
    #expect(chat.title == "Renamed while streaming")
    #expect(chat.isPinned && chat.isArchived && chat.effort == .high)
    #expect(chat.messages.last?.text == "Completed reply")
    #expect(controller.activeChats.isEmpty)
    #expect(controller.archivedChats.map(\.id) == [id])
}
