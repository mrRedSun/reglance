import Foundation
import Testing
@testable import ChatCore

private let sid = "ses_e1e98f6e6ffeVsyrkk3vE2Th81"

/// Recorded v2 `/api/event` payloads, trimmed to the fields Reglance reads.
private func event(_ type: String, _ data: [String: Any] = [:], session: String = sid) -> [String: Any] {
    ["type": type, "data": data.merging(["sessionID": session]) { value, _ in value }]
}

private func consume(_ events: [[String: Any]], into parser: inout OpenCodeStreamParser) -> [ChatEvent] {
    events.flatMap { parser.consume($0) }
}

@Test func openCodeTextAndReasoningStreamUntilTheExecutionSucceeds() {
    var parser = OpenCodeStreamParser(sessionID: sid)
    let events = consume([
        event("session.execution.started"),
        event("session.reasoning.started", ["ordinal": 0]),
        event("session.reasoning.delta", ["delta": "The user wants "]),
        event("session.text.started", ["ordinal": 0]),
        event("session.text.delta", ["delta": "1 2 3 "]),
        event("session.text.delta", ["delta": "4 5"]),
        event("session.text.ended", ["text": "1 2 3 4 5"]),
        event("session.step.ended", ["finish": "stop"]),
        event("session.execution.succeeded"),
    ], into: &parser)
    #expect(events == [.thinking("The user wants "), .text("1 2 3 "), .text("4 5"), .finished(sessionID: sid, fullText: "1 2 3 4 5")])
    #expect(parser.isFinished && parser.errorMessage == nil && parser.violation == nil)
}

@Test func openCodeWebFetchShowsAsAToolAndTheNextTextStartsAParagraph() {
    var parser = OpenCodeStreamParser(sessionID: sid)
    let events = consume([
        event("session.text.started"),
        event("session.text.delta", ["delta": "Let me fetch that page."]),
        event("session.tool.input.started", ["id": "call_1", "name": "webfetch"]),
        event("session.tool.called", ["id": "call_1", "input": ["url": "https://example.com"], "executed": false]),
        event("session.tool.success", ["id": "call_1"]),
        event("session.text.started"),
        event("session.text.delta", ["delta": "The title is Example Domain."]),
        event("session.execution.succeeded"),
    ], into: &parser)
    #expect(events.contains(.tool(name: "WebFetch", detail: "https://example.com")))
    #expect(parser.text == "Let me fetch that page.\n\nThe title is Example Domain.")
    #expect(parser.violation == nil)
}

@Test func openCodeIgnoresOtherSessions() {
    var parser = OpenCodeStreamParser(sessionID: sid)
    let events = consume([
        event("session.text.delta", ["delta": "someone else's reply"], session: "ses_other"),
        event("session.execution.succeeded", session: "ses_other"),
        ["type": "server.connected", "data": [String: Any]()],
    ], into: &parser)
    #expect(events.isEmpty)
    #expect(!parser.isFinished)
}

@Test func openCodeAnyOtherToolOrAPermissionRequestStopsTheReply() {
    for name in ["bash", "read", "edit", "glob", "task", "pencil_batch_design"] {
        var parser = OpenCodeStreamParser(sessionID: sid)
        _ = parser.consume(event("session.tool.input.started", ["id": "c", "name": name]))
        #expect(parser.violation?.contains(name) == true, "\(name)")
    }
    var parser = OpenCodeStreamParser(sessionID: sid)
    _ = parser.consume(event("session.permission.asked", ["id": "p1"]))
    #expect(parser.violation != nil)
}

/// Recorded with a model id the provider doesn't have.
@Test func openCodeFailedAndInterruptedExecutionsBecomeErrors() {
    var failed = OpenCodeStreamParser(sessionID: sid)
    _ = failed.consume(event("session.execution.failed", ["error": [
        "type": "provider.no-route", "message": "Model unavailable: zai-coding-plan/no-such-model",
    ]]))
    #expect(failed.isFinished)
    #expect(failed.errorMessage == "Model unavailable: zai-coding-plan/no-such-model")

    var interrupted = OpenCodeStreamParser(sessionID: sid)
    _ = interrupted.consume(event("session.execution.interrupted", ["reason": "user"]))
    #expect(interrupted.isFinished)
    #expect(interrupted.errorMessage == "Stopped")
}

