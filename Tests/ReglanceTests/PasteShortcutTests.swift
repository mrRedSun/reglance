import AppKit
import ChatCore
import Testing
@testable import Reglance

/// Cmd-V runs Edit > Paste from the menu bar. AppKit enables that item only when the text
/// view can read the clipboard, and a plain-text view can't read an image, so an image-only
/// clipboard left Paste disabled and Cmd-V did nothing. The test runner can't reliably
/// make a window key, so these check the menu validation and the action the menu sends.
@MainActor
@Suite(.serialized, .headlessWindows)
struct PasteShortcutTests {
    private func findEditor(_ view: NSView) -> PromptTextView? {
        (view as? PromptTextView) ?? view.subviews.lazy.compactMap(findEditor).first
    }

    private func imageOnlyPasteboard() -> NSPasteboard {
        let board = NSPasteboard.withUniqueName()
        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 8, height: 8).fill()
        image.unlockFocus()
        let png = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        board.setData(png, forType: .png)
        return board
    }

    private func expectPasteMenuAttachesImage(_ editor: PromptTextView) async {
        let board = imageOnlyPasteboard()
        defer { board.releaseGlobally() }
        editor.pasteboard = board
        let paste = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        #expect(editor.validateUserInterfaceItem(paste), "Paste must be enabled with an image on the clipboard")
        let tray = AttachmentTray()
        editor.pasteAttachment = { AttachmentPasteboard.paste(into: tray, from: $0) }
        editor.paste(paste)
        for _ in 0..<100 where tray.drafts.isEmpty {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(tray.drafts.count == 1)
    }

    @Test func pasteIsEnabledForImagesInTheFloatingPanel() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appending(path: "paste-key-test-\(UUID())")
        let controller = FloatingPanelController(chats: ChatController(store: ChatStore(directory: directory)),
                                                 openInWindow: { _ in })
        controller.show()
        defer { controller.hide() }
        try await Task.sleep(for: .milliseconds(150))
        let root = try #require(controller.panel.contentView)
        await expectPasteMenuAttachesImage(try #require(findEditor(root)))
    }

    @Test func pasteIsEnabledForImagesInTheChatsWindow() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appending(path: "paste-key-main-test-\(UUID())")
        let controller = MainWindowController(chats: ChatController(store: ChatStore(directory: directory)))
        controller.show()
        defer { controller.window.performClose(nil) }
        try await Task.sleep(for: .milliseconds(200))
        let root = try #require(controller.window.contentView)
        await expectPasteMenuAttachesImage(try #require(findEditor(root)))
    }
}
