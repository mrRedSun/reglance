import Foundation
import Testing
@testable import ChatCore

@Test func ordinaryChatsNeverBypassPermissions() {
    let args = ClaudeClient.arguments(model: ClaudeModel.sonnet.rawValue, resume: "s1")
    #expect(!args.contains("--permission-mode") && !args.contains("--dangerously-skip-permissions"))
    #expect(!args.contains("--append-system-prompt"))
    #expect(args[args.firstIndex(of: "--tools")! + 1] == "WebSearch,WebFetch")
    #expect(args[args.firstIndex(of: "--setting-sources")! + 1] == "")
}

@Test func agentArgumentsKeepClaudeCodeAndBypassPermissions() {
    let args = ClaudeClient.arguments(model: ClaudeModel.opus.rawValue, effort: .high, resume: "s1", agent: .bypass)
    #expect(args[args.firstIndex(of: "--permission-mode")! + 1] == "bypassPermissions")
    // The normal Claude Code prompt, settings, tools and MCP servers stay in place.
    for flag in ["--system-prompt", "--tools", "--allowedTools", "--setting-sources", "--strict-mcp-config", "--disable-slash-commands"] {
        #expect(!args.contains(flag), "\(flag)")
    }
    let appended = args[args.firstIndex(of: "--append-system-prompt")! + 1]
    #expect(appended.contains("```chart") && appended.contains("```document"))
    #expect(args.contains("--input-format") && args.contains("--include-partial-messages"))
    #expect(args[args.firstIndex(of: "--resume")! + 1] == "s1" && args.contains("--fork-session"))
    #expect(args[args.firstIndex(of: "--effort")! + 1] == "high")
}

@Test func agentChatsRunInAutoModeByDefault() throws {
    let args = ClaudeClient.arguments(model: ClaudeModel.sonnet.rawValue, resume: nil, agent: .auto)
    #expect(args[args.firstIndex(of: "--permission-mode")! + 1] == "auto")
    #expect(Chat(firstMessage: "Hi", model: .sonnet, agentDirectory: URL(filePath: "/tmp")).agentPermissions == .auto)
}

@Test func agentChatsSavedBeforeAutoModeStayBypassed() throws {
    var chat = Chat(firstMessage: "Fix it", model: .sonnet, agentDirectory: URL(filePath: "/tmp"))
    var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(chat)) as! [String: Any]
    #expect(json["agentPermissions"] as? String == "auto")
    json["agentPermissions"] = nil
    chat = try JSONDecoder().decode(Chat.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(chat.agentPermissions == .bypass)
}

@Test func chatPromptStillHasTheWidgets() {
    let prompt = SystemPrompt.make()
    #expect(prompt.contains("# Widgets\nBesides markdown"))
    #expect(prompt.hasSuffix("For content the user will want to keep or save (notes, checklists, cheat sheets)."))
}

@Test func agentToolCallsShowTheirCommandOrPath() {
    var parser = StreamParser()
    let line = #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"swift test\necho done","description":"Run tests"}},{"type":"tool_use","name":"Edit","input":{"file_path":"/tmp/a.swift","old_string":"x"}},{"type":"tool_use","name":"TodoWrite","input":{"todos":[]}}]}}"#
    #expect(parser.consume(line) == [
        .tool(name: "Bash", detail: "swift test"),
        .tool(name: "Edit", detail: "/tmp/a.swift"),
        .tool(name: "TodoWrite", detail: ""),
    ])
}

private actor Requests {
    private(set) var directories: [URL?] = []
    private(set) var permissions: [AgentPermissions] = []
    func add(_ directory: URL?, _ permission: AgentPermissions) {
        directories.append(directory)
        permissions.append(permission)
    }
}

private struct RecordingClient: ChatStreamingClient {
    let requests: Requests

    func send(_ content: [ContentBlock], model: ChatModel, effort: Effort, resume sessionID: String?,
              agentDirectory: URL?, permissions: AgentPermissions) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await requests.add(agentDirectory, permissions)
                continuation.yield(.finished(sessionID: "s-\(UUID())", fullText: "ok"))
                continuation.finish()
            }
        }
    }
}

@MainActor @Test func aChatKeepsTheModeItWasCreatedWith() async throws {
    let store = ChatStore(directory: FileManager.default.temporaryDirectory.appending(path: "reglance-agent-tests-\(UUID())"))
    defer { try? FileManager.default.removeItem(at: store.directory) }
    let requests = Requests()
    let controller = ChatController(store: store, client: RecordingClient(requests: requests))
    let folder = URL(filePath: "/tmp/project", directoryHint: .isDirectory)

    let agent = controller.send("Fix the build", model: .sonnet, agentDirectory: folder, agentPermissions: .bypass, to: nil)
    await controller.waitForReply(agent)
    // Follow-ups and regenerations stay in the agent's folder without passing it again.
    controller.send("And run the tests", model: .sonnet, to: agent)
    await controller.waitForReply(agent)
    controller.regenerate(agent)
    await controller.waitForReply(agent)

    let chat = controller.send("What's the weather?", model: .sonnet, to: nil)
    await controller.waitForReply(chat)
    // Agent permissions are never inherited by an ordinary chat.
    controller.send("Delete my files", model: .sonnet, agentDirectory: folder, to: chat)
    await controller.waitForReply(chat)

    #expect(await requests.directories == [folder, folder, folder, nil, nil])
    // Follow-ups keep the permissions the agent chat was created with.
    #expect(await requests.permissions.prefix(3) == [.bypass, .bypass, .bypass])
    #expect(controller.chat(agent)?.agentDirectory == folder)
    #expect(controller.chat(chat)?.isAgent == false)

    let saved = Dictionary(uniqueKeysWithValues: store.loadAll().map { ($0.id, $0) })
    #expect(saved[agent]?.agentDirectory == folder && saved[agent]?.agentPermissions == .bypass)
    #expect(saved[chat]?.agentDirectory == nil)
}

@Test func preferencesReachBothPrompts() {
    let preferences = "  Answer in British English.\nKeep it brief.  "
    let chat = ClaudeClient.arguments(model: ClaudeModel.sonnet.rawValue, resume: nil, preferences: preferences)
    let chatPrompt = chat[chat.firstIndex(of: "--system-prompt")! + 1]
    #expect(chatPrompt.hasSuffix("<preferences>\nAnswer in British English.\nKeep it brief.\n</preferences>"))
    let agent = ClaudeClient.arguments(model: ClaudeModel.sonnet.rawValue, resume: nil, agent: .auto, preferences: preferences)
    #expect(agent[agent.firstIndex(of: "--append-system-prompt")! + 1].contains("# The user's preferences"))
    // No preferences, no section.
    #expect(SystemPrompt.make(preferences: " \n") == SystemPrompt.make())
    #expect(!SystemPrompt.make().contains("<preferences>"))
}
