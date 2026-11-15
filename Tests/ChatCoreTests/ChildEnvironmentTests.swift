import Foundation
import Testing
@testable import ChatCore

private let executable = URL(filePath: "/Users/someone/.local/bin/claude")

private func settingsFile(_ json: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "reglance-settings-\(UUID().uuidString).json")
    try Data(json.utf8).write(to: url)
    return url
}

/// Chats run with `--setting-sources ""`, which also skips the `env` block of the user's
/// settings. A gateway login set there (ANTHROPIC_BASE_URL plus ANTHROPIC_AUTH_TOKEN) was
/// lost, and the CLI fell back to an expired OAuth login.
@Test func childGetsTheEnvBlockOfTheUserSettings() throws {
    let url = try settingsFile("""
        {"hooks": {}, "env": {"ANTHROPIC_BASE_URL": "https://gateway.example", "ANTHROPIC_AUTH_TOKEN": "token"}}
        """)
    defer { try? FileManager.default.removeItem(at: url) }
    let environment = ClaudeClient.childEnvironment(
        inherited: ["HOME": "/Users/someone", "PATH": "/usr/bin:/bin"],
        settingsEnvironment: ClaudeClient.settingsEnvironment(at: url),
        executable: executable)
    #expect(environment["ANTHROPIC_BASE_URL"] == "https://gateway.example")
    #expect(environment["ANTHROPIC_AUTH_TOKEN"] == "token")
    #expect(environment["HOME"] == "/Users/someone")
    #expect(environment["PATH"] == "/Users/someone/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin")
}

@Test func missingOrBrokenSettingsAddNothing() throws {
    let broken = try settingsFile("{ not json")
    defer { try? FileManager.default.removeItem(at: broken) }
    #expect(ClaudeClient.settingsEnvironment(at: broken).isEmpty)
    #expect(ClaudeClient.settingsEnvironment(at: URL(filePath: "/nonexistent/settings.json")).isEmpty)
}

@Test func settingsLiveInClaudeConfigDirWhenItIsSet() {
    #expect(ClaudeClient.settingsURL(environment: ["CLAUDE_CONFIG_DIR": "/tmp/claude-config"]).path
        == "/tmp/claude-config/settings.json")
    #expect(ClaudeClient.settingsURL(environment: [:]).path
        == FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/settings.json").path)
}
