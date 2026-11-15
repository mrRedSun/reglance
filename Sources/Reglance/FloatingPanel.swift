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
    var effort: ClaudeEffort = .automatic
    /// The chat shown under the bar; nil means the next send starts a new chat.
    var chatID: UUID?
    /// Agent mode for the next new chat: the folder it runs in. Off for every new chat.
    /// Its permissions come from Settings when the chat starts (`AgentMode.permissions`).
    var agentDirectory: URL?
    var focusToken = 0
    var isPresented = false
    var pickerIsPresented = false

    /// Sends the draft to the open chat, or starts one. Callers choose the animation.
    func send(using chats: ChatController) {
        chatID = chats.send(text, attachments: attachments.take(), model: model, effort: effort,
                            agentDirectory: agentDirectory, agentPermissions: AgentMode.permissions, to: chatID)
        text = ""
    }
}

/// How long the bar may stay hidden before it reopens on a new chat. Zero means never.
enum NewChatAfter {
    static let defaultsKey = "newChatAfterSeconds"
    static let defaultValue: TimeInterval = 5 * 60
    static let options: [(title: String, seconds: TimeInterval)] = [
        ("1 minute", 60), ("5 minutes", 5 * 60), ("15 minutes", 15 * 60), ("1 hour", 60 * 60), ("Never", 0),
    ]

    static func current(in defaults: UserDefaults = .standard) -> TimeInterval {
        defaults.object(forKey: defaultsKey) as? TimeInterval ?? defaultValue
    }
}

final class FloatingPanelController {
    let panel = FloatingPanel()
    private let model: FloatingBarModel
    private let chats: ChatController
    private let newChatAfter: () -> TimeInterval
    private let now: () -> Date
    private var hiddenAt: Date?
    private var escapeMonitor: Any?
    private var hasPosition = false
    private var presentationGeneration = 0
    private var mouseMonitors: [Any] = []
    /// The glass in the hosting view's coordinates, reported by SwiftUI.
    private var glassFrame: CGRect = .zero
    private var pickerFrame: CGRect = .zero

    /// Margin around the glass so its shadow isn't clipped by the window edge.
    static let margin: CGFloat = 24
    /// The glass compositor also needs clearance inside its own container.
    static let glassInset: CGFloat = 16
    static var windowWidth: CGFloat { contentWidth + 2 * (margin + glassInset) }
    /// The panel keeps one tall, transparent frame and the glass grows inside it, pinned to
    /// the bottom. Resizing the NSWindow mid-animation moves SwiftUI's top-left origin and
    /// makes the content jump; clicks on the transparent area pass through to apps below.
    /// Tall enough for the header, the 470pt message area, the picker and the composer.
    static let windowHeight: CGFloat = 760
    /// Width of the bar and the expanded panel (the design's 560pt).
    static let contentWidth: CGFloat = 560

