import Foundation
import Testing
@testable import ChatCore

private let executable = URL(filePath: "/Users/someone/.local/bin/claude")

/// Reglance opened from inside a Claude Code session (an agent running `open`) inherits
/// that session's gateway token, which expires and made every reply fail to authenticate.
@Test func childDropsAParentClaudeCodeSessionsVariables() {
    let inherited = [
        "CLAUDECODE": "1",
        "CLAUDE_CODE_ENTRYPOINT": "sdk-ts",
        "CLAUDE_CODE_SESSION_ID": "parent",
        "ANTHROPIC_BASE_URL": "http://127.0.0.1:1234",
        "ANTHROPIC_AUTH_TOKEN": "parent-token",
        "HOME": "/Users/someone",
        "PATH": "/usr/bin:/bin",
    ]
    let environment = ClaudeClient.childEnvironment(inherited: inherited, executable: executable)
    #expect(environment.keys.sorted() == ["HOME", "PATH"])
    #expect(environment["PATH"] == "/Users/someone/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin")
}

@Test func childKeepsAnthropicSettingsOutsideAClaudeCodeSession() {
    let inherited = ["ANTHROPIC_API_KEY": "the person's key", "HOME": "/Users/someone"]
    let environment = ClaudeClient.childEnvironment(inherited: inherited, executable: executable)
    #expect(environment["ANTHROPIC_API_KEY"] == "the person's key")
}
