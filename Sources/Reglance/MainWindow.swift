import AppKit
import ChatCore
import SwiftUI

@Observable
final class MainWindowModel {
    /// Nil shows a new conversation in Chats, or the archive's selection prompt.
    var selection: UUID?
    var showsArchive = false
    var composerID = UUID()
    /// Agent mode for the next new chat: the folder it runs in. Off for every new chat.
    var agentDirectory: URL?

    func newChat() {
        showsArchive = false
        selection = nil
        agentDirectory = nil
        composerID = UUID()
    }

    func showArchive(_ archived: Bool) {
        showsArchive = archived
        selection = nil
        agentDirectory = nil
        composerID = UUID()
    }
}

final class MainWindowController: NSObject, NSWindowDelegate {
    private let model = MainWindowModel()
    /// AppDelegate can update application policy without the window owning app-wide behavior.
    var onVisibilityChange: ((Bool) -> Void)?
    var isVisible: Bool { window.isVisible }

    private(set) lazy var window: NSWindow = {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = "ReGlance"
        window.titleVisibility = .hidden
        window.contentMinSize = NSSize(width: 900, height: 620)
        window.contentViewController = MainHostingController(rootView: MainView(chats: chats, window: model))
        window.addTitlebarAccessoryViewController(ConversationTitleController())
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.delegate = self
        window.center()
        // Demo mode must not move the real window's saved frame.
        if !DemoMode.isEnabled { window.setFrameAutosaveName("MainWindow") }
        return window
    }()
    private let chats: ChatController

    init(chats: ChatController) {
        self.chats = chats
        super.init()
    }

    func show(chatID: UUID? = nil) {
        NSApp.setActivationPolicy(.regular)
        if let chat = chats.chat(chatID) {
            model.showsArchive = chat.isArchived
            model.selection = chat.id
        }
        WindowPresentation.prepare(window)
        window.deminiaturize(nil)
        window.makeKeyAndOrderFront(nil)
        if !WindowPresentation.isHeadless { NSApp.activate() }
        onVisibilityChange?(true)
    }

    /// Entry point for the app menu's Command-N action.
    func newChat() {
        model.newChat()
        show()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        onVisibilityChange?(false)
        return false
    }
}

private final class MainHostingController: NSHostingController<MainView> {
    override func viewDidLayout() {
        super.viewDidLayout()
        // SwiftUI may recreate the native split item after a layout change.
        SidebarLayout.configure(in: view)
    }
}

private final class ConversationTitleController: NSTitlebarAccessoryViewController {
    private let label = NSTextField(labelWithString: "")
    private var titleObservation: NSKeyValueObservation?

    override func loadView() {
        layoutAttribute = .left
        view = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 28))
        label.identifier = NSUserInterfaceItemIdentifier("conversationTitle")
        label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        view.addSubview(label)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard let window = view.window else { return }
        titleObservation = window.observe(\.title, options: [.initial, .new]) { [weak self] window, _ in
            MainActor.assumeIsolated {
                self?.label.stringValue = window.title
                self?.label.toolTip = window.title
            }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(centerTitle),
                                               name: NSWindow.didResizeNotification, object: window)
        centerTitle()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        titleObservation = nil
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResizeNotification, object: nil)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        centerTitle()
    }

    @objc private func centerTitle() {
        guard let window = view.window else { return }
        // A leading accessory participates in native titlebar layout, but its label
        // is positioned in window coordinates, independently of the split divider.
        let center = view.convert(NSPoint(x: window.frame.width / 2, y: 0), from: nil).x
        let width: CGFloat = 360
        view.setFrameSize(NSSize(width: center + width / 2, height: view.frame.height))
        let height = label.fittingSize.height
        label.frame = NSRect(x: center - width / 2, y: (view.bounds.height - height) / 2,
                             width: width, height: height)
    }
}

private enum SidebarSelection: Hashable {
    case chats, archive, chat(UUID)
}

private struct MainView: View {
    let chats: ChatController
    @Bindable var window: MainWindowModel
    @State private var search = ""
    @State private var renamingChat: Chat?
    @State private var deletingChat: Chat?
    @State private var deletionError: String?

    private var visibleChats: [Chat] {
        let source = window.showsArchive ? chats.archivedChats : chats.activeChats
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? source : source.filter { $0.title.localizedStandardContains(query) }
    }

