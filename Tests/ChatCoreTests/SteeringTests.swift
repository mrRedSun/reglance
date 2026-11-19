import Foundation
import Testing
@testable import ChatCore

/// Waits (briefly) for work started on other tasks, such as a steer reaching the client.
@MainActor private func eventually(_ condition: () -> Bool) async {
    for _ in 0..<200 where !condition() {
        try? await Task.sleep(for: .milliseconds(5))
    }
}

/// A client whose first turn the test drives; later turns answer at once.
private func client(acceptsSteering: Bool) -> (ScriptedClient, AsyncThrowingStream<ChatEvent, Error>.Continuation) {
    let (first, continuation) = AsyncThrowingStream<ChatEvent, Error>.makeStream()
    let calls = Counter()
    let client = ScriptedClient(acceptsSteering: acceptsSteering) { request in
        calls.next() == 0 ? first : ScriptedClient.stream(ScriptedClient.reply("Answer to \(request.text)", session: "s2"))
    }
    return (client, continuation)
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { defer { value += 1 }; return value } }
}

@MainActor @Test func aMessageSentWhileReplyingSteersTheTurnAndStartsANewReply() async throws {
    let store = ChatStore.temporary()
    defer { store.removeDirectory() }
    let (client, turn) = client(acceptsSteering: true)
    let controller = ChatController(store: store, client: client)
    let id = controller.send("Count to ten", model: .opus, effort: .high, to: nil)
    turn.yield(.session(id: "s1"))
    turn.yield(.text("1 2 3"))
    await eventually { controller.chat(id)?.messages.last?.text == "1 2 3" }
    let firstReply = try #require(controller.streamingReply(in: id))

    controller.send("Stop and say done", model: .haiku, effort: .low, to: id)
    // Shown at once, below the reply that is still streaming.
    #expect(controller.chat(id)?.messages.map(\.role) == [.user, .assistant, .user])
    #expect(controller.streamingReply(in: id) == firstReply)
    await eventually { client.steers == ["Stop and say done"] }
    #expect(client.steers == ["Stop and say done"])
    #expect(client.requests.count == 1)

    turn.yield(.text(" 4"))
    turn.yield(.steered)
    turn.yield(.text("Done"))
    turn.yield(.finished(sessionID: "s1"))
    turn.finish()
    await controller.waitForReply(id)

    let chat = try #require(controller.chat(id))
    #expect(chat.messages.map(\.text) == ["Count to ten", "1 2 3 4", "Stop and say done", "Done"])
    #expect(chat.messages.allSatisfy { $0.error == nil })
    // A steer keeps the turn's model, and the reply before it can't be returned to.
    #expect(chat.model == .opus && chat.effort == .high)
    #expect(chat.messages[1].sessionID == nil)
    #expect(chat.messages[3].sessionID == "s1")
    #expect(!controller.isStreaming(id))
    #expect(!controller.canRegenerate(id))
}

@MainActor @Test func aSteerTheTurnNeverTookIsSentAsTheNextTurn() async throws {
    let store = ChatStore.temporary()
    defer { store.removeDirectory() }
    let (client, turn) = client(acceptsSteering: false)
    let controller = ChatController(store: store, client: client)
    let id = controller.send("First", model: .sonnet, to: nil)
    turn.yield(.session(id: "s1"))
    controller.send("Second", model: .sonnet, to: id)
    controller.send("Third", model: .sonnet, to: id)
    turn.yield(.text("One"))
    turn.yield(.finished(sessionID: "s1"))
    turn.finish()

    await eventually { controller.chat(id)?.messages.count == 5 && !controller.isStreaming(id) }
    let chat = try #require(controller.chat(id))
    #expect(chat.messages.map(\.text) == ["First", "One", "Second", "Third", "Answer to Second\nThird"])
    #expect(client.requests.count == 2)
    #expect(client.requests.last?.resume == "s1")
    #expect(client.steers.isEmpty)
}

@MainActor @Test func stoppingAReplySendsItsWaitingSteerRightAway() async throws {
    let store = ChatStore.temporary()
    defer { store.removeDirectory() }
    let (client, turn) = client(acceptsSteering: true)
    let controller = ChatController(store: store, client: client)
    let id = controller.send("Write a long essay", model: .sonnet, to: nil)
    turn.yield(.session(id: "s1"))
    controller.send("Make it short", model: .sonnet, to: id)
    await eventually { client.steers.count == 1 }

    controller.cancel(id)
    await eventually { controller.chat(id)?.messages.last?.text == "Answer to Make it short" && !controller.isStreaming(id) }
    let chat = try #require(controller.chat(id))
    #expect(chat.messages.map(\.text) == ["Write a long essay", "", "Make it short", "Answer to Make it short"])
    #expect(chat.messages[1].error == "Stopped")
    turn.finish()
}

