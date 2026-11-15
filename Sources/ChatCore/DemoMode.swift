import Foundation

/// Demo mode runs the app on made-up chats and canned replies, so it can be shown, recorded
/// or screenshotted without real conversations or Claude calls. Turn it on with
/// `REGLANCE_DEMO=1` (a fresh temporary folder per launch), `REGLANCE_DEMO=<folder>`, or the
/// `--demo` launch argument. `scripts/capture-readme.sh` uses it for the README images.
public enum DemoMode {
    /// The data folder for this process, or nil when demo mode is off.
    public static let directory: URL? = directory(environment: ProcessInfo.processInfo.environment,
                                                  arguments: ProcessInfo.processInfo.arguments)
    public static var isEnabled: Bool { directory != nil }

    static func directory(environment: [String: String], arguments: [String]) -> URL? {
        let value = environment["REGLANCE_DEMO"] ?? (arguments.contains("--demo") ? "1" : nil)
        guard let value, !value.isEmpty, value != "0" else { return nil }
        if value.hasPrefix("/") { return URL(filePath: value, directoryHint: .isDirectory) }
        return FileManager.default.temporaryDirectory
            .appending(path: "ReglanceDemo-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    /// Writes the demo chats into `store` unless it already has chats.
    public static func seed(_ store: ChatStore) throws {
        guard store.loadAll().isEmpty else { return }
        for chat in DemoContent.chats(now: Date()) { try store.save(chat) }
    }
}

/// Streams canned replies (`DemoContent.reply(to:)`) at roughly the pace of a real model.
public struct DemoClient: ClaudeStreamingClient {
    /// Delay between streamed words.
    let wordDelay: Duration

    public init(wordDelay: Duration = .milliseconds(28)) {
        self.wordDelay = wordDelay
    }

    public func send(_ content: [ContentBlock], model: ClaudeModel, effort: ClaudeEffort, resume sessionID: String?,
                     agentDirectory: URL?, permissions: AgentPermissions) -> AsyncThrowingStream<ClaudeEvent, Error> {
        let question = content.compactMap { block -> String? in
            if case .text(let text) = block { text } else { nil }
        }.joined(separator: "\n")
        let reply = DemoContent.reply(to: question)
        let delay = wordDelay
        return AsyncThrowingStream { continuation in
            let task = Task {
                let session = UUID().uuidString
                continuation.yield(.session(id: session))
                for tool in reply.tools {
                    try? await Task.sleep(for: delay * 12)
                    continuation.yield(.tool(name: tool.name, detail: tool.detail))
                }
                try? await Task.sleep(for: delay * (reply.tools.isEmpty ? 12 : 30))
                // Words with their trailing whitespace, so newlines arrive intact.
                var chunk = ""
                for character in reply.text {
                    chunk.append(character)
                    if character.isWhitespace, !chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        if Task.isCancelled { break }
                        continuation.yield(.text(chunk))
                        chunk = ""
                        try? await Task.sleep(for: delay)
                    }
                }
                guard !Task.isCancelled else { return continuation.finish() }
                if !chunk.isEmpty { continuation.yield(.text(chunk)) }
                continuation.yield(.finished(sessionID: session, fullText: reply.text))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func title(question: String, answer: String) async -> String? {
        DemoContent.reply(to: question).title
    }
}
