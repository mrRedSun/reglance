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

/// Whether the floating bar's glass is shown, for the open and close bloom.
@Observable
final class FloatingPresentation {
    var isPresented = false
}

final class FloatingPanelController {
    let panel = FloatingPanel()
    let composer: ComposerSession
    private let presentation = FloatingPresentation()
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
    /// The picker card in the hosting view's coordinates; empty while it's closed.
    private(set) var pickerFrame: CGRect = .zero

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

    init(chats: ChatController, composer: ComposerSession? = nil,
         newChatAfter: @escaping () -> TimeInterval = { NewChatAfter.current() },
         now: @escaping () -> Date = Date.init,
         openInWindow: @escaping (UUID) -> Void) {
        self.chats = chats
        let composer = composer ?? ComposerSession(chats: chats)
        self.composer = composer
        self.newChatAfter = newChatAfter
        self.now = now
        let root = FloatingRootView(
            bar: composer, presentation: presentation,
            onGlassFrame: { [weak self] in
                self?.glassFrame = $0
                self?.updateMousePassthrough()
            },
            onPickerFrame: { [weak self] in
                self?.pickerFrame = $0
                self?.updateMousePassthrough()
            },
            openInWindow: openInWindow,
            close: { [weak self] in self?.hide() }
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
        // A non-activating panel doesn't get the main menu's key equivalents, so its
        // shortcuts are handled here, calling the same methods as the buttons.
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            return self.handleShortcut(event, openInWindow: openInWindow) ? nil : event
        }
        // An agent-mode alert or folder panel takes key focus from the panel; give it back.
        composer.afterModal = { [weak self] in self?.refocus() }
    }

    /// Esc closes the picker, then the panel; ⌘N, ⌘O, ⌘W and ⌘⇧A. True when handled.
    private func handleShortcut(_ event: NSEvent, openInWindow: (UUID) -> Void) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased()
        if event.keyCode == 53 {
            if composer.pickerIsPresented { composer.setPickerPresented(false) } else { hide() }
            return true
        }
        switch (modifiers, key) {
        case (.command, "n"): withAnimation(ComposerMotion.layout()) { composer.startNewChat() }
        case (.command, "o"): if let id = composer.chatID { openInWindow(id) }
        case (.command, "w"): hide()
        case ([.command, .shift], "a"): composer.toggleAgentMode()
        case ([.command, .shift], "d"): composer.toggleDictation()
        default: return false
        }
        return true
    }

    private func refocus() {
        guard panel.isVisible else { return }
        panel.makeKeyAndOrderFront(nil)
    }

    var isPresented: Bool { presentation.isPresented }

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
        Task { await ModelLibrary.shared.refresh() }
        if isEntering {
            startNewChatIfIdle()
            if composer.chatID == nil { composer.adoptLastChoice() }
        }
        // First show, or the mouse moved to another display: place it there. Otherwise keep
        // the spot the user dragged it to.
        if !hasPosition || panel.screen?.frame != mouseScreen?.frame { positionOnActiveScreen() }
        WindowPresentation.prepare(panel)
        panel.makeKeyAndOrderFront(nil)
        composer.focusToken += 1
        updateMousePassthrough()
        guard isEntering else { return } // Refocusing an open panel must not restart its spring.
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        presentationGeneration += 1
        let generation = presentationGeneration
        // Let the hidden starting state reach the compositor before expanding the glass.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel.isVisible, self.presentationGeneration == generation else { return }
            // Tests run headless and check the settled layout, so they skip the bloom.
            var transaction = Transaction()
            transaction.disablesAnimations = WindowPresentation.isHeadless
            withTransaction(transaction) { self.presentation.isPresented = true }
        }
    }

    func hide() {
        if panel.isVisible { hiddenAt = now() }
        composer.dictation.finish() // The microphone never stays on behind a hidden bar.
        presentationGeneration += 1
        panel.orderOut(nil)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            presentation.isPresented = false
            composer.pickerIsPresented = false
        }
    }

    /// After the bar has been hidden for the chosen time, it reopens on a new chat. The draft
    /// stays, and a chat that is still replying stays open.
    private func startNewChatIfIdle() {
        let limit = newChatAfter()
        guard limit > 0, let hiddenAt, now().timeIntervalSince(hiddenAt) >= limit,
              let id = composer.chatID, !chats.isStreaming(id) else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            composer.chatID = nil
            composer.agentDirectory = nil
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
    @Bindable var bar: ComposerSession
    let presentation: FloatingPresentation
    let onGlassFrame: (CGRect) -> Void
    let onPickerFrame: (CGRect) -> Void
    let openInWindow: (UUID) -> Void
    let close: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Observed so a composer already in agent mode recolours when Settings changes.
    @AppStorage(AgentMode.bypassKey, store: AgentMode.defaults) private var bypassesPermissions = false

    var body: some View {
        let chat = bar.chat
        let isPresented = presentation.isPresented
        let scale = FloatingPanelMotion.scale(isPresented: isPresented, reduceMotion: reduceMotion)

        // One container so the bar and panel glass render and blend as a single material.
        GlassEffectContainer {
            VStack(alignment: .trailing, spacing: 10) {
                ReplyView(
                    chat: chat, streamingReplyID: bar.streamingReplyID, canRegenerate: bar.canRegenerate,
                    onNewChat: { withAnimation(ComposerMotion.layout(reduceMotion: reduceMotion)) { bar.startNewChat() } },
                    onOpenInWindow: { if let chat { openInWindow(chat.id) } },
                    onClose: close,
                    onRegenerate: bar.regenerate
                ) {
                    PromptBarView(session: bar, docked: chat != nil, embedded: true,
                                  sendAnimation: ComposerMotion.layout(reduceMotion: reduceMotion))
                }
                .glowAnchor()
            }
            .frame(width: FloatingPanelController.contentWidth)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { onGlassFrame($0) }
            .padding(FloatingPanelController.glassInset)
            // Pinned to the bottom of the tall panel, so growth only ever goes upward. The
            // root spans the panel so the picker card has room above the bar.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .edgeGlow(agent: bar.shownAgentDirectory == nil ? nil
                      : (chat?.agentPermissions ?? (bypassesPermissions ? .bypass : .auto)).color,
                  isListening: bar.dictation.state == .listening,
                  cornerRadius: chat == nil ? ComposerShape.cornerRadius : ComposerShape.panelCornerRadius)
        .modelPickerOverlay(isPresented: bar.pickerIsPresented, model: $bar.model, effort: $bar.effort,
                            backend: bar.lockedBackend, reduceMotion: reduceMotion,
                            onDone: { bar.setPickerPresented(false) },
                            onFrame: onPickerFrame)
        // Animate only presentation, never the NSWindow frame or the editor's layout.
        .scaleEffect(x: scale.width, y: scale.height, anchor: .bottom)
        .blur(radius: FloatingPanelMotion.blur(isPresented: isPresented, reduceMotion: reduceMotion))
        .opacity(isPresented ? 1 : 0)
        .animation(FloatingPanelMotion.animation(reduceMotion: reduceMotion), value: isPresented)
        .attachmentDrop(bar.attachments)
        .padding(FloatingPanelController.margin)
    }
}
