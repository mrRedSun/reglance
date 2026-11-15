import Foundation
import Testing
@testable import ChatCore

// MARK: - JSON-RPC framing and response matching

@Test func rpcIDAcceptsIntAndString() {
    #expect(CodexServer.rpcID(["id": 3]) == 3)
    #expect(CodexServer.rpcID(["id": "3"]) == 3)
    #expect(CodexServer.rpcID(["id": "abc"]) == nil)
    #expect(CodexServer.rpcID([:]) == nil)
}

/// Feeds recorded JSON-RPC lines through the reader's classification logic: responses
/// (id, no method) are matched to requests; notifications reach the turn loop.
@Test func responsesMatchAndNotificationsStream() throws {
    // The reader's classification: an id without a method is a response matched by id;
    // anything with a method is a notification for the turn loop.
    func classify(_ object: [String: Any]) -> Int? {
        object["method"] == nil ? CodexServer.rpcID(object) : nil
    }

    #expect(classify(try json(#"{"jsonrpc":"2.0","id":1,"result":{"userAgent":"codex 0.164"}}"#)) == 1)
    #expect(classify(try json(#"{"jsonrpc":"2.0","id":"3","result":{"thread":{"id":"t3"}}}"#)) == 3)
    #expect(classify(try json(#"{"jsonrpc":"2.0","id":2,"error":{"code":-32000,"message":"no thread"}}"#)) == 2)
    // Notifications and server requests (approvals) carry a method, so they reach the loop.
    #expect(classify(try json(#"{"jsonrpc":"2.0","method":"account/updated","params":{}}"#)) == nil)
    #expect(classify(try json(#"{"jsonrpc":"2.0","id":9,"method":"execCommandApproval","params":{}}"#)) == nil)
}

private func json(_ line: String) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
}

// MARK: - Notification-to-event mapping

private func consume(_ lines: [String], into parser: inout CodexStreamParser) -> [ChatEvent] {
    lines.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        .flatMap { parser.consume($0) }
}

let turnCompleted = #"{"jsonrpc":"2.0","method":"turn/completed","params":{"threadId":"th1","turn":{"id":"tu1","status":"completed","error":null}}}"#

@Test func mapsDeltasToTextAndFinish() {
    var parser = CodexStreamParser()
    let events = consume([
        #"{"jsonrpc":"2.0","method":"item/started","params":{"item":{"type":"agentMessage","id":"m1","text":""}}}"#,
        #"{"jsonrpc":"2.0","method":"item/agentMessage/delta","params":{"threadId":"th1","itemId":"m1","delta":"Bas"}}"#,
        #"{"jsonrpc":"2.0","method":"item/agentMessage/delta","params":{"threadId":"th1","itemId":"m1","delta":"enji"}}"#,
        turnCompleted,
    ], into: &parser)

    #expect(events.filter { if case .text = $0 { true } else { false } }.count >= 2)
    #expect(parser.text == "Basenji")
    #expect(parser.isFinished)
    #expect(parser.errorMessage == nil)
    #expect(events.last == .finished(sessionID: "th1", fullText: "Basenji"))
}

@Test func separatesTwoAgentMessagesWithABlankLine() {
    var parser = CodexStreamParser()
    let events = consume([
        #"{"jsonrpc":"2.0","method":"item/started","params":{"item":{"type":"agentMessage","id":"m1","text":""}}}"#,
        #"{"jsonrpc":"2.0","method":"item/agentMessage/delta","params":{"itemId":"m1","delta":"First part."}}"#,
        #"{"jsonrpc":"2.0","method":"item/started","params":{"item":{"type":"agentMessage","id":"m2","text":""}}}"#,
        #"{"jsonrpc":"2.0","method":"item/agentMessage/delta","params":{"itemId":"m2","delta":"Second part."}}"#,
        turnCompleted,
    ], into: &parser)

    #expect(parser.text == "First part.\n\nSecond part.")
    #expect(events.contains(.text("\n\n")))
}

@Test func mapsReasoningDeltasToThinking() {
    var parser = CodexStreamParser()
    let events = consume([
        #"{"jsonrpc":"2.0","method":"item/reasoning/summaryTextDelta","params":{"itemId":"r1","delta":"Thinking "}}"#,
        #"{"jsonrpc":"2.0","method":"item/reasoning/textDelta","params":{"itemId":"r1","delta":"hard"}}"#,
        #"{"jsonrpc":"2.0","method":"item/agentMessage/delta","params":{"itemId":"m1","delta":"Answer"}}"#,
        turnCompleted,
    ], into: &parser)

    #expect(events.contains(.thinking("Thinking ")))
    #expect(events.contains(.thinking("hard")))
    #expect(parser.text == "Answer")   // thinking doesn't leak into the reply text
}

@Test func mapsWebSearchToToolEvent() {
    var parser = CodexStreamParser()
    let events = consume([
        #"{"jsonrpc":"2.0","method":"item/started","params":{"item":{"type":"webSearch","id":"w1","query":"latest macOS release"}}}"#,
        turnCompleted,
    ], into: &parser)

    #expect(events.contains(.tool(name: "WebSearch", detail: "latest macOS release")))
}

