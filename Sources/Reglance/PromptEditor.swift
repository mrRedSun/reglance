import AppKit
import SwiftUI

/// A native editor handles both Cmd-V and Edit > Paste through the responder chain.
/// A local key monitor cannot reliably intercept SwiftUI's field editor on every OS.
struct PromptEditor: NSViewRepresentable {
    @Binding var text: String
    /// Read to VoiceOver. `PromptBarView` draws it, in SwiftUI so it adapts to the glass.
    let placeholder: String
    let tray: AttachmentTray
    let focusToken: Int
    let onSubmit: () -> Void
    var onCancel: () -> Void = {}
    var onHoldToTalk: () -> Void = {}
    var onReleaseToSend: () -> Void = {}
    var onReleaseTooSoon: () -> Void = {}
    /// Space above and below the text. The floating bar uses more, for a taller bar.
    var verticalInset: CGFloat = 5

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> PromptScrollView {
        let scroll = PromptScrollView()
        let editor = scroll.editor
        editor.delegate = context.coordinator
        context.coordinator.scroll = scroll
        editor.font = .systemFont(ofSize: 15)
        editor.textColor = .labelColor
        editor.insertionPointColor = .controlAccentColor
        editor.isRichText = false
        editor.isEditable = true
        editor.isSelectable = true
        editor.allowsUndo = true
        editor.drawsBackground = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainerInset = NSSize(width: 4, height: 5)
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainer?.widthTracksTextView = true
        editor.setAccessibilityLabel("Message")
        updateNSView(scroll, context: context)
        return scroll
    }

    func updateNSView(_ scroll: PromptScrollView, context: Context) {
        context.coordinator.parent = self
        let editor = scroll.editor
        if editor.string != text {
            editor.string = text
            scroll.invalidateIntrinsicContentSize()
        }
        if editor.textContainerInset.height != verticalInset {
            editor.textContainerInset = NSSize(width: 4, height: verticalInset)
            scroll.invalidateIntrinsicContentSize()
        }
        editor.setAccessibilityPlaceholderValue(placeholder)
        editor.pasteAttachment = { board in AttachmentPasteboard.paste(into: tray, from: board) }
        editor.onSubmit = onSubmit
        editor.onCancel = onCancel
        editor.onHoldToTalk = onHoldToTalk
        editor.onReleaseToSend = onReleaseToSend
        editor.onReleaseTooSoon = onReleaseTooSoon
        editor.needsDisplay = true
        if context.coordinator.focusToken != focusToken {
            context.coordinator.focusToken = focusToken
            editor.requestFocus()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PromptScrollView, context: Context) -> CGSize? {
        let width = max(40, proposal.width ?? 300)
        return CGSize(width: width, height: nsView.editorHeight(for: width))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PromptEditor
        weak var scroll: PromptScrollView?
        var focusToken: Int?

        init(parent: PromptEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? PromptTextView else { return }
            parent.text = editor.string
            editor.needsDisplay = true
            scroll?.invalidateIntrinsicContentSize()
        }
    }
}

final class PromptScrollView: NSScrollView {
    let editor = PromptTextView(frame: .zero)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        drawsBackground = false
        borderType = .noBorder
        // Long prompts still scroll (trackpad, caret); there's just no scroller drawn over the glass.
        hasVerticalScroller = false
        documentView = editor
        editor.minSize = NSSize(width: 0, height: 30)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Measures in a separate layout. SwiftUI probes several widths (some only 40pt wide)
    /// before settling; resizing the live text container for a probe left the text wrapping
    /// at that width, one word per line.
    func editorHeight(for width: CGFloat) -> CGFloat {
        let insets = 2 * editor.textContainerInset.height
        let storage = NSTextStorage(string: editor.string.isEmpty ? " " : editor.string,
                                    attributes: [.font: editor.font ?? .systemFont(ofSize: 15)])
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: max(1, width - 2 * editor.textContainerInset.width),
                                                     height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = editor.textContainer?.lineFragmentPadding ?? 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        // One line is 20pt; up to 100pt of text before it scrolls.
        return min(100, max(20, ceil(layout.usedRect(for: container).height))) + insets
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: editorHeight(for: max(40, bounds.width)))
    }
}

final class PromptTextView: NSTextView {
    var pasteAttachment: ((NSPasteboard) -> Bool)?
    var onSubmit: (() -> Void)?
    var onCancel: (() -> Void)?
    /// Return held down: start dictating.
    var onHoldToTalk: (() -> Void)?
    /// Return let go long enough after `onHoldToTalk`: send once the last words are in.
    var onReleaseToSend: (() -> Void)?
    /// Return let go too soon after `onHoldToTalk`: throw the recording away.
    var onReleaseTooSoon: (() -> Void)?
    private var wantsFocus = false

