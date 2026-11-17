import AppKit
import ChatCore
import SwiftUI

enum SidebarSelection: Hashable {
    case chats, archive, chat(UUID)
}

/// The chats window's content: the library sidebar and the conversation beside it.
struct MainView: View {
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
                // Each conversation starts its own scroll position. The draft lives in the
                // composer session, so turning agent mode on keeps it.
                .id(window.selection ?? window.conversationID)
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