@MainActor @Test func aSteeredFirstTurnStillGetsATitle() async throws {
    let store = ChatStore.temporary()
    defer { store.removeDirectory() }
    let (first, turn) = AsyncThrowingStream<ChatEvent, Error>.makeStream()
    let client = ScriptedClient(title: { question, _, _ in "Title for \(question)" }, acceptsSteering: true) { _ in first }
    let controller = ChatController(store: store, client: client)
    let id = controller.send("Which dogs can't bark?", model: .sonnet, to: nil)
    controller.send("Only African ones", model: .sonnet, to: id)
    await eventually { client.steers.count == 1 }
    turn.yield(.text("Basenji"))
    turn.yield(.steered)
    turn.yield(.text("Still the Basenji"))
    turn.yield(.finished(sessionID: "s"))
    turn.finish()
    await controller.waitForReply(id)
    await controller.waitForTitle(id)
    #expect(controller.chat(id)?.title == "Title for Which dogs can't bark?")
}

@Test func steeringWaitsForTheTurnToOpenAndRefusesOnceItEnds() async {
    let steering = Steering()
    let early = Task { await steering.steer([.text("early")]) }
    try? await Task.sleep(for: .milliseconds(30))
    steering.open { _ in true }
    #expect(await early.value)

    // Taken messages let the turn close; a queued one keeps it open.
    #expect(await steering.close() == false)
    steering.noteTaken([.steered])
    #expect(await steering.close() == true)
    #expect(await steering.steer([.text("late")]) == false)

    let ended = Steering()
    ended.end()
    #expect(await ended.steer([.text("too late")]) == false)
}

@Test func claudeTreatsLaterReplayedMessagesAsSteers() {
    var parser = StreamParser()
    let lines = [
        #"{"type":"system","subtype":"init","session_id":"abc"}"#,
        #"{"type":"user","isReplay":true,"message":{"role":"user","content":[{"type":"text","text":"Weather?"}]}}"#,
        #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Sunny"}}}"#,
        #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"…"}]}}"#,
        #"{"type":"user","isReplay":true,"message":{"role":"user","content":[{"type":"text","text":"And Lyon?"}]}}"#,
        #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Rain"}}}"#,
        #"{"type":"result","subtype":"success","is_error":false,"result":"Rain","session_id":"abc"}"#,
    ]
    let events = lines.flatMap { parser.consume($0) }
    #expect(events == [.session(id: "abc"), .text("Sunny"), .steered, .text("Rain"), .finished(sessionID: "abc")])
    #expect(ClaudeClient.arguments(model: "m", resume: nil).contains("--replay-user-messages"))
}

@Test func codexSteersOnItsOwnClientMessageID() {
    var parser = CodexStreamParser()
    let started = { (clientID: Any) -> [String: Any] in
        ["method": "item/started", "params": ["item": ["type": "userMessage", "id": "u", "clientId": clientID]]]
    }
    #expect(parser.consume(started(NSNull())).isEmpty)
    _ = parser.consume(["method": "item/agentMessage/delta", "params": ["delta": "One"]])
    #expect(parser.consume(started(CodexStreamParser.steerIDPrefix + "1")) == [.steered])
    #expect(parser.text.isEmpty)
}

@Test func openCodeSteersWhenItTakesALaterPromptFromTheInbox() {
    var parser = OpenCodeStreamParser(sessionID: "ses")
    let delivered: [String: Any] = ["type": "session.inbox.delivered", "data": ["sessionID": "ses", "inboxID": "m"]]
    #expect(parser.consume(delivered).isEmpty)
    _ = parser.consume(["type": "session.text.delta", "data": ["sessionID": "ses", "delta": "One"]])
    _ = parser.consume(["type": "session.execution.succeeded", "data": ["sessionID": "ses"]])
    #expect(parser.isFinished)
    #expect(parser.consume(delivered) == [.steered])
    #expect(!parser.isFinished && parser.text.isEmpty)
}
