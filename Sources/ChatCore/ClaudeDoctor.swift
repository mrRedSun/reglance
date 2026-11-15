import Foundation

/// One line of the provider doctor in Settings.
public struct DoctorCheck: Equatable, Identifiable, Sendable {
    public enum Status: Sendable { case ok, warning, failed }
    public let title: String
    public let status: Status
    public let detail: String
    public var id: String { title }
}

public struct DoctorReport: Equatable, Sendable {
    public let checks: [DoctorCheck]
    /// The output of `claude doctor`, or nil when it couldn't run.
    public let fullReport: String?
}

/// Checks that the Claude Code CLI Reglance depends on is installed and signed in,
/// using only read-only commands (`--version`, `auth status`, `doctor`). No message is
/// sent, so a check costs no usage.
public enum ClaudeDoctor {
    public struct CommandResult: Sendable {
        public let status: Int32
        public let output: String
        public init(status: Int32, output: String) {
            self.status = status
            self.output = output
        }
    }

    /// Runs `claude` with arguments; nil when it couldn't start or timed out.
    public typealias Runner = @Sendable (_ executable: URL, _ arguments: [String]) async -> CommandResult?

    public static func run(executable: URL?, runner: @escaping Runner = defaultRunner) async -> DoctorReport {
        guard let executable else {
            return DoctorReport(checks: [DoctorCheck(
                title: "Claude Code CLI", status: .failed,
                detail: "Not found. Install Claude Code, run `claude` once in Terminal to sign in, then check again."
            )], fullReport: nil)
        }
        async let version = runner(executable, ["--version"])
        async let auth = runner(executable, ["auth", "status", "--json"])
        async let doctor = runner(executable, ["doctor"])

        let checks = [
            DoctorCheck(title: "Claude Code CLI", status: .ok, detail: executable.path),
            versionCheck(await version),
            signInCheck(await auth),
        ]
        let report = await doctor.flatMap { $0.output.trimmingCharacters(in: .whitespacesAndNewlines) }
        return DoctorReport(checks: checks, fullReport: report?.isEmpty == false ? report : nil)
    }

    private static func versionCheck(_ result: CommandResult?) -> DoctorCheck {
        let line = result?.output.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        guard let result, result.status == 0, !line.isEmpty else {
            return DoctorCheck(title: "Version", status: .failed, detail: "`claude --version` didn't run. Reinstall Claude Code.")
        }
        return DoctorCheck(title: "Version", status: .ok, detail: line.trimmingCharacters(in: .whitespaces))
    }

    private static func signInCheck(_ result: CommandResult?) -> DoctorCheck {
        // Warnings may precede the JSON, and a signed-out CLI can exit non-zero.
        guard let output = result?.output,
              let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"), start < end,
              let status = try? JSONSerialization.jsonObject(with: Data(output[start...end].utf8)) as? [String: Any],
              let loggedIn = status["loggedIn"] as? Bool else {
            return DoctorCheck(title: "Sign-in", status: .warning,
                               detail: "Couldn't read the sign-in status. Update Claude Code to check it.")
        }
        guard loggedIn else {
            return DoctorCheck(title: "Sign-in", status: .failed,
                               detail: "Not signed in. Run `claude` in Terminal to sign in.")
        }
        let method: String? = switch status["authMethod"] as? String {
        case "oauth_token", "claude.ai": "Claude account"
        case "api_key": "API key"
        case let other?: other
        case nil: nil
        }
        let provider: String? = switch status["apiProvider"] as? String {
        case "firstParty", nil: nil
        case "bedrock": "Amazon Bedrock"
        case "vertex": "Google Vertex AI"
        case let other?: other
        }
        let detail = [method, provider].compactMap(\.self).joined(separator: ", ")
        return DoctorCheck(title: "Sign-in", status: .ok, detail: detail.isEmpty ? "Signed in" : detail)
    }

    /// Runs the CLI in Reglance's neutral working folder, with stderr merged into the
    /// output and a time limit so a stuck command can't hang Settings.
    public static let defaultRunner: Runner = { executable, arguments in
        await Task.detached {
            let directory = AppPaths.claudeWorkdir
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let process = ClaudeClient.process(executable: executable, arguments: arguments, workingDirectory: directory)
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            process.standardInput = FileHandle.nullDevice
            do { try process.run() } catch { return nil }
            let handle = ProcessHandle(process)
            DispatchQueue.global().asyncAfter(deadline: .now() + 30) { handle.terminate() }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationReason == .exit else { return nil }
            return CommandResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
        }.value
    }
}