@Test func openCodeModelsComeFromTheAPIWithTheirVariantsAsEfforts() {
    let models: [[String: Any]] = [
        ["id": "gpt-5.5", "providerID": "openai", "name": "GPT-5.5", "enabled": true, "status": "active",
         "variants": [["id": "none"], ["id": "low"], ["id": "medium"], ["id": "high"], ["id": "xhigh"]]],
        ["id": "glm-5.3-flash", "providerID": "zai-coding-plan", "name": "GLM-5.3-Flash", "status": "active",
         "variants": [["id": "low"], ["id": "high"], ["id": "max"]]],
        ["id": "big-pickle", "providerID": "opencode", "name": "Big Pickle", "status": "active", "variants": [Any]()],
        ["id": "old", "providerID": "openai", "name": "Old", "status": "deprecated"],
        ["id": "off", "providerID": "openai", "name": "Off", "enabled": false],
    ]
    let options = OpenCodeBackend.modelOptions(from: models)
    #expect(options.map(\.model.id) == ["openai/gpt-5.5", "opencode/big-pickle", "zai-coding-plan/glm-5.3-flash"])
    #expect(options.allSatisfy { $0.model.backend == .opencode })
    #expect(options[0].name == "GPT-5.5" && options[0].detail == "OpenAI")
    #expect(options[0].efforts == [.automatic, .low, .medium, .high, .xhigh])
    #expect(options[1].efforts == [.automatic])
    #expect(options[2].detail == "Z.AI Coding Plan" && options[2].efforts == [.automatic, .low, .high, .max])
}

@Test func openCodePickerShowsOnlyEnabledModelsThatStillExist() {
    let available = OpenCodeBackend.modelOptions(from: [
        ["id": "a", "providerID": "p", "name": "A"], ["id": "b", "providerID": "p", "name": "B"],
    ])
    #expect(OpenCodeBackend.filter(available, enabled: ["p/b", "p/gone"]).map(\.model.id) == ["p/b"])
    #expect(OpenCodeBackend.filter(available, enabled: []).isEmpty)
}

@Test func openCodeModelReferenceSplitsProviderAndCarriesTheVariant() throws {
    let ref = try OpenCodeClient.modelRef(ChatModel(backend: .opencode, id: "zai-coding-plan/glm-5.3-flash"), effort: .high)
    #expect(ref["providerID"] as? String == "zai-coding-plan")
    #expect(ref["id"] as? String == "glm-5.3-flash")
    #expect(ref["variant"] as? String == "high")
    let automatic = try OpenCodeClient.modelRef(ChatModel(backend: .opencode, id: "openrouter/meta/llama"), effort: .automatic)
    #expect(automatic["id"] as? String == "meta/llama" && automatic["variant"] == nil)
    #expect(throws: ChatError.self) { try OpenCodeClient.modelRef(ChatModel(backend: .opencode, id: "noslash"), effort: .automatic) }
}

@Test func openCodeServerIsPrivateAndLockedToTheWeb() throws {
    let environment = OpenCodeServer.environment(
        inherited: ["PATH": "/usr/bin", "HOME": "/Users/x"], executable: URL(filePath: "/opt/homebrew/bin/opencode"),
        configHome: URL(filePath: "/tmp/Reglance/Config"), systemPrompt: "Be brief.", password: "secret")
    #expect(environment["XDG_CONFIG_HOME"] == "/tmp/Reglance/Config")
    #expect(environment["OPENCODE_SERVER_PASSWORD"] == "secret")
    #expect(environment["OPENCODE_DISABLE_CLAUDE_CODE"] == "1")
    #expect(environment["OPENCODE_DISABLE_PROJECT_CONFIG"] == "1")
    #expect(environment["PATH"]?.hasPrefix("/opt/homebrew/bin:") == true)

    let content = try #require(environment["OPENCODE_CONFIG_CONTENT"])
    let config = try #require(try JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any])
    #expect(config["default_agent"] as? String == "reglance")
    #expect((config["mcp"] as? [String: Any])?.isEmpty == true)
    #expect((config["plugins"] as? [Any])?.isEmpty == true)
    let agent = try #require((config["agents"] as? [String: Any])?["reglance"] as? [String: Any])
    #expect(agent["system"] as? String == "Be brief.")
    // Deny everything, then allow only the web. Later rules win.
    let rules = try #require(agent["permissions"] as? [[String: String]])
    #expect(rules.first == ["action": "*", "resource": "*", "effect": "deny"])
    #expect(rules.dropFirst().map { $0["action"] } == ["webfetch", "websearch"])
    #expect(rules.dropFirst().allSatisfy { $0["effect"] == "allow" })
}

@Test func openCodeServerURLComesFromItsFirstLogLine() {
    #expect(OpenCodeServer.listeningURL(in: "server listening on http://127.0.0.1:61061\n")?.absoluteString == "http://127.0.0.1:61061")
    #expect(OpenCodeServer.listeningURL(in: "starting…") == nil)
    #expect(OpenCodeServer.listeningURL(in: "listening on http://0.0.0.0:4096") == nil)
}