    private var sidebarSelection: Binding<SidebarSelection?> {
        Binding {
            window.selection.map(SidebarSelection.chat) ?? (window.showsArchive ? .archive : .chats)
        } set: { selection in
            switch selection {
            case .chats: window.showArchive(false)
            case .archive: window.showArchive(true)
            case .chat(let id): window.selection = id
            case nil: window.selection = nil
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: sidebarSelection) {
                Section("Library") {
                    SidebarRow(title: "Chats", systemImage: "bubble.left.and.bubble.right", isDestination: true)
                        .tag(SidebarSelection.chats)
                    SidebarRow(title: "Archive", systemImage: "archivebox", isDestination: true)
                        .tag(SidebarSelection.archive)
                }
                if visibleChats.contains(where: \.isPinned) {
                    Section("Pinned") {
                        rows(visibleChats.filter(\.isPinned))
                    }
                }
                Section(window.showsArchive ? "Archived chats" : "Recent chats") {
                    rows(visibleChats.filter { !$0.isPinned })
                    if visibleChats.isEmpty {
                        Text(search.isEmpty ? (window.showsArchive ? "No archived chats" : "No chats yet") : "No matching chats")
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 10)
                    }
                }
            }
            .listStyle(.sidebar)
            .searchable(text: $search, placement: .sidebar, prompt: "Search chat titles")
            .toolbar(removing: .sidebarToggle)
            .alert("Couldn't Delete Chat", isPresented: Binding(
                get: { deletionError != nil },
                set: { if !$0 { deletionError = nil } }
            )) {
                Button("OK", role: .cancel) { deletionError = nil }
            } message: {
                Text(deletionError ?? "")
            }
        } detail: {
            ConversationView(chats: chats, window: window)
                // Each conversation owns its composer and attachment tray. A late file
                // preparation result stays with the old tray instead of the next chat.
                .id(window.selection ?? window.composerID)
        }
        // These are window actions, not sidebar items. Trailing placement is
        // independent of the moving split divider, so both controls stay put.
        .toolbar {
            // The title lives in a native accessory; keep flexible space before the actions.
            ToolbarItem(placement: .automatic) { Spacer() }
            ToolbarItem(id: "newChat", placement: .primaryAction) {
                Button("New Chat", systemImage: "square.and.pencil") { window.newChat() }
                    .help("New Chat")
            }
        }
        .frame(minWidth: 900, minHeight: 620)
        .sheet(item: $renamingChat) { chat in
            RenameChatSheet(title: chat.title) { title in
                chats.rename(chat.id, to: title)
            }
        }
        .alert("Delete Chat?", isPresented: Binding(
            get: { deletingChat != nil },
            set: { if !$0 { deletingChat = nil } }
        ), presenting: deletingChat) { chat in
            Button("Delete", role: .destructive) {
                do {
                    try chats.delete(chat.id)
                    if window.selection == chat.id { window.selection = nil }
                } catch {
                    deletionError = error.localizedDescription
                }
                deletingChat = nil
            }
            Button("Cancel", role: .cancel) { deletingChat = nil }
        } message: { chat in
            Text("Delete \"\(chat.title)\" and its attachment copies from ReGlance? This cannot be undone. Claude CLI session history is not deleted.")
        }
        .onChange(of: chats.chat(window.selection)?.isArchived) {
            if let selected = chats.chat(window.selection), selected.isArchived != window.showsArchive {
                window.selection = nil
            }
        }
        .onChange(of: chats.chat(window.selection)?.id) {
            if window.selection != nil, chats.chat(window.selection) == nil { window.selection = nil }
        }
    }

    private func rows(_ items: [Chat]) -> some View {
        ForEach(items) { chat in
            SidebarRow(title: chat.title, systemImage: chat.isPinned ? "pin.fill" : "bubble.left",
                       updatedAt: chat.updatedAt, isReplying: chats.isStreaming(chat.id),
                       agentPermissions: chat.isAgent ? chat.agentPermissions : nil)
            .tag(SidebarSelection.chat(chat.id))
            .contextMenu {
                Button("Rename…", systemImage: "pencil") { renamingChat = chat }
                Button(chat.isPinned ? "Unpin" : "Pin", systemImage: chat.isPinned ? "pin.slash" : "pin") {
                    chats.setPinned(!chat.isPinned, for: chat.id)
                }
                Button(chat.isArchived ? "Unarchive" : "Archive", systemImage: "archivebox") {
                    chats.setArchived(!chat.isArchived, for: chat.id)
                    if window.selection == chat.id { window.selection = nil }
                }
                Divider()
                Button("Delete…", systemImage: "trash", role: .destructive) { deletingChat = chat }
            }
        }
    }
}

/// One icon column, text inset and vertical padding for every sidebar destination
/// and conversation. A pin replaces the chat icon instead of moving the title.
struct SidebarRow: View {
    let title: String
    let systemImage: String
    var updatedAt: Date? = nil
    var isReplying = false
    /// Set for agent chats.
    var agentPermissions: AgentPermissions? = nil
    var isDestination = false
    @Environment(\.backgroundProminence) private var backgroundProminence

    private var iconColor: Color {
        if backgroundProminence == .increased { return .white }
        return isDestination ? .accentColor : .secondary
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 15))
                .foregroundStyle(iconColor)
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(updatedAt == nil ? 1 : 2)
                if let updatedAt {
                    HStack(spacing: 6) {
                        if let agentPermissions { AgentModeBadge(permissions: agentPermissions, compact: true) }
                        Text(updatedAt, format: .relative(presentation: .named))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if isReplying {
                ProgressView().controlSize(.small).accessibilityLabel("Replying")
            }
        }
        .padding(.vertical, 6)
        // The list already insets rows inside the selection; with these the icon sits as
        // far from the highlight's leading edge as from its top and bottom (about 10pt).
        .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
    }
}

