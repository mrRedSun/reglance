import AppKit
import ChatCore
import Testing
@testable import Reglance

/// Sending grows the bar into a reply panel without replacing the composer or resizing the
/// window. How the spring looks is for the person to judge; this checks what must hold.
@MainActor
@Test(.headlessWindows) func sendingKeepsTheSameNativeComposerAndWindow() async throws {
    _ = NSApplication.shared
    let chats = makeChats(client: ScriptedClient(replying: "Hello.", session: "transition-test-session"))
    let controller = FloatingPanelController(chats: chats, openInWindow: { _ in })
    defer { controller.hide() }
    #expect(await showSettled(controller))
    let editor = try #require(await editor(in: controller.panel))
    let frame = controller.panel.frame

    controller.composer.text = "Hello"
    editor.onSubmit?()

    let id = try #require(controller.composer.chatID)
    await chats.waitForReply(id)
    #expect(chats.chat(id)?.messages.last?.text == "Hello.")
    controller.panel.contentView?.layoutSubtreeIfNeeded()
    #expect(controller.panel.frame == frame, "The glass grows inside the panel; the window never resizes")
    let root = try #require(controller.panel.contentView)
    let afterSend = try #require(findView(PromptTextView.self, in: root))
    #expect(afterSend === editor, "Sending must not destroy and replace the editor or its glass")
}