@Test func reportsTurnFailure() {
    var parser = CodexStreamParser()
    consume([
        #"{"jsonrpc":"2.0","method":"turn/completed","params":{"threadId":"th1","turn":{"id":"tu1","status":"failed","error":{"message":"usage limit exceeded"}}}}"#,
    ], into: &parser)
    #expect(parser.isFinished)
    #expect(parser.errorMessage == "usage limit exceeded")
}

@Test func reportsInterruptedTurnAsStopped() {
    var parser = CodexStreamParser()
    consume([
        #"{"jsonrpc":"2.0","method":"turn/completed","params":{"threadId":"th1","turn":{"id":"tu1","status":"interrupted","error":null}}}"#,
    ], into: &parser)
    #expect(parser.errorMessage == "Stopped")
}

@Test func ignoresUnrelatedNotifications() {
    var parser = CodexStreamParser()
    let events = consume([
        #"{"jsonrpc":"2.0","method":"thread/tokenUsage/updated","params":{"tokenUsage":{"total":{"totalTokens":10}}}}"#,
        #"{"jsonrpc":"2.0","method":"item/started","params":{"item":{"type":"userMessage","id":"u1"}}}"#,
        #"{"jsonrpc":"2.0","method":"item/completed","params":{"item":{"type":"userMessage","id":"u1"}}}"#,
    ], into: &parser)
    #expect(events.isEmpty)
    #expect(!parser.isFinished)
}

// MARK: - Lockdown

@Test func serverRequestsAreTheMessagesWithAnIdAndAMethod() {
    #expect(CodexClient.isServerRequest(["id": 4, "method": "item/commandExecution/requestApproval"]))
    #expect(!CodexClient.isServerRequest(["method": "turn/completed"]))
    #expect(!CodexClient.isServerRequest(["id": 4, "result": [:]]))
}

