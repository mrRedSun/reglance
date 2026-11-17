import Foundation

/// The `codex` CLI as a chat backend, through `codex app-server` (see `CodexClient`).
public enum CodexBackend: BackendDescriptor {
    public static let displayName = "Codex"
    public static let workdirName = "CodexWorkdir"
    public static let notFoundMessage =
        "Couldn't find the codex CLI. Install Codex and run `codex` once in a terminal to sign in."

    public static func makeClient() -> any ChatStreamingClient { CodexClient() }

    public static func executableURL() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return CLILocator.executableURL(named: "codex", candidates: [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "\(home)/.npm-global/bin/codex",
            "\(home)/.bun/bin/codex",
            "\(home)/.local/bin/codex",
        ])
    }

    /// The picker's models, from the app-server's `model/list`. Only read-only commands;
    /// nothing is sent to a model. Nil when codex isn't installed or the call fails.
    public static func models() async -> [ModelOption]? {
        await Task.detached {
            guard let executable = executableURL(),
                  let server = try? CodexServer(executable: executable, workingDirectory: AppPaths.workdir(for: .codex))
            else { return nil }
            defer { server.terminate() }
            guard (try? await server.handshake()) != nil,
                  let result = try? await server.request("model/list", params: [:]),
                  let data = result["data"] as? [[String: Any]] else { return nil }
            return modelOptions(from: data)
        }.value
    }

    public static func doctor() async -> DoctorReport {
        await CodexDoctor.run(executable: Task.detached { executableURL() }.value)
    }

    /// Maps a `model/list` result to picker options. Pure, so tests cover it without a CLI.
    /// Hidden models are skipped; efforts the `Effort` enum lacks (e.g. `ultra`) are dropped;
    /// a model whose remaining efforts are empty falls back to automatic only.
    static func modelOptions(from models: [[String: Any]]) -> [ModelOption] {
        models.compactMap { model in
            guard let id = model["id"] as? String, model["hidden"] as? Bool != true else { return nil }
            let efforts = (model["supportedReasoningEfforts"] as? [[String: Any]] ?? [])
                .compactMap { $0["reasoningEffort"] as? String }
                .compactMap(Effort.init(rawValue:))
            let detail = shortDetail(model["description"] as? String)
            return ModelOption(model: ChatModel(backend: .codex, id: id),
                               name: (model["displayName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id,
                               detail: detail,
                               efforts: [.automatic] + efforts)
        }
    }

    /// The catalog description's first clause ("Latest workhorse model for coding and
    /// everyday work." becomes "Latest workhorse model"), or empty when even that is long.
    static func shortDetail(_ description: String?) -> String {
        var clause = description?.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        for separator in [" for ", ", ", " — ", " - ", ". "] {
            if let range = clause.range(of: separator) { clause = String(clause[..<range.lowerBound]) }
        }
        clause = clause.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ".")))
        return clause.count <= 36 ? clause : ""
    }
}

/// Checks that the optional Codex CLI is installed and signed in, using only read-only
/// commands (`--version`, `login status`).
public enum CodexDoctor {
    public typealias Runner = ClaudeDoctor.Runner

    public static func run(executable: URL?, runner: @escaping Runner = defaultRunner) async -> DoctorReport {
        guard let executable else {
            // A warning, not a failure: Codex chats are opt-in.
            return DoctorReport(checks: [DoctorCheck(
                title: "Codex CLI", status: .warning,
                detail: "Not found. Install Codex and run `codex` once in Terminal to sign in, or keep using Claude."
            )], fullReport: nil)
        }
        async let version = runner(executable, ["--version"])
        async let login = runner(executable, ["login", "status"])
        return DoctorReport(checks: [
            DoctorCheck(title: "Codex CLI", status: .ok, detail: executable.path),
            versionCheck(await version),
            signInCheck(await login),
        ], fullReport: nil)
    }

    /// Runs `codex` in its chat folder with a time limit, without Claude Code's settings
    /// variables (`ClaudeDoctor.defaultRunner` adds those).
    public static let defaultRunner: Runner = { executable, arguments in
        await Task.detached {
            let directory = AppPaths.workdir(for: .codex)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.currentDirectoryURL = directory
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
            return ClaudeDoctor.CommandResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
        }.value
    }

    private static func versionCheck(_ result: ClaudeDoctor.CommandResult?) -> DoctorCheck {
        let line = result?.output.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        guard let result, result.status == 0, !line.isEmpty else {
            return DoctorCheck(title: "Version", status: .failed, detail: "`codex --version` didn't run. Reinstall Codex.")
        }
        return DoctorCheck(title: "Version", status: .ok, detail: line.trimmingCharacters(in: .whitespaces))
    }

    private static func signInCheck(_ result: ClaudeDoctor.CommandResult?) -> DoctorCheck {
        guard let result else {
            return DoctorCheck(title: "Sign-in", status: .warning, detail: "Couldn't read the sign-in status.")
        }
        // `codex login status` prints "Logged in using ChatGPT" and exits 0 when signed in;
        // signed out it prints an instruction and exits non-zero.
        let signedIn = result.status == 0 && result.output.range(of: "logged in", options: .caseInsensitive) != nil
        guard signedIn else {
            return DoctorCheck(title: "Sign-in", status: .failed, detail: "Not signed in. Run `codex` in Terminal to sign in.")
        }
        let method = ["ChatGPT", "API key"].first { result.output.localizedCaseInsensitiveContains($0) }
        return DoctorCheck(title: "Sign-in", status: .ok, detail: method ?? "Signed in")
    }
}
