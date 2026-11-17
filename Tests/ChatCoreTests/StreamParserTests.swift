import Foundation
import Testing
@testable import ChatCore

@Test func parsesStreamedReply() {
    var parser = StreamParser()
    let lines = [
        #"{"type":"system","subtype":"init","session_id":"abc"}"#,
        #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Bas"}},"session_id":"abc"}"#,
        #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"enji"}},"session_id":"abc"}"#,
        #"{"type":"assistant","message":{"content":[{"type":"text","text":"Basenji"}]}}"#,
        #"{"type":"result","subtype":"success","is_error":false,"result":"Basenji","session_id":"abc"}"#,
    ]
    let events = lines.flatMap { parser.consume($0) }
    #expect(events == [.session(id: "abc"), .text("Bas"), .text("enji"), .finished(sessionID: "abc")])
    #expect(parser.isFinished)
    #expect(parser.errorMessage == nil)
}

@Test func usesResultWhenNoDeltas() {
    var parser = StreamParser()
    let events = parser.consume(#"{"type":"result","subtype":"success","is_error":false,"result":"Hi","session_id":"s"}"#)
    #expect(events == [.text("Hi"), .finished(sessionID: "s")])
}

@Test func reportsErrorResult() {
    var parser = StreamParser()
    #expect(parser.consume(#"{"type":"result","subtype":"success","is_error":true,"result":"Not logged in"}"#).isEmpty)
    #expect(parser.errorMessage == "Not logged in")
}

@Test func buildsResumeArguments() {
    let args = ClaudeClient.arguments(model: ClaudeModel.opus.rawValue, resume: "sid")
    #expect(args.suffix(3) == ["--resume", "sid", "--fork-session"])
    #expect(args.contains("claude-opus-5-5"))
}

@Test func newChatHasNoResume() {
    #expect(!ClaudeClient.arguments(model: ClaudeModel.haiku.rawValue, resume: nil).contains("--resume"))
}

@Test func parsesThinkingAndSkipsEmptyThinking() {
    var parser = StreamParser()
    #expect(parser.consume(#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":""}}}"#).isEmpty)
    #expect(parser.consume(#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"hmm"}}}"#) == [.thinking("hmm")])
}

@Test func parsesToolCallsAndSeparatesTextBlocks() {
    var parser = StreamParser()
    let lines = [
        #"{"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"text","text":""}}}"#,
        #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Checking."}}}"#,
        #"{"type":"assistant","message":{"content":[{"type":"text","text":"Checking."},{"type":"tool_use","name":"WebFetch","input":{"url":"https://example.com","prompt":"p"}}]}}"#,
        #"{"type":"assistant","message":{"content":[{"type":"server_tool_use","name":"web_search","input":{"query":"nutella sugar"}}]}}"#,
        #"{"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"text","text":""}}}"#,
        #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"56 g."}}}"#,
    ]
    let events = lines.flatMap { parser.consume($0) }
    #expect(events == [
        .text("Checking."),
        .tool(name: "WebFetch", detail: "https://example.com"),
        .tool(name: "WebSearch", detail: "nutella sugar"),
        .text("\n\n"), .text("56 g."),
    ])
    #expect(parser.text == "Checking.\n\n56 g.")
}

@Test func systemPromptFillsRegionAndDate() {
    let date = ISO8601DateFormatter().date(from: "2026-11-15T12:00:00Z")!
    let prompt = SystemPrompt.make(now: date, locale: Locale(identifier: "en_US@rg=dezzzz"))
    #expect(prompt.contains("Today is Sunday, November 15, 2026"))
    #expect(prompt.contains("The user is in Germany and uses metric units and\nEUR"))
    #expect(!prompt.contains("{{"))
}

@Test func enablesOnlyWebTools() {
    let args = ClaudeClient.arguments(model: ClaudeModel.haiku.rawValue, resume: nil)
    #expect(args[args.firstIndex(of: "--tools")! + 1] == "WebSearch,WebFetch")
    #expect(args.contains("--strict-mcp-config") && args.contains("--disable-slash-commands"))
}

private func makeChat(_ turns: [(question: String, answer: String, session: String?)]) -> Chat {
    var chat = Chat(firstMessage: turns[0].question, model: .haiku)
    for turn in turns {
        chat.messages.append(Message(role: .user, text: turn.question))
        var reply = Message(role: .assistant, text: turn.answer)
        reply.sessionID = turn.session
        chat.messages.append(reply)
    }
    chat.sessionID = turns.last?.session
    return chat
}

@Test func storeRoundTrip() throws {
    let store = ChatStore.temporary()
    defer { store.removeDirectory() }
    var chat = makeChat([("Which dogs can't bark?", "The Basenji.", "s1")])
    chat.messages[1].thinkingDuration = 1.5
    try store.save(chat)
    let loaded = store.loadAll()
    #expect(loaded.count == 1)
    // ISO 8601 drops sub-second precision, so compare everything but the dates.
    #expect(loaded[0].id == chat.id && loaded[0].title == chat.title && loaded[0].sessionID == "s1")
    #expect(loaded[0].messages.map(\.text) == chat.messages.map(\.text))
    #expect(loaded[0].messages[1].sessionID == "s1" && loaded[0].messages[1].thinkingDuration == 1.5)
}

@MainActor @Test func regenerateNeedsTheSessionBeforeTheLastTurn() throws {
    let store = ChatStore.temporary()
    defer { store.removeDirectory() }
    let firstTurn = makeChat([("q1", "a1", "s1")])
    let twoTurns = makeChat([("q1", "a1", "s1"), ("q2", "a2", "s2")])
    let legacy = makeChat([("q1", "a1", nil), ("q2", "a2", nil)]) // saved before per-reply session ids
    for chat in [firstTurn, twoTurns, legacy] { try store.save(chat) }

    let controller = ChatController(store: store, client: ScriptedClient([]))
    #expect(controller.canRegenerate(firstTurn.id))
    #expect(controller.canRegenerate(twoTurns.id))
    #expect(!controller.canRegenerate(legacy.id))
}
