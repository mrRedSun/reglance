import AppKit
import ChatCore
import Testing
@testable import Reglance

@MainActor
/// SwiftUI measures the field at narrow widths before settling. Measuring must not leave
/// the text wrapping at a probe width (it wrapped one word per line in the chats window).
@Test(.headlessWindows) func chatsWindowTextUsesTheFieldWidth() async throws {
    _ = NSApplication.shared
    let controller = MainWindowController(chats: makeChats())
    controller.show()
    defer { controller.window.performClose(nil) }
    try await Task.sleep(for: .milliseconds(200))
    let root = try #require(controller.window.contentView)
    let editor = try #require(findView(PromptTextView.self, in: root))
    let scroll = try #require(editor.enclosingScrollView)
    editor.insertText("Which dogs can't bark and why do they yodel", replacementRange: editor.selectedRange())
    try await Task.sleep(for: .milliseconds(100))
    // SwiftUI measured the field at 40pt first; the text must still wrap at its real width.
    let container = editor.textContainer?.containerSize.width ?? 0
    #expect(container >= editor.frame.width - 2 * editor.textContainerInset.width - 1,
            "Text wraps at \(container)pt in a \(editor.frame.width)pt field")
    #expect(editor.frame.width >= scroll.contentView.frame.width - 1)
    #expect(scroll.frame.width > 300)
    #expect(scroll.frame.height < 60, "One line of text must stay one line")
}