@Test func openCodeAttachmentsAreSentAsFileURIs() throws {
    let content: [ContentBlock] = [
        .text("What's in these?"),
        .image(mediaType: "image/png", data: Data([1, 2, 3])),
        .document(mediaType: "application/pdf", data: Data([4, 5]), title: "note.pdf"),
    ]
    let files = try OpenCodeClient.writeFiles(content)
    defer { for file in files { try? FileManager.default.removeItem(at: file.url) } }
    let body = OpenCodeClient.promptBody(content, files: files)
    #expect(body["text"] as? String == "What's in these?")
    let sent = try #require(body["files"] as? [[String: String]])
    #expect(sent.count == 2)
    #expect(sent.allSatisfy { $0["uri"]?.hasPrefix("file://") == true })
    #expect(sent[1]["name"] == "note.pdf")
    #expect(try Data(contentsOf: files[1].url) == Data([4, 5]))
}

@Test func openCodeGeneratedTitleTextIsFoundInEitherShape() {
    #expect(OpenCodeClient.generatedText(["data": "Dog breeds"]) == "Dog breeds")
    #expect(OpenCodeClient.generatedText(["data": ["text": "Dog breeds"]]) == "Dog breeds")
    #expect(OpenCodeClient.generatedText([:]) == nil)
}

@Test func openCodeDoctorReadsVersionAndProviderNames() async {
    #expect(OpenCodeDoctor.majorVersion("opencode v2.1.4") == 2)
    #expect(OpenCodeDoctor.majorVersion("1.18.34") == 1)
    let list = "\u{1B}[1mOpenAI\u{1B}[0m            OAuth                       stored\nZ.AI Coding Plan  API key                     stored\n"
    #expect(OpenCodeDoctor.providerNames(list) == ["OpenAI", "Z.AI Coding Plan"])

    let opencode = URL(filePath: "/opt/homebrew/bin/opencode")
    let current = await OpenCodeDoctor.run(executable: opencode) { _, arguments in
        arguments == ["--version"] ? .init(status: 0, output: "opencode v2.1.4\n") : .init(status: 0, output: list)
    }
    #expect(current.checks.map(\.status) == [.ok, .ok, .ok])
    #expect(current.checks[2].detail == "OpenAI, Z.AI Coding Plan")

    let old = await OpenCodeDoctor.run(executable: opencode) { _, arguments in
        arguments == ["--version"] ? .init(status: 0, output: "1.18.34\n") : .init(status: 0, output: "")
    }
    #expect(old.checks[1].status == .failed && old.checks[1].detail.contains("OpenCode 2"))
    #expect(old.checks[2].status == .failed)

    let missing = await OpenCodeDoctor.run(executable: nil)
    #expect(missing.checks.map(\.status) == [.warning])
}

/// The pid of the guard shell's `sleep` child, or nil before it starts.
private func childPID(of parent: pid_t) throws -> pid_t? {
    let pgrep = Process()
    pgrep.executableURL = URL(filePath: "/usr/bin/pgrep")
    pgrep.arguments = ["-P", String(parent), "sleep"]
    let out = Pipe()
    pgrep.standardOutput = out
    try pgrep.run()
    let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    pgrep.waitUntilExit()
    return text.split(whereSeparator: \.isNewline).first.flatMap { pid_t(String($0)) }
}

private func waitUntil(_ condition: () -> Bool) async throws -> Bool {
    for _ in 0..<100 where !condition() { try await Task.sleep(for: .milliseconds(50)) }
    return condition()
}

@Test func theServerStopsWhenReglanceGoesAway() async throws {
    // Reglance dying closes its end of the guard's pipe, exactly like closing it here.
    let guarded = try ParentGuard.launch(URL(filePath: "/bin/sleep"), arguments: ["60"], configure: { _ in })
    var server: pid_t?
    #expect(try await waitUntil { server = try? childPID(of: guarded.process.processIdentifier); return server != nil })
    let pid = try #require(server)
    #expect(kill(pid, 0) == 0)
    guarded.release()
    #expect(try await waitUntil { kill(pid, 0) != 0 })
    #expect(try await waitUntil { !guarded.process.isRunning })
}

@Test func theGuardExitsWhenTheServerDoes() async throws {
    let guarded = try ParentGuard.launch(URL(filePath: "/bin/sleep"), arguments: ["0.2"], configure: { _ in })
    defer { guarded.release() }
    // So `isRunning` tells whether the server is still up.
    #expect(try await waitUntil { !guarded.process.isRunning })
}
