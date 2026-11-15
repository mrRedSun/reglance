import AppKit
import SwiftUI

/// A native editor handles both Cmd-V and Edit > Paste through the responder chain.
/// A local key monitor cannot reliably intercept SwiftUI's field editor on every OS.
struct PromptEditor: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let tray: AttachmentTray
    let focusToken: Int
    let onSubmit: () -> Void
    var onCancel: () -> Void = {}
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
        editor.placeholder = placeholder
        editor.pasteAttachment = { board in AttachmentPasteboard.paste(into: tray, from: board) }
        editor.onSubmit = onSubmit
        editor.onCancel = onCancel
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
        hasVerticalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
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
    var placeholder = ""
    var pasteAttachment: ((NSPasteboard) -> Bool)?
    var onSubmit: (() -> Void)?
    var onCancel: (() -> Void)?
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

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            if event.modifierFlags.intersection([.option, .shift]).isEmpty {
                onSubmit?()
            } else {
                super.insertNewline(nil)
            }
            return
        }
        super.keyDown(with: event)
    }

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

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        placeholder.draw(at: NSPoint(x: textContainerInset.width, y: textContainerInset.height), withAttributes: [
            .font: font ?? .systemFont(ofSize: 15),
            .foregroundColor: NSColor.placeholderTextColor,
        ])
    }
}
