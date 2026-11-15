import AppKit
import ChatCore
import SwiftUI

/// Borderless, non-activating panel: it takes keyboard input without activating the app,
/// so the app you were using stays frontmost.
final class FloatingPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 600, height: 80),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false            // the glass draws its own shadow
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// State of the floating bar that isn't part of a chat.
@Observable
final class FloatingBarModel {
    var text = ""
    let attachments = AttachmentTray()
    var model: ClaudeModel = .sonnet
    /// The chat shown under the bar; nil means the next send starts a new chat.
    var chatID: UUID?
    var focusToken = 0
}

final class FloatingPanelController {
    private let panel = FloatingPanel()
    private let model = FloatingBarModel()
    private let chats: ChatController
    private var escapeMonitor: Any?
    private var hasPosition = false

    /// Margin around the glass so its shadow isn't clipped by the window edge.
    static let margin: CGFloat = 20
    /// Width of the bar and the expanded panel (the design's 560pt).
    static let contentWidth: CGFloat = 560

    init(chats: ChatController, openInWindow: @escaping (UUID) -> Void) {
        self.chats = chats
        let root = FloatingRootView(
            chats: chats, bar: model,
            onSize: { [weak self] in self?.resize(to: $0) },
            openInWindow: openInWindow,
            close: { [weak self] in self?.hide() }
        )
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []   // the controller sizes the panel (see `resize`)
        panel.contentView = hosting

        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel, event.keyCode == 53 /* Esc */ else { return event }
            self.hide()
            return nil
        }
    }

    var isVisible: Bool { panel.isVisible }

    func toggle() {
        if panel.isVisible && panel.isKeyWindow { hide() } else { show() }
    }

    func show() {
        // First show, or the mouse moved to another display: place it there. Otherwise keep
        // the spot the user dragged it to.
        if !hasPosition || panel.screen?.frame != mouseScreen?.frame { positionOnActiveScreen() }
        panel.makeKeyAndOrderFront(nil)
        model.focusToken += 1
    }

    func hide() {
        panel.orderOut(nil)
    }

    private var mouseScreen: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
    }

    /// Centre horizontally in the lower part of the screen under the mouse, leaving room
    /// above for the reply to grow into.
    private func positionOnActiveScreen() {
        guard let screen = mouseScreen else { return }
        // The hosting view doesn't report a fitting size (the controller sizes the panel),
        // so centre on the known width and keep the current height.
        let width = Self.contentWidth + 2 * Self.margin
        let visible = screen.visibleFrame
        let bottom = visible.minY + visible.height * 0.18 - Self.margin
        panel.setFrame(NSRect(x: visible.midX - width / 2, y: bottom,
                              width: width, height: panel.frame.height), display: false)
        hasPosition = true
    }

    /// Resize to the SwiftUI content, keeping the bottom edge fixed so the bar stays put
    /// and the reply grows upward.
    private func resize(to size: CGSize) {
        let old = panel.frame
        guard old.size != size else { return }
        var frame = NSRect(x: old.minX, y: old.minY, width: size.width, height: size.height)
        // Don't grow past the top of the screen; shift down instead.
        if let visible = panel.screen?.visibleFrame, frame.maxY > visible.maxY {
            frame.origin.y = max(visible.minY, visible.maxY - frame.height)
        }
        panel.setFrame(frame, display: true, animate: false)
    }
}

private struct FloatingRootView: View {
    let chats: ChatController
    @Bindable var bar: FloatingBarModel
    let onSize: (CGSize) -> Void
    let openInWindow: (UUID) -> Void
    let close: () -> Void

    var body: some View {
        let chat = chats.chat(bar.chatID)
        let isStreaming = chats.isStreaming(bar.chatID)

        // One container so the bar and panel glass render and blend as a single material.
        GlassEffectContainer {
            if let chat {
                ReplyView(
                    chat: chat, isStreaming: isStreaming,
                    canRegenerate: chats.canRegenerate(chat.id),
                    recentChats: chats.chats,
                    onSelectChat: { id in
                        bar.chatID = id
                        if let model = chats.chat(id)?.model { bar.model = model }
                        bar.focusToken += 1
                    },
                    onNewChat: {
                        bar.chatID = nil
                        bar.focusToken += 1
                    },
                    onOpenInWindow: { openInWindow(chat.id) },
                    onClose: close,
                    onRegenerate: { chats.regenerate(chat.id) }
                ) {
                    promptBar(isStreaming: isStreaming, docked: true)
                }
            } else {
                promptBar(isStreaming: isStreaming, docked: false)
            }
        }
        .frame(width: FloatingPanelController.contentWidth)
        .attachmentDrop(bar.attachments)
        .padding(FloatingPanelController.margin)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { onSize($0) }
    }

    private func promptBar(isStreaming: Bool, docked: Bool) -> some View {
        PromptBarView(
            text: $bar.text, model: $bar.model, tray: bar.attachments,
            isStreaming: isStreaming, docked: docked, focusToken: bar.focusToken,
            onSend: {
                bar.chatID = chats.send(bar.text, attachments: bar.attachments.take(), model: bar.model, to: bar.chatID)
                bar.text = ""
            },
            onStop: { if let id = bar.chatID { chats.cancel(id) } }
        )
    }
}

