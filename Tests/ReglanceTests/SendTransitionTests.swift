import AppKit
import ChatCore
import Testing
@testable import Reglance

private struct TransitionTestClient: ChatStreamingClient {
    func send(_ content: [ContentBlock], model: ChatModel, effort: Effort, resume sessionID: String?, agentDirectory: URL?, permissions: AgentPermissions) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.session(id: "transition-test-session"))
            continuation.yield(.text("Hello."))
            continuation.yield(.finished(sessionID: "transition-test-session"))
            continuation.finish()
        }
    }
}

@MainActor
@Test(.headlessWindows) func sendingKeepsTheSameNativeComposerAndBottomAnchor() async throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appending(path: "send-transition-test-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let chats = ChatController(store: ChatStore(directory: directory), client: TransitionTestClient())
    let bar = FloatingBarModel()
    let controller = FloatingPanelController(chats: chats, model: bar, openInWindow: { _ in })
    controller.show()
    defer { controller.hide() }
    func findEditor(_ view: NSView) -> PromptTextView? {
        if let editor = view as? PromptTextView { return editor }
        return view.subviews.lazy.compactMap(findEditor).first
    }
    let root = try #require(controller.panel.contentView)
    let editor = try #require(findEditor(root))
    // Wait out the entrance bloom so it doesn't read as the composer moving: until the
    // editor starts rising (that can take a few hundred ms in the full suite), then until
    // it holds still for 100ms. Fixed waits were flaky on a busy machine.
    let deadline = ContinuousClock.now + .seconds(3)
    let start = editor.convert(editor.bounds, to: nil).minY
    while abs(editor.convert(editor.bounds, to: nil).minY - start) < 2, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(16))
    }
    var editorBottom = editor.convert(editor.bounds, to: nil).minY
    var stillSince = ContinuousClock.now
    while ContinuousClock.now - stillSince < .milliseconds(100), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(16))
        let bottom = editor.convert(editor.bounds, to: nil).minY
        if abs(bottom - editorBottom) > 0.25 { stillSince = .now }
        editorBottom = bottom
    }
    let originalFrame = controller.panel.frame
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
    #expect(positions.allSatisfy { abs($0 - editorBottom) < 12 }, "Composer moved from \(editorBottom): \(positions)")
    let afterSend = try #require(findEditor(root))
    #expect(afterSend === editor, "Sending must not destroy and replace the editor/glass hierarchy")
    #expect(chats.chat(bar.chatID)?.messages.last?.text == "Hello.")
}
