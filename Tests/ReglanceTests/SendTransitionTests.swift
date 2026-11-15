import AppKit
import ChatCore
import Testing
@testable import Reglance

private struct TransitionTestClient: ClaudeStreamingClient {
    func send(_ content: [ContentBlock], model: ClaudeModel, effort: ClaudeEffort, resume sessionID: String?, agentDirectory: URL?) -> AsyncThrowingStream<ClaudeEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.session(id: "transition-test-session"))
            continuation.yield(.text("Hello."))
            continuation.yield(.finished(sessionID: "transition-test-session", fullText: "Hello."))
            continuation.finish()
        }
    }
}

@MainActor
@Test func sendingKeepsTheSameNativeComposerAndBottomAnchor() async throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appending(path: "send-transition-test-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let chats = ChatController(store: ChatStore(directory: directory), client: TransitionTestClient())
    let bar = FloatingBarModel()
    let controller = FloatingPanelController(chats: chats, model: bar, openInWindow: { _ in })
    controller.show()
    defer { controller.hide() }
    try await Task.sleep(for: .milliseconds(100))
    func findEditor(_ view: NSView) -> PromptTextView? {
        if let editor = view as? PromptTextView { return editor }
        return view.subviews.lazy.compactMap(findEditor).first
    }
    let root = try #require(controller.panel.contentView)
    let editor = try #require(findEditor(root))
    let originalFrame = controller.panel.frame
    let editorBottom = editor.convert(editor.bounds, to: nil).minY
    bar.text = "Hello"
    try await Task.sleep(for: .milliseconds(20))
    editor.onSubmit?()
    // The panel never resizes; the glass grows upward inside it. Every sampled frame keeps
    // the composer within the docked inset (about 9pt) of where it started, with no jump.
    var positions: [CGFloat] = []
    for _ in 0..<40 {
        try await Task.sleep(for: .milliseconds(12))
        #expect(controller.panel.frame == originalFrame)
        positions.append(editor.convert(editor.bounds, to: nil).minY)
    }
    #expect(positions.allSatisfy { abs($0 - editorBottom) < 12 }, "Composer moved: \(positions)")
    let afterSend = try #require(findEditor(root))
    #expect(afterSend === editor, "Sending must not destroy and replace the editor/glass hierarchy")
    #expect(chats.chat(bar.chatID)?.messages.last?.text == "Hello.")
}
