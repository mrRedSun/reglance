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
        await waitUntil { !tray.drafts.isEmpty }
        #expect(tray.drafts.count == 1)
    }

    @Test func pasteIsEnabledForImagesInTheFloatingPanel() async throws {
        _ = NSApplication.shared
        let controller = FloatingPanelController(chats: makeChats(), openInWindow: { _ in })
        defer { controller.hide() }
        #expect(await showSettled(controller))
        await expectPasteMenuAttachesImage(try #require(await editor(in: controller.panel)))
    }

    @Test func pasteIsEnabledForImagesInTheChatsWindow() async throws {
        _ = NSApplication.shared
        let controller = MainWindowController(chats: makeChats())
        controller.show()
        defer { controller.window.performClose(nil) }
        await expectPasteMenuAttachesImage(try #require(await editor(in: controller.window)))
    }
}
