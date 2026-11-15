import AppKit
import ChatCore
import SwiftUI

/// Agent mode: a chat that runs the normal Claude Code environment in a chosen folder.
/// New agent chats run in Claude Code's auto mode (blue), or with permissions bypassed
/// (red) once that's turned on in Settings. Every composer starts with agent mode off;
/// the person turns it on with the composer's Agent button or ⌘⇧A, which starts a new
/// agent chat.
enum AgentMode {
    /// Turning agent mode on or off adds or removes the folder row, so the composer
    /// changes height on the same spring as the rest of the layout.
    static let toggleAnimation = Animation.spring(response: 0.40, dampingFraction: 0.82)

    static let bypassKey = "agentBypassPermissions"
    private static let directoryKey = "agentDirectory"
    /// Predates auto mode, when every agent chat bypassed permissions.
    private static let bypassAcknowledgedKey = "agentModeWarningAcknowledged"
    private static let autoAcknowledgedKey = "agentAutoModeAcknowledged"
    /// Demo mode keeps its choices out of the real preferences.
    static let defaults = DemoMode.isEnabled ? UserDefaults(suiteName: "app.reglance.demo")! : .standard

    /// How new agent chats approve actions: auto mode unless bypassing is on in Settings.
    static var permissions: AgentPermissions {
        defaults.bool(forKey: bypassKey) ? .bypass : .auto
    }

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

    /// Explains what agent mode allows before it's first turned on with these permissions.
    /// Returns whether the person agreed.
    static func confirmEnabling() -> Bool {
        switch permissions {
        case .auto:
            if defaults.bool(forKey: autoAcknowledgedKey) { return true }
            let alert = NSAlert()
            alert.messageText = "Turn On Agent Mode?"
            alert.informativeText = """
                In agent mode, Claude runs as Claude Code does in a folder you choose, with \
                your settings, CLAUDE.md, skills, hooks, plugins and MCP servers.

                It runs in auto mode: Claude Code checks each action and runs the ones it \
                judges safe without asking. Risky actions are blocked. It's a safeguard, \
                not a sandbox.

                Agent mode applies only to new chats started with it on. Ordinary chats stay \
                limited to web search.
                """
            alert.addButton(withTitle: "Turn On Agent Mode")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate()
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
            defaults.set(true, forKey: autoAcknowledgedKey)
            return true
        case .bypass:
            return defaults.bool(forKey: bypassAcknowledgedKey) || confirmBypassing()
        }
    }

    /// Asked before bypassing permissions is turned on in Settings, or before a bypassing
    /// agent chat is first started. Returns whether the person agreed.
    static func confirmBypassing() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Bypass Permissions in Agent Mode?"
        alert.informativeText = """
            New agent chats will skip every permission check: commands, file changes and \
            other actions on this Mac run without asking you first and without auto mode's \
            safety check. The red styling is a warning, not a sandbox.

            Agent chats you already have keep the permissions they were started with.
            """
        alert.addButton(withTitle: "Bypass Permissions")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        defaults.set(true, forKey: bypassAcknowledgedKey)
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

extension AgentPermissions {
    /// Blue for auto mode, red as a warning when permissions are bypassed.
    var color: Color {
        switch self {
        case .auto: .blue
        case .bypass: .red
        }
    }

    var label: String {
        switch self {
        case .auto: "Agent mode · Auto"
        case .bypass: "Agent mode · Permissions bypassed"
        }
    }

    var symbol: String {
        switch self {
        case .auto: "checkmark.shield"
        case .bypass: "exclamationmark.shield"
        }
    }

    /// What the agent banner says actions do in `folder`.
    func explanation(in folder: String) -> String {
        switch self {
        case .auto: "Claude runs actions it judges safe without asking, in \(folder). Risky ones are blocked."
        case .bypass: "Commands and file changes run without asking, in \(folder)."
        }
    }
}

/// Shown with every agent chat and agent composer: blue in auto mode, a red warning when
/// permissions are bypassed.
struct AgentModeBadge: View {
    let permissions: AgentPermissions
    var compact = false

    var body: some View {
        // Not a Label: sidebar lists tint label icons with the accent color, which put a
        // blue shield on the red capsule.
        HStack(spacing: compact ? 3 : 4) {
            Image(systemName: permissions.symbol + ".fill")
                .symbolRenderingMode(.monochrome)
            Text(compact ? "Agent" : permissions.label)
        }
            .font(.system(size: compact ? 10.5 : 11.5, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, compact ? 6 : 8)
            .padding(.vertical, compact ? 1.5 : 3)
            .background(permissions.color, in: .capsule)
            .fixedSize()
            .accessibilityLabel(permissions.label)
    }
}
