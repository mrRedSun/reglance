import Foundation

/// The `codex` CLI as a chat backend. Placeholder until it is implemented.
public enum CodexBackend {
    public static func executableURL() -> URL? { nil }

    public static func models() async -> [ModelOption] { [] }

    public static func doctor() async -> DoctorReport {
        DoctorReport(checks: [DoctorCheck(title: "Codex CLI", status: .failed, detail: "Not supported yet.")], fullReport: nil)
    }
}

public struct CodexClient: ChatStreamingClient {
    public init() {}

    public func send(_ content: [ContentBlock], model: ChatModel, effort: Effort, resume sessionID: String?,
                     agentDirectory: URL?, permissions: AgentPermissions) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: ChatError.failed("Codex isn't supported yet.")) }
    }
}
