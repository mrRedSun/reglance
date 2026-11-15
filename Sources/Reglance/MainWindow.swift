import AppKit
import ChatCore
import SwiftUI

@Observable
final class MainWindowModel {
    /// Selected chat; nil shows an empty conversation that starts a new chat on send.
    var selection: UUID?
}

final class MainWindowController {
    private let model = MainWindowModel()
    private lazy var window: NSWindow = {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = "Reglance"
        window.contentViewController = NSHostingController(rootView: MainView(chats: chats, window: model))
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("MainWindow")
        return window
    }()
    private let chats: ChatController

    init(chats: ChatController) {
        self.chats = chats
    }

    func show(chatID: UUID? = nil) {
        if let chatID { model.selection = chatID }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

private struct MainView: View {
    let chats: ChatController
    @Bindable var window: MainWindowModel

    var body: some View {
        NavigationSplitView {
            List(chats.chats, selection: $window.selection) { chat in
                VStack(alignment: .leading, spacing: 2) {
                    Text(chat.title).lineLimit(1)
                    Text(chat.updatedAt, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(chat.id)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
            .toolbar {
                Button("New Chat", systemImage: "square.and.pencil") { window.selection = nil }
            }
        } detail: {
            ConversationView(chats: chats, window: window)
        }
        .frame(minWidth: 640, minHeight: 400)
    }
}

private struct ConversationView: View {
    let chats: ChatController
    @Bindable var window: MainWindowModel
    @State private var text = ""
    @State private var attachments = AttachmentTray()
    @State private var model: ClaudeModel = .sonnet
    @State private var focusToken = 0

    var body: some View {
        let chat = chats.chat(window.selection)
        let isStreaming = chats.isStreaming(window.selection)

        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(chat?.messages ?? []) { message in
                        let isLast = message.id == chat?.messages.last?.id
                        MessageView(
                            message: message, isStreaming: isStreaming && isLast, isLast: isLast,
                            canRegenerate: window.selection.map(chats.canRegenerate) ?? false,
                            onRegenerate: { if let id = window.selection { chats.regenerate(id) } }
                        )
                    }
                }
                .padding(20)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom)
            .overlay {
                if chat == nil {
                    Text("Ask anything to start a new chat.").foregroundStyle(.secondary)
                }
            }

            PromptBarView(
                text: $text, model: $model, tray: attachments, isStreaming: isStreaming, focusToken: focusToken,
                onSend: {
                    window.selection = chats.send(text, attachments: attachments.take(), model: model, to: window.selection)
                    text = ""
                },
                onStop: { if let id = window.selection { chats.cancel(id) } }
            )
            .frame(maxWidth: 640)
            .attachmentDrop(attachments)
            .padding(16)
        }
        .navigationTitle(chat?.title ?? "New Chat")
        .onChange(of: window.selection, initial: true) {
            if let chat { model = chat.model }
            focusToken += 1
        }
    }
}