@Test func anMCPServerStartingStopsTheTurn() throws {
    var parser = CodexStreamParser()
    consume([#"{"method":"mcpServer/startupStatus/updated","params":{"name":"pencil","status":"starting"}}"#], into: &parser)
    let violation = try #require(parser.violation)
    #expect(violation.contains("pencil"))
}

@Test func anyToolButWebSearchStopsTheTurn() {
    for type in ["commandExecution", "fileChange", "mcpToolCall", "dynamicToolCall", "collabAgentToolCall", "imageGeneration"] {
        var parser = CodexStreamParser()
        let events = consume([#"{"method":"item/started","params":{"item":{"type":"\#(type)","id":"x"}}}"#], into: &parser)
        #expect(events.isEmpty)
        #expect(parser.violation?.contains(type) == true, "\(type)")
    }
    var parser = CodexStreamParser()
    consume([#"{"method":"item/started","params":{"item":{"type":"webSearch","id":"w","query":"q"}}}"#], into: &parser)
    #expect(parser.violation == nil)
}

/// Recorded: a signed-in account over its usage limit.
@Test func aFinalErrorNotificationBecomesTheReplyError() {
    var parser = CodexStreamParser()
    let events = consume([
        #"{"method":"error","params":{"error":{"message":"You’ve hit your usage limit. Try again later.","codexErrorInfo":"usageLimitExceeded"},"willRetry":false,"threadId":"th1","turnId":"tu1"}}"#,
        #"{"method":"turn/completed","params":{"threadId":"th1","turn":{"id":"tu1","status":"failed","error":{"message":"You’ve hit your usage limit. Try again later."}}}}"#,
    ], into: &parser)
    #expect(events.isEmpty)
    #expect(parser.isFinished)
    #expect(parser.errorMessage == "You’ve hit your usage limit. Try again later.")
}

@Test func aRetriedErrorIsNotFinal() {
    var parser = CodexStreamParser()
    consume([#"{"method":"error","params":{"error":{"message":"Reconnecting"},"willRetry":true,"threadId":"t","turnId":"u"}}"#, turnCompleted],
            into: &parser)
    #expect(parser.errorMessage == nil)
}

@Test func lockdownDisablesEveryConfiguredMCPServerAndToolFeature() {
    let config = """
        model = "gpt-6-astra"
        [mcp_servers.pencil]
        command = "pencil"
        [mcp_servers.pencil.env]
        KEY = "x"
        [mcp_servers."my server"]
        url = "https://example.com"
          [ mcp_servers.node_repl ]
        command = "node"
        [features]
        """
    #expect(CodexLockdown.mcpServerNames(in: config) == ["pencil", "\"my server\"", "node_repl"])
    let args = CodexLockdown.arguments(config: config)
    #expect(args.first == "app-server")
    for name in ["pencil", "\"my server\"", "node_repl"] {
        #expect(args.contains("mcp_servers.\(name).enabled=false"))
    }
    for feature in ["shell_tool", "apps", "plugins", "browser_use", "in_app_browser", "computer_use"] {
        #expect(args.contains(feature) && args[args.firstIndex(of: feature)! - 1] == "--disable")
    }
    #expect(args.suffix(2) == ["-c", "tools.web_search=true"])
}

@Test func chatThreadsAreReadOnlyWithoutApprovals() {
    let params = CodexClient.threadParams(cwd: URL(filePath: "/tmp/w"), model: ChatModel(backend: .codex, id: "gpt-6-astra"),
                                          instructions: "Be brief.")
    #expect(params["sandbox"] as? String == "read-only")
    #expect(params["approvalPolicy"] as? String == "never")
    #expect(params["model"] as? String == "gpt-6-astra")
    #expect(params["baseInstructions"] as? String == "Be brief.")
    #expect(params["ephemeral"] as? Bool == false)
}

@Test func imagesAreSentAsTemporaryFiles() async throws {
    let png = Data([0x89, 0x50, 0x4E, 0x47])
    let content: [ContentBlock] = [.text("What is this?"), .image(mediaType: "image/png", data: png)]
    let images = try CodexClient.writeImages(content)
    defer { for url in images.values { try? FileManager.default.removeItem(at: url) } }
    let input = CodexClient.userInput(content, images: images)
    #expect(input.count == 2)
    #expect(input[0]["text"] as? String == "What is this?")
    let path = try #require(input[1]["path"] as? String)
    #expect(input[1]["type"] as? String == "localImage")
    #expect(path.hasSuffix(".png"))
    #expect(try Data(contentsOf: URL(filePath: path)) == png)
}

// MARK: - model/list mapping

@Test func mapsModelListToOptions() {
    let models = [
        [
            "id": "gpt-6-luna", "displayName": "GPT-6-Luna", "hidden": false,
            "description": "Fast and affordable model for easier tasks.",
            "supportedReasoningEfforts": [
                ["reasoningEffort": "low", "description": ""],
                ["reasoningEffort": "medium", "description": ""],
                ["reasoningEffort": "ultra", "description": ""],
            ],
        ] as [String: Any],
        [
            "id": "hidden-model", "displayName": "Hidden", "hidden": true,
            "supportedReasoningEfforts": [["reasoningEffort": "low", "description": ""]],
        ] as [String: Any],
        [
            "id": "gpt-6-astra", "displayName": "GPT-6-Astra", "hidden": false,
            "description": "Frontier intelligence for the most demanding work.",
            "supportedReasoningEfforts": [["reasoningEffort": "high", "description": ""]],
        ] as [String: Any],
    ]
    let options = CodexBackend.modelOptions(from: models)

    #expect(options.count == 2)
    #expect(options[0].model == ChatModel(backend: .codex, id: "gpt-6-luna"))
    #expect(options[0].name == "GPT-6-Luna")
    #expect(options[0].efforts == [.automatic, .low, .medium])   // ultra dropped
    #expect(options[0].detail == "Fast and affordable model")
    #expect(options[1].detail == "Frontier intelligence")
    #expect(options[1].efforts == [.automatic, .high])
}

@Test func emptyEffortsFallBackToAutomatic() {
    let options = CodexBackend.modelOptions(from: [["id": "x", "displayName": "X", "hidden": false]])
    #expect(options.first?.efforts == [.automatic])
}

// MARK: - Doctor with a fake runner

private func fakeRunner(_ answers: [String: ClaudeDoctor.CommandResult?]) -> ClaudeDoctor.Runner {
    { _, arguments in answers[arguments.joined(separator: " ")] ?? nil }
}

private let codex = URL(filePath: "/opt/homebrew/bin/codex")

@Test func codexDoctorWarnsWhenNotInstalled() async {
    let report = await CodexDoctor.run(executable: nil, runner: { _, _ in
        Issue.record("ran a command"); return nil
    })
    #expect(report.checks.map(\.status) == [.warning])
    #expect(report.checks[0].detail.contains("Install Codex"))
}

@Test func codexDoctorPassesWhenSignedIn() async {
    let report = await CodexDoctor.run(executable: codex, runner: fakeRunner([
        "--version": .init(status: 0, output: "codex-cli 0.164.0\n"),
        "login status": .init(status: 0, output: "Logged in using ChatGPT\n"),
    ]))
    #expect(report.checks.map(\.status) == [.ok, .ok, .ok])
    #expect(report.checks[0].detail == codex.path)
    #expect(report.checks[1].detail == "codex-cli 0.164.0")
    #expect(report.checks[2].detail == "ChatGPT")
}

@Test func codexDoctorFlagsSignedOut() async {
    let report = await CodexDoctor.run(executable: codex, runner: fakeRunner([
        "--version": .init(status: 0, output: "codex-cli 0.164.0"),
        "login status": .init(status: 1, output: "Not logged in. Run `codex login`."),
    ]))
    #expect(report.checks[2].status == .failed)
    #expect(report.checks[2].detail.contains("sign in"))
}
