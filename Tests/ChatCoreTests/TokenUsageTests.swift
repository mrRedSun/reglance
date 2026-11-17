import Foundation
import Testing
@testable import ChatCore

private func usages(_ events: [ChatEvent]) -> [TokenUsage] {
    events.compactMap { if case .usage(let usage) = $0 { usage } else { nil } }
}

// Shapes from Claude Code 2.1, Codex 0.164 and OpenCode 2.1, trimmed to the fields read.

@Test func claudeUsageSumsTheTurnAndTakesContextFromTheLastCall() throws {
    var parser = StreamParser()
    let lines = [
        #"{"type":"stream_event","event":{"type":"message_start","message":{"usage":{"input_tokens":2,"cache_creation_input_tokens":3000,"cache_read_input_tokens":0,"output_tokens":3}}}}"#,
        #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hi"}}}"#,
        #"{"type":"stream_event","event":{"type":"message_delta","usage":{"input_tokens":2,"cache_creation_input_tokens":3000,"cache_read_input_tokens":0,"output_tokens":7}}}"#,
        #"{"type":"stream_event","event":{"type":"message_start","message":{"usage":{"input_tokens":5,"cache_creation_input_tokens":0,"cache_read_input_tokens":3000,"output_tokens":1}}}}"#,
        #"{"type":"stream_event","event":{"type":"message_delta","usage":{"input_tokens":5,"cache_creation_input_tokens":0,"cache_read_input_tokens":3000,"output_tokens":40}}}"#,
        #"{"type":"result","subtype":"success","is_error":false,"result":"Hi","session_id":"s","total_cost_usd":0.0125,"usage":{"input_tokens":7,"cache_creation_input_tokens":3000,"cache_read_input_tokens":3000,"output_tokens":47},"modelUsage":{"claude-haiku-5-5":{"inputTokens":40,"cacheReadInputTokens":0,"cacheCreationInputTokens":0,"contextWindow":200000},"claude-opus-5-5":{"inputTokens":7,"cacheReadInputTokens":3000,"cacheCreationInputTokens":3000,"contextWindow":1000000}}}"#,
    ]
    let events = lines.flatMap { parser.consume($0) }
    let usage = try #require(usages(events).last)
    #expect(usage == TokenUsage(input: 6007, cachedInput: 3000, output: 47, context: 3045, contextWindow: 1_000_000, cost: 0.0125))
    #expect(events.last == .finished(sessionID: "s"))
}

@Test func codexUsageAddsUpEachCallOfTheTurn() throws {
    var parser = CodexStreamParser()
    func update(_ input: Int, cached: Int, output: Int) -> [String: Any] {
        ["method": "thread/tokenUsage/updated", "params": ["threadId": "th1", "turnId": "tu1", "tokenUsage": [
            "last": ["inputTokens": input, "cachedInputTokens": cached, "outputTokens": output,
                     "reasoningOutputTokens": 0, "totalTokens": input + output],
            "total": ["inputTokens": 0, "cachedInputTokens": 0, "outputTokens": 0, "reasoningOutputTokens": 0, "totalTokens": 0],
            "modelContextWindow": 272_000,
        ] as [String: Any]] as [String: Any]]
    }
    let events = [update(1000, cached: 0, output: 50), update(1200, cached: 1000, output: 300)].flatMap { parser.consume($0) }
    let usage = try #require(usages(events).last)
    #expect(usage == TokenUsage(input: 2200, cachedInput: 1000, output: 350, context: 1500, contextWindow: 272_000))
}

@Test func openCodeUsageCountsCacheAndReasoningAndAddsUpCost() throws {
    var parser = OpenCodeStreamParser(sessionID: "ses_1")
    parser.contextWindow = 400_000
    func step(_ input: Int, read: Int, output: Int, reasoning: Int, cost: Double) -> [String: Any] {
        ["type": "session.step.ended", "data": ["sessionID": "ses_1", "cost": cost, "tokens": [
            "input": input, "output": output, "reasoning": reasoning, "cache": ["read": read, "write": 0],
        ] as [String: Any]] as [String: Any]]
    }
    let events = [step(900, read: 0, output: 20, reasoning: 10, cost: 0.01),
                  step(100, read: 900, output: 200, reasoning: 0, cost: 0.02)].flatMap { parser.consume($0) }
    let usage = try #require(usages(events).last)
    #expect(usage.input == 1900 && usage.cachedInput == 900 && usage.output == 230)
    #expect(usage.context == 1200 && usage.contextWindow == 400_000)
    #expect(abs((usage.cost ?? 0) - 0.03) < 1e-9)
}

@Test func usageDerivesSpeedAndContextLeft() {
    let usage = TokenUsage(input: 10, output: 200, context: 50_000, contextWindow: 200_000, duration: 4)
    #expect(usage.outputPerSecond == 50)
    #expect(usage.contextLeft == 0.75)
    #expect(TokenUsage(input: 1, output: 1).contextLeft == nil)
}

@MainActor @Test func theReplyKeepsItsUsageAcrossLaunches() async throws {
    let store = ChatStore.temporary()
    defer { store.removeDirectory() }
    let client = ScriptedClient([.text("Hi"), .usage(TokenUsage(input: 10, output: 2, context: 12, contextWindow: 100)),
                                 .finished(sessionID: "s")])
    let controller = ChatController(store: store, client: client)
    let id = controller.send("Hello", model: .haiku, to: nil)
    await controller.waitForReply(id)
    let saved = try #require(store.loadAll().first { $0.id == id }?.messages.last?.usage)
    #expect(saved.input == 10 && saved.output == 2 && saved.contextWindow == 100)
    #expect(saved.duration != nil)
}
