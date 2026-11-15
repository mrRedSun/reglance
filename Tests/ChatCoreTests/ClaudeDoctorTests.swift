import Foundation
import Testing
@testable import ChatCore

/// Answers each CLI command from a table, so the checks run without a real `claude`.
private func fakeRunner(_ answers: [String: ClaudeDoctor.CommandResult?]) -> ClaudeDoctor.Runner {
    { _, arguments in answers[arguments.joined(separator: " ")] ?? nil }
}

private let claude = URL(filePath: "/opt/homebrew/bin/claude")

@Test func doctorReportsMissingCLIAndRunsNothingElse() async {
    let report = await ClaudeDoctor.run(executable: nil, runner: { _, _ in Issue.record("ran a command"); return nil })
    #expect(report.checks.map(\.status) == [.failed])
    #expect(report.checks[0].detail.contains("Install Claude Code"))
    #expect(report.fullReport == nil)
}

@Test func doctorPassesWhenInstalledAndSignedIn() async {
    let report = await ClaudeDoctor.run(executable: claude, runner: fakeRunner([
        "--version": .init(status: 0, output: "2.1.325 (Claude Code)\n"),
        "auth status --json": .init(status: 0, output: #"{"loggedIn":true,"authMethod":"oauth_token","apiProvider":"firstParty"}"#),
        "doctor": .init(status: 0, output: "Claude Code doctor\n\nNo installation issues found.\n"),
    ]))
    #expect(report.checks.map(\.status) == [.ok, .ok, .ok])
    #expect(report.checks[0].detail == claude.path)
    #expect(report.checks[1].detail == "2.1.325 (Claude Code)")
    #expect(report.checks[2].detail == "Claude account")
    #expect(report.fullReport == "Claude Code doctor\n\nNo installation issues found.")
}

@Test func doctorFlagsSignedOutAndUnreadableStatus() async {
    let signedOut = await ClaudeDoctor.run(executable: claude, runner: fakeRunner([
        "--version": .init(status: 0, output: "2.1.325 (Claude Code)"),
        "auth status --json": .init(status: 1, output: #"{"loggedIn":false}"#),
    ]))
    #expect(signedOut.checks[2].status == .failed)
    #expect(signedOut.checks[2].detail.contains("sign in"))

    // An older CLI without `auth status`, and a version command that fails.
    let old = await ClaudeDoctor.run(executable: claude, runner: fakeRunner([
        "--version": .init(status: 1, output: "boom"),
        "auth status --json": .init(status: 1, output: "error: unknown command 'auth'"),
    ]))
    #expect(old.checks[1].status == .failed)
    #expect(old.checks[2].status == .warning)
    #expect(old.fullReport == nil)
}

@Test func doctorNamesThirdPartyProviders() async {
    let report = await ClaudeDoctor.run(executable: claude, runner: fakeRunner([
        "--version": .init(status: 0, output: "2.1.325 (Claude Code)"),
        "auth status --json": .init(status: 0, output: "warning: something\n" + #"{"loggedIn":true,"authMethod":"api_key","apiProvider":"bedrock"}"#),
    ]))
    #expect(report.checks[2].status == .ok)
    #expect(report.checks[2].detail == "API key, Amazon Bedrock")
}
