import Foundation

/// Finds the `claude` binary. Apps launched from Finder don't inherit the shell PATH,
/// so check the usual install locations first, then ask a login shell.
public enum ClaudeLocator {
    public static func executableURL() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/claude",          // native installer
            "\(home)/.claude/local/claude",       // older local install
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.npm-global/bin/claude",
            "\(home)/.bun/bin/claude",
        ]
        if let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return URL(filePath: path)
        }
        return loginShellLookup()
    }

    private static func loginShellLookup() -> URL? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(filePath: shell)
        process.arguments = ["-l", "-c", "command -v claude"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let path = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline).last
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard process.terminationStatus == 0, path.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return URL(filePath: path)
    }
}
