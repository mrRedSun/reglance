import AppKit
import ChatCore
import SwiftUI

struct ConversationView: View {
    let chats: ChatController
    @Bindable var window: MainWindowModel

    var body: some View {
        let composer = window.composer
        let chat = composer.chat
        let streamingReplyID = composer.streamingReplyID

        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 26) {
                    ForEach(chat?.messages ?? []) { message in
                        let isLast = message.id == chat?.messages.last?.id
                        MessageView(
                            message: message, isStreaming: message.id == streamingReplyID, isLast: isLast,
                            canRegenerate: composer.canRegenerate, onRegenerate: composer.regenerate
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
                PromptBarView(session: composer)
                    .frame(maxWidth: 820)
                    .attachmentDrop(composer.attachments)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 24)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .navigationTitle(chat?.title ?? (window.showsArchive ? "Archive" : "New Chat"))
        .onAppear { composer.focusToken += 1 }
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