private struct RenameChatSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var title: String
    let onSave: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Rename Chat").font(.headline)
            TextField("Chat title", text: $title)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Rename", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 400)
    }

    private func save() {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        onSave(title)
        dismiss()
    }
}

private struct ConversationView: View {
    let chats: ChatController
    @Bindable var window: MainWindowModel
    @State private var text = ""
    @State private var attachments = AttachmentTray()
    @State private var model: ClaudeModel
    @State private var effort: ClaudeEffort
    @State private var focusToken = 0
    /// Observed so a composer already in agent mode recolours when Settings changes.
    @AppStorage(AgentMode.bypassKey, store: AgentMode.defaults) private var bypassesPermissions = false

    init(chats: ChatController, window: MainWindowModel) {
        self.chats = chats
        self.window = window
        let selected = chats.chat(window.selection)
        _model = State(initialValue: selected?.model ?? .sonnet)
        _effort = State(initialValue: selected?.effort ?? .automatic)
    }

    var body: some View {
        let chat = chats.chat(window.selection)
        let isStreaming = chats.isStreaming(window.selection)

        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 26) {
                    ForEach(chat?.messages ?? []) { message in
                        let isLast = message.id == chat?.messages.last?.id
                        MessageView(
                            message: message, isStreaming: isStreaming && isLast, isLast: isLast,
                            canRegenerate: window.selection.map(chats.canRegenerate) ?? false,
                            onRegenerate: {
                                if let id = window.selection { chats.regenerate(id, model: model, effort: effort) }
                            }
                        )
                    }
                }
                .environment(\.conversationTextSize, 16)
                .font(.system(size: 16))
                .padding(.horizontal, 32)
                .padding(.vertical, 28)
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom)
            .safeAreaInset(edge: .top, spacing: 0) {
                if let chat, let directory = chat.agentDirectory {
                    AgentBanner(directory: directory, permissions: chat.agentPermissions)
                }
            }
            .overlay {
                if chat == nil {
                    ContentUnavailableView {
                        Label(window.showsArchive ? "Archived Chats" : "Start a Conversation",
                              systemImage: window.showsArchive ? "archivebox" : "bubble.left.and.bubble.right")
                    } description: {
                        Text(window.showsArchive ? "Select an archived chat in the sidebar. Unarchive it to return it to Chats."
                             : "Ask a question or add a file to start a new chat.")
                    }
                }
            }

            // The same composer as the floating bar, with its own glass instead of the
            // floating panel's; it doesn't grow into a reply panel.
            if !window.showsArchive || chat != nil {
                PromptBarView(
                    text: $text, model: $model, effort: $effort, tray: attachments,
                    isStreaming: isStreaming, focusToken: focusToken,
                    onSend: {
                        guard !isStreaming else { return }
                        window.selection = chats.send(text, attachments: attachments.take(), model: model, effort: effort,
                                                      agentDirectory: window.agentDirectory,
                                                      agentPermissions: AgentMode.permissions, to: window.selection)
                        text = ""
                    },
                    onStop: { if let id = window.selection { chats.cancel(id) } },
                    // An open chat shows its own mode; the toggle only sets up the next chat.
                    agentDirectory: chat.map(\.agentDirectory) ?? window.agentDirectory,
                    agentPermissions: chat?.agentPermissions ?? (bypassesPermissions ? .bypass : .auto),
                    onToggleAgent: { toggleAgentMode(chat: chat) },
                    onChooseAgentDirectory: chat == nil ? {
                        if let directory = AgentMode.chooseDirectory() { window.agentDirectory = directory }
                        focusToken += 1
                    } : nil
                )
                .frame(maxWidth: 820)
                .attachmentDrop(attachments)
                .padding(.horizontal, 32)
                .padding(.vertical, 24)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .navigationTitle(chat?.title ?? (window.showsArchive ? "Archive" : "New Chat"))
        .onAppear { focusToken += 1 }
    }

    /// A chat keeps the mode it was created with, so switching while one is open starts
    /// a new chat.
    private func toggleAgentMode(chat: Chat?) {
        let isOn = chat?.isAgent ?? (window.agentDirectory != nil)
        if isOn {
            withAnimation(AgentMode.toggleAnimation) {
                if chat == nil { window.agentDirectory = nil } else { window.newChat() }
            }
        } else if AgentMode.confirmEnabling() {
            withAnimation(AgentMode.toggleAnimation) {
                if chat != nil { window.newChat() }
                window.agentDirectory = AgentMode.directory
            }
        }
        focusToken += 1
    }
}

/// Above every agent conversation, so reopening one never looks like an ordinary chat.
private struct AgentBanner: View {
    let directory: URL
    let permissions: AgentPermissions

    var body: some View {
        HStack(spacing: 10) {
            AgentModeBadge(permissions: permissions)
            Text(permissions.explanation(in: AgentMode.displayPath(directory)))
                .font(.system(size: 12.5))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(directory.path)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(permissions.color.opacity(0.12))
        .overlay(alignment: .bottom) { Rectangle().fill(permissions.color).frame(height: 1.5) }
    }
}
