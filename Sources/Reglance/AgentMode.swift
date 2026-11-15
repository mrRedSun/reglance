import AppKit
import ChatCore
import SwiftUI

/// Agent mode: a chat that runs the normal Claude Code environment in a chosen folder with
/// permission prompts bypassed. Every composer starts with it off; the person turns it on
/// with the composer's Agent button or ⌘⇧A, which starts a new agent chat.
enum AgentMode {
    static let color = Color.red
    static let label = "Agent mode · Permissions bypassed"

    private static let directoryKey = "agentDirectory"
    private static let acknowledgedKey = "agentModeWarningAcknowledged"
    /// Demo mode keeps its choices out of the real preferences.
    private static let defaults = DemoMode.isEnabled ? UserDefaults(suiteName: "app.reglance.demo")! : .standard

    /// The folder new agent chats run in: the last one chosen, or the home folder.
    static var directory: URL {
        get {
            if let path = defaults.string(forKey: directoryKey),
               FileManager.default.fileExists(atPath: path) {
                return URL(filePath: path, directoryHint: .isDirectory)
            }
            return URL.homeDirectory
        }
        set { defaults.set(newValue.path, forKey: directoryKey) }
    }

    /// Explains what agent mode allows before it's turned on for the first time.
    /// Returns whether the person agreed.
    static func confirmEnabling() -> Bool {
        if defaults.bool(forKey: acknowledgedKey) { return true }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Turn On Agent Mode?"
        alert.informativeText = """
            In agent mode, Claude runs as Claude Code does in a folder you choose, with your \
            settings, CLAUDE.md, skills, hooks, plugins and MCP servers.

            Permission prompts are bypassed: commands, file changes and other actions on \
            this Mac run without asking you first. The red styling is a warning, not a sandbox.

            Agent mode applies only to new chats started with it on. Ordinary chats stay \
            limited to web search.
            """
        alert.addButton(withTitle: "Turn On Agent Mode")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        defaults.set(true, forKey: acknowledgedKey)
        return true
    }

    /// Asks for the folder new agent chats run in and remembers it.
    static func chooseDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = directory
        panel.message = "Choose the folder Claude works in. It can run commands and change files there and elsewhere."
        panel.prompt = "Choose"
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        directory = url
        return url
    }

    /// "~/Projects/app" for display.
    static func displayPath(_ url: URL) -> String {
        let home = URL.homeDirectory.path
        let path = url.path
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

/// The unmistakable warning shown with every agent chat and agent composer.
struct AgentModeBadge: View {
    var compact = false

    var body: some View {
        // Not a Label: sidebar lists tint label icons with the accent color, which put a
        // blue shield on the red capsule.
        HStack(spacing: compact ? 3 : 4) {
            Image(systemName: "exclamationmark.shield.fill")
                .symbolRenderingMode(.monochrome)
            Text(compact ? "Agent" : AgentMode.label)
        }
            .font(.system(size: compact ? 10.5 : 11.5, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, compact ? 6 : 8)
            .padding(.vertical, compact ? 1.5 : 3)
            .background(AgentMode.color, in: .capsule)
            .fixedSize()
            .accessibilityLabel(AgentMode.label)
    }
}
