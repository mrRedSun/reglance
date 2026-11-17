import Foundation

/// Helpers every backend uses to run its CLI as a child process.
enum Subprocess {
    /// Writing to a pipe whose reader exited (the CLI quit early or was cancelled) raises
    /// SIGPIPE, which would kill the app. Ignored, the write then just fails.
    static let ignoreBrokenPipe: Void = { signal(SIGPIPE, SIG_IGN) }()

    /// `inherited` with a PATH that also finds tools next to `executable` and in Homebrew,
    /// such as `node`: apps launched from Finder get a minimal PATH.
    static func environment(inherited: [String: String], executable: URL) -> [String: String] {
        var environment = inherited
        let extraPath = [executable.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin"]
        environment["PATH"] = (extraPath + [environment["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
        return environment
    }

    /// Pipe data as soon as it's written. (`FileHandle.bytes` buffers, which delays streaming.)
    static func chunks(of handle: FileHandle) -> AsyncStream<Data> {
        AsyncStream { continuation in
            handle.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    continuation.finish()
                } else {
                    continuation.yield(data)
                }
            }
        }
    }

    /// Newline-delimited output, one line at a time (without the newline) as it arrives.
    static func lines(of handle: FileHandle) -> AsyncStream<Data> {
        AsyncStream { continuation in
            let task = Task {
                var buffer = Data()
                for await chunk in chunks(of: handle) {
                    buffer.append(chunk)
                    while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                        continuation.yield(Data(buffer[..<newline]))
                        buffer.removeSubrange(...newline)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func readAll(_ handle: FileHandle) async -> String {
        var data = Data()
        do { for try await byte in handle.bytes { data.append(byte) } } catch {}
        return String(decoding: data, as: UTF8.self)
    }
}

/// `Process` isn't Sendable; this only exposes `terminate()`, which is safe from any thread.
final class ProcessHandle: @unchecked Sendable {
    private let process: Process
    init(_ process: Process) { self.process = process }
    func terminate() { if process.isRunning { process.terminate() } }
}

/// A JSON object from `JSONSerialization`, handed from the reader task to one consumer.
struct SendableJSON: @unchecked Sendable {
    let value: [String: Any]
    init(_ value: [String: Any]) { self.value = value }
}

/// Finds a CLI binary. Apps launched from Finder don't inherit the shell PATH, so check
/// the usual install locations first, then ask a login shell.
public enum CLILocator {
    public static func executableURL(named name: String, candidates: [String]) -> URL? {
        if let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return URL(filePath: path)
        }
        return loginShellLookup(name)
    }

    private static func loginShellLookup(_ name: String) -> URL? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(filePath: shell)
        process.arguments = ["-l", "-c", "command -v \(name)"]
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