    init(chats: ChatController, model: FloatingBarModel = FloatingBarModel(),
         newChatAfter: @escaping () -> TimeInterval = { NewChatAfter.current() },
         now: @escaping () -> Date = Date.init,
         openInWindow: @escaping (UUID) -> Void) {
        self.chats = chats
        self.model = model
        self.newChatAfter = newChatAfter
        self.now = now
        let root = FloatingRootView(
            chats: chats, bar: model,
            onGlassFrame: { [weak self] in
                self?.glassFrame = $0
                self?.updateMousePassthrough()
            },
            onPickerFrame: { [weak self] in
                self?.pickerFrame = $0
                self?.updateMousePassthrough()
            },
            openInWindow: openInWindow,
            close: { [weak self] in self?.hide() },
            toggleAgent: { [weak self] in self?.toggleAgentMode() },
            chooseAgentDirectory: { [weak self] in self?.chooseAgentDirectory() }
        )
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []   // fixed frame, see `windowHeight`
        panel.contentView = hosting

        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        mouseMonitors = [
            NSEvent.addGlobalMonitorForEvents(matching: moves) { [weak self] _ in self?.updateMousePassthrough() },
            NSEvent.addLocalMonitorForEvents(matching: moves) { [weak self] event in
                self?.updateMousePassthrough()
                return event
            },
        ].compactMap { $0 }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            if event.keyCode == 53 { // Esc dismisses the accessory before the panel.
                if self.model.pickerIsPresented {
                    withAnimation(.easeOut(duration: 0.15)) { self.model.pickerIsPresented = false }
                } else {
                    self.hide()
                }
                return nil
            }
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "n":
                    self.model.pickerIsPresented = false
                    self.model.chatID = nil
                    self.model.agentDirectory = nil
                    self.model.text = ""
                    _ = self.model.attachments.take()
                    self.model.focusToken += 1
                    return nil
                case "o":
                    if let id = self.model.chatID { openInWindow(id) }
                    return nil
                case "w":
                    self.hide()
                    return nil
                default: break
                }
            }
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command, .shift],
               event.charactersIgnoringModifiers?.lowercased() == "a" {
                self.toggleAgentMode()
                return nil
            }
            return event
        }
    }

    /// A chat keeps the mode it was created with, so switching while one is open starts
    /// a new chat. The draft stays in the composer.
    func toggleAgentMode() {
        model.pickerIsPresented = false
        let isOn = chats.chat(model.chatID)?.isAgent ?? (model.agentDirectory != nil)
        if isOn {
            withAnimation(AgentMode.toggleAnimation) {
                model.agentDirectory = nil
                model.chatID = nil
            }
        } else if AgentMode.confirmEnabling() {
            withAnimation(AgentMode.toggleAnimation) {
                model.agentDirectory = AgentMode.directory
                model.chatID = nil
            }
        }
        refocus()
    }

    func chooseAgentDirectory() {
        if let directory = AgentMode.chooseDirectory() { model.agentDirectory = directory }
        refocus()
    }

    /// A modal alert or open panel takes key focus from the panel.
    private func refocus() {
        guard panel.isVisible else { return }
        panel.makeKeyAndOrderFront(nil)
        model.focusToken += 1
    }

    isolated deinit {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        mouseMonitors.forEach(NSEvent.removeMonitor)
    }

    var isVisible: Bool { panel.isVisible }

    func toggle() {
        if panel.isVisible && panel.isKeyWindow { hide() } else { show() }
    }

    func show() {
        let isEntering = !panel.isVisible
        if isEntering { startNewChatIfIdle() }
        // First show, or the mouse moved to another display: place it there. Otherwise keep
        // the spot the user dragged it to.
        if !hasPosition || panel.screen?.frame != mouseScreen?.frame { positionOnActiveScreen() }
        panel.makeKeyAndOrderFront(nil)
        model.focusToken += 1
        updateMousePassthrough()
        guard isEntering else { return } // Refocusing an open panel must not restart its spring.
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        presentationGeneration += 1
        let generation = presentationGeneration
        // Let the hidden starting state reach the compositor before expanding the glass.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel.isVisible, self.presentationGeneration == generation else { return }
            self.model.isPresented = true
        }
    }

    func hide() {
        if panel.isVisible { hiddenAt = now() }
        presentationGeneration += 1
        panel.orderOut(nil)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            model.isPresented = false
            model.pickerIsPresented = false
        }
    }

    /// After the bar has been hidden for the chosen time, it reopens on a new chat. The draft
    /// stays, and a chat that is still replying stays open.
    private func startNewChatIfIdle() {
        let limit = newChatAfter()
        guard limit > 0, let hiddenAt, now().timeIntervalSince(hiddenAt) >= limit,
              let id = model.chatID, !chats.isStreaming(id) else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            model.chatID = nil
            model.agentDirectory = nil
        }
    }

    private var mouseScreen: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
    }

    /// Centre horizontally in the lower part of the screen under the mouse. The bar sits
    /// at the bottom of the tall panel and the reply grows upward into it.
    private func positionOnActiveScreen() {
        guard let screen = mouseScreen else { return }
        let visible = screen.visibleFrame
        let bottom = visible.minY + visible.height * 0.18 - Self.margin - Self.glassInset
        let height = min(Self.windowHeight, visible.maxY - bottom)
        panel.setFrame(NSRect(x: visible.midX - Self.windowWidth / 2, y: bottom,
                              width: Self.windowWidth, height: height), display: false)
        hasPosition = true
    }

    /// Clicks outside the glass go to the app underneath, so the tall transparent panel
    /// never blocks the screen above the bar.
    private func updateMousePassthrough() {
        guard panel.isVisible, let hosting = panel.contentView else { return }
        let mouse = panel.convertPoint(fromScreen: NSEvent.mouseLocation)
        let ignores = ![glassFrame, pickerFrame].contains { rect in
            !rect.isEmpty && hosting.convert(rect.insetBy(dx: -4, dy: -4), to: nil).contains(mouse)
        }
        if panel.ignoresMouseEvents != ignores { panel.ignoresMouseEvents = ignores }
    }
}