    /// The clipboard Cmd-V reads; tests substitute a private one.
    var pasteboard: NSPasteboard = .general

    override func paste(_ sender: Any?) { paste(from: pasteboard) }

    /// AppKit enables Edit > Paste (and so Cmd-V) only for clipboard types a plain-text
    /// view can read. Images and files attach instead, so they enable it too.
    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)), isEditable, AttachmentPasteboard.canAttach(from: pasteboard) {
            return true
        }
        return super.validateUserInterfaceItem(item)
    }

    /// The exact path used by Cmd-V and the Edit menu, injectable for regression tests.
    func paste(from board: NSPasteboard) {
        if pasteAttachment?(board) == true { return }
        if let text = board.string(forType: .string) {
            insertText(text, replacementRange: selectedRange())
        }
    }

    /// NSTextView accepts dropped files itself and inserts their paths. It sits on top of
    /// the SwiftUI drop target, so files and images attach here instead, like paste does.
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        AttachmentPasteboard.canAttach(from: sender.draggingPasteboard) ? .copy : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        AttachmentPasteboard.canAttach(from: sender.draggingPasteboard) ? .copy : super.draggingUpdated(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if pasteAttachment?(sender.draggingPasteboard) == true { return true }
        return super.performDragOperation(sender)
    }

    /// When a held Return starts the mic, and how long it must be held to send the speech.
    var holdTiming = HoldToTalk()
    /// Whether Return is physically down; tests stand in for the keyboard.
    var isReturnDown: () -> Bool = {
        CGEventSource.keyState(.combinedSessionState, key: 36) || CGEventSource.keyState(.combinedSessionState, key: 76)
    }
    private enum ReturnKey { case up, pressed(Task<Void, Never>), talking(since: ContinuousClock.Instant) }
    private var returnKey = ReturnKey.up

    /// Return sends when it's let go, not when it goes down. Held past `holdTiming.micDelay`
    /// it starts dictation; let go after `holdTiming.sendAfter` it sends what was said, and
    /// sooner it throws the recording away.
    override func keyDown(with event: NSEvent) {
        if Self.isReturn(event) {
            if !event.modifierFlags.intersection([.option, .shift]).isEmpty {
                super.insertNewline(nil)
            } else if !event.isARepeat {
                // A fresh press starts over, even if the last key-up went to another window.
                if case .pressed(let wait) = returnKey { wait.cancel() }
                let delay = holdTiming.micDelay
                returnKey = .pressed(Task { [weak self] in
                    try? await Task.sleep(for: delay)
                    guard !Task.isCancelled, let self, case .pressed = self.returnKey else { return }
                    // The key-up can get lost (the bar hid mid-press); never start the mic then.
                    guard self.isReturnDown() else { self.returnKey = .up; return }
                    self.returnKey = .talking(since: .now)
                    self.onHoldToTalk?()
                })
            }
            return
        }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        guard Self.isReturn(event) else { return super.keyUp(with: event) }
        let key = returnKey
        returnKey = .up
        switch key {
        case .up: break
        case .pressed(let wait):
            wait.cancel()
            onSubmit?()
        case .talking(let since):
            if ContinuousClock.now - since + holdTiming.micDelay >= holdTiming.sendAfter {
                onReleaseToSend?()
            } else {
                onReleaseTooSoon?()
            }
        }
    }

    /// Focus moved away mid-press, so the key-up won't come here: forget the press. Dictation
    /// already started keeps going; the mic button or ⌘⇧D stops it.
    override func resignFirstResponder() -> Bool {
        if case .pressed(let wait) = returnKey { wait.cancel() }
        returnKey = .up
        return super.resignFirstResponder()
    }

    private static func isReturn(_ event: NSEvent) -> Bool { event.keyCode == 36 || event.keyCode == 76 }

    override func insertNewline(_ sender: Any?) { onSubmit?() }
    override func cancelOperation(_ sender: Any?) { onCancel?() }

    func requestFocus() {
        wantsFocus = true
        if window != nil { focusWhenReady() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if wantsFocus { focusWhenReady() }
    }

    private func focusWhenReady() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
            self.wantsFocus = false
        }
    }
}

/// Hold Return to talk. A tap sends as always; the mic waits out a tap so its menu bar dot
/// doesn't flash on every send.
struct HoldToTalk {
    /// Held this long, Return starts the mic.
    var micDelay: Duration = .milliseconds(200)
    /// Let go after this long (from the press), the speech is sent; sooner, it's thrown away.
    var sendAfter: Duration = .seconds(2)
}
