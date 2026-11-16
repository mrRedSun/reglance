import Foundation

/// The `opencode` CLI (version 2 or later) as a chat backend, through its v2 HTTP API
/// (see `OpenCodeClient`). The picker offers only the models the person turned on in
/// Settings (`enabledModelsKey`), out of everything their signed-in providers have.
public enum OpenCodeBackend {
    public static func executableURL() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return CLILocator.executableURL(named: "opencode", candidates: [
            "/opt/homebrew/bin/opencode",
            "/usr/local/bin/opencode",
            "\(home)/.opencode/bin/opencode",
            "\(home)/.local/bin/opencode",
            "\(home)/.bun/bin/opencode",
            "\(home)/.npm-global/bin/opencode",
        ])
    }

    /// UserDefaults key: the `provider/model` ids the picker offers.
    public static let enabledModelsKey = "openCodeEnabledModels"

    public static var enabledModels: [String] {
        get { UserDefaults.standard.stringArray(forKey: enabledModelsKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: enabledModelsKey) }
    }

    /// The picker's models: the enabled ones that are still available. Asks the server
    /// only when something is enabled, so nothing runs for people who don't use OpenCode.
    public static func models() async -> [ModelOption] {
        let enabled = enabledModels
        guard !enabled.isEmpty else { return [] }
        return filter(await availableModels(), enabled: enabled)
    }

    /// Every model the signed-in providers offer, for Settings. Empty when OpenCode isn't
    /// installed, is older than version 2, or the server can't start.
    public static func availableModels() async -> [ModelOption] {
        guard let executable = executableURL(),
              let connection = try? await OpenCodeServer.shared.connect(executable: executable),
              let response = try? await connection.send("GET", "/api/model"),
              let models = response["data"] as? [[String: Any]] else { return [] }
        return modelOptions(from: models)
    }

    /// Enabled models in the order the person sees them in Settings.
    static func filter(_ available: [ModelOption], enabled: [String]) -> [ModelOption] {
        let enabled = Set(enabled)
        return available.filter { enabled.contains($0.model.id) }
    }

    /// Maps `/api/model` to picker options. Pure, so tests cover it without a server.
    /// Disabled and deprecated models are skipped; variants become efforts where `Effort`
    /// has a matching level (OpenAI's `none` doesn't).
    static func modelOptions(from models: [[String: Any]]) -> [ModelOption] {
        models.compactMap { model in
            guard let provider = model["providerID"] as? String,
                  let id = model["id"] as? String ?? model["modelID"] as? String,
                  model["enabled"] as? Bool != false,
                  (model["status"] as? String).map({ $0 == "active" || $0 == "beta" }) ?? true else { return nil }
            let variants = (model["variants"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
            let efforts = variants.compactMap(Effort.init(rawValue:)).filter { $0 != .automatic }
            let name = (model["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id
            return ModelOption(model: ChatModel(backend: .opencode, id: "\(provider)/\(id)"),
                               name: name, detail: providerName(provider), symbol: "sparkles",
                               efforts: [.automatic] + efforts)
        }
        .sorted { ($0.detail, $0.name) < ($1.detail, $1.name) }
    }

    /// A readable provider name for the ids OpenCode ships with; others stay as they are.
    static func providerName(_ id: String) -> String {
        switch id {
        case "openai": "OpenAI"
        case "anthropic": "Anthropic"
        case "opencode": "OpenCode Zen"
        case "zai": "Z.AI"
        case "zai-coding-plan": "Z.AI Coding Plan"
        case "google": "Google"
        case "openrouter": "OpenRouter"
        default: id
        }
    }

    public static func doctor() async -> DoctorReport {
        await OpenCodeDoctor.run(executable: Task.detached { executableURL() }.value)
    }
}

/// Checks that the optional OpenCode CLI is installed, new enough, and has a provider
/// signed in, using only read-only commands (`--version`, `auth list`).
public enum OpenCodeDoctor {
    public typealias Runner = ClaudeDoctor.Runner

    public static func run(executable: URL?, runner: @escaping Runner = CodexDoctor.defaultRunner) async -> DoctorReport {
        guard let executable else {
            // A warning, not a failure: OpenCode chats are opt-in.
            return DoctorReport(checks: [DoctorCheck(
                title: "OpenCode CLI", status: .warning,
                detail: "Not found. Install OpenCode 2 (`brew install opencode`) to chat with its models."
            )], fullReport: nil)
        }
        async let version = runner(executable, ["--version"])
        async let auth = runner(executable, ["auth", "list", "--standalone"])
        return DoctorReport(checks: [
            DoctorCheck(title: "OpenCode CLI", status: .ok, detail: executable.path),
            versionCheck(await version),
            signInCheck(await auth),
        ], fullReport: nil)
    }

    /// The major version from output like "opencode v2.1.4" or "1.18.34".
    static func majorVersion(_ output: String) -> Int? {
        guard let match = output.firstMatch(of: /v?(\d+)\.\d+/) else { return nil }
        return Int(match.output.1)
    }

    private static func versionCheck(_ result: ClaudeDoctor.CommandResult?) -> DoctorCheck {
        let line = result?.output.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard let result, result.status == 0, let major = majorVersion(line) else {
            return DoctorCheck(title: "Version", status: .failed, detail: "`opencode --version` didn't run. Reinstall OpenCode.")
        }
        guard major >= 2 else {
            return DoctorCheck(title: "Version", status: .failed,
                               detail: "\(line): Reglance needs OpenCode 2 or later. Run `opencode upgrade`.")
        }
        return DoctorCheck(title: "Version", status: .ok, detail: line)
    }

    /// Provider names from `opencode auth list`: one per line, the name before a run of
    /// spaces ("Z.AI Coding Plan  API key  stored"). Never the credentials themselves.
    static func providerNames(_ output: String) -> [String] {
        output.replacing(/\u{1B}\[[0-9;]*m/, with: "")
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> String? in
                let line = line.trimmingCharacters(in: .whitespaces)
                guard line.localizedCaseInsensitiveContains("stored") || line.localizedCaseInsensitiveContains("connected"),
                      let gap = line.range(of: "  ") else { return nil }
                return String(line[..<gap.lowerBound])
            }
    }

    private static func signInCheck(_ result: ClaudeDoctor.CommandResult?) -> DoctorCheck {
        guard let result else {
            return DoctorCheck(title: "Sign-in", status: .warning, detail: "Couldn't read the signed-in providers.")
        }
        let names = providerNames(result.output)
        guard !names.isEmpty else {
            return DoctorCheck(title: "Sign-in", status: .failed,
                               detail: "No provider signed in. Run `opencode auth login` in Terminal.")
        }
        return DoctorCheck(title: "Sign-in", status: .ok, detail: names.joined(separator: ", "))
    }
}