private struct FloatingRootView: View {
    let chats: ChatController
    @Bindable var bar: FloatingBarModel
    let onGlassFrame: (CGRect) -> Void
    let onPickerFrame: (CGRect) -> Void
    let openInWindow: (UUID) -> Void
    let close: () -> Void
    let toggleAgent: () -> Void
    let chooseAgentDirectory: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Observed so a composer already in agent mode recolours when Settings changes.
    @AppStorage(AgentMode.bypassKey, store: AgentMode.defaults) private var bypassesPermissions = false

    var body: some View {
        let chat = chats.chat(bar.chatID)
        let isStreaming = chats.isStreaming(bar.chatID)
        let scale = FloatingPanelMotion.scale(isPresented: bar.isPresented, reduceMotion: reduceMotion)

        // One container so the bar and panel glass render and blend as a single material.
        GlassEffectContainer {
            VStack(alignment: .trailing, spacing: 10) {
                ReplyView(
                    chat: chat, isStreaming: isStreaming,
                    canRegenerate: chat.map { chats.canRegenerate($0.id) } ?? false,
                    onNewChat: {
                        withAnimation(reduceMotion ? nil : .spring(response: 0.40, dampingFraction: 0.82)) {
                            bar.pickerIsPresented = false
                            bar.chatID = nil
                            bar.agentDirectory = nil
                            bar.text = ""
                            _ = bar.attachments.take()
                            bar.focusToken += 1
                        }
                    },
                    onOpenInWindow: { if let chat { openInWindow(chat.id) } },
                    onClose: close,
                    onRegenerate: { if let chat { chats.regenerate(chat.id, model: bar.model, effort: bar.effort) } }
                ) {
                    promptBar(chat: chat, isStreaming: isStreaming)
                }
                .agentGlowAnchor()
            }
            .frame(width: FloatingPanelController.contentWidth)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { onGlassFrame($0) }
            .padding(FloatingPanelController.glassInset)
            // Pinned to the bottom of the tall panel, so growth only ever goes upward. The
            // root spans the panel so the picker card has room above the bar.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .agentGlow(isOn: chat.map(\.isAgent) ?? (bar.agentDirectory != nil),
                   color: (chat?.agentPermissions ?? (bypassesPermissions ? .bypass : .auto)).color,
                   cornerRadius: chat == nil ? ComposerShape.cornerRadius : ComposerShape.panelCornerRadius)
        .modelPickerOverlay(isPresented: bar.pickerIsPresented, model: $bar.model, effort: $bar.effort,
                            reduceMotion: reduceMotion,
                            onDone: {
                                withAnimation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.80)) {
                                    bar.pickerIsPresented = false
                                }
                            },
                            onFrame: onPickerFrame)
        // Animate only presentation, never the NSWindow frame or the editor's layout.
        .scaleEffect(x: scale.width, y: scale.height, anchor: .bottom)
        .blur(radius: FloatingPanelMotion.blur(isPresented: bar.isPresented, reduceMotion: reduceMotion))
        .opacity(bar.isPresented ? 1 : 0)
        .animation(FloatingPanelMotion.animation(reduceMotion: reduceMotion), value: bar.isPresented)
        .attachmentDrop(bar.attachments)
        .padding(FloatingPanelController.margin)
    }

    private func promptBar(chat: Chat?, isStreaming: Bool) -> some View {
        PromptBarView(
            text: $bar.text, model: $bar.model, effort: $bar.effort, tray: bar.attachments,
            isStreaming: isStreaming, docked: chat != nil, embedded: true, focusToken: bar.focusToken,
            onSend: {
                withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.40, dampingFraction: 0.82)) {
                    bar.send(using: chats)
                }
            },
            onStop: { if let id = bar.chatID { chats.cancel(id) } },
            pickerIsPresented: $bar.pickerIsPresented,
            usesExternalPicker: true,
            // An open chat shows its own mode; the toggle only sets up the next chat.
            agentDirectory: chat.map(\.agentDirectory) ?? bar.agentDirectory,
            agentPermissions: chat?.agentPermissions ?? (bypassesPermissions ? .bypass : .auto),
            onToggleAgent: toggleAgent,
            onChooseAgentDirectory: chat == nil ? chooseAgentDirectory : nil
        )
    }
}

