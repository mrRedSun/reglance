import AppKit
import ChatCore
import Testing
@testable import Reglance

/// The prompt's NSTextView accepts file drags itself and, by default, inserts the file's
/// path as text. It sits on top of the SwiftUI drop target, so a dropped file never reached
/// the attachment tray. These drop a file straight onto the real editors in both windows.
@MainActor
@Suite(.serialized, .headlessWindows)
struct FileDropTests {

    private func expectDropAttachesFile(_ editor: PromptTextView) async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "drop-\(UUID()).txt")
        try "notes".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.writeObjects([file as NSURL])

        let tray = AttachmentTray()
        editor.pasteAttachment = { AttachmentPasteboard.paste(into: tray, from: $0) }
        editor.string = ""
        let drag = FakeDrag(pasteboard: board, window: editor.window)
        #expect(editor.draggingEntered(drag).contains(.copy))
        #expect(editor.performDragOperation(drag))
        await waitUntil { !tray.drafts.isEmpty }
        #expect(tray.drafts.count == 1)
        #expect(editor.string.isEmpty, "Dropped file inserted text: \(editor.string)")
    }

    @Test func droppingAFileOnTheFloatingPanelAttachesIt() async throws {
        _ = NSApplication.shared
        let controller = FloatingPanelController(chats: makeChats(), openInWindow: { _ in })
        defer { controller.hide() }
        #expect(await showSettled(controller))
        try await expectDropAttachesFile(try #require(await editor(in: controller.panel)))
    }

    @Test func droppingAFileOnTheChatsWindowAttachesIt() async throws {
        _ = NSApplication.shared
        let controller = MainWindowController(chats: makeChats())
        controller.show()
        defer { controller.window.performClose(nil) }
        try await expectDropAttachesFile(try #require(await editor(in: controller.window)))
    }
}

/// A drag from Finder, reduced to what a drop destination reads.
private final class FakeDrag: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingDestinationWindow: NSWindow?

    init(pasteboard: NSPasteboard, window: NSWindow?) {
        draggingPasteboard = pasteboard
        draggingDestinationWindow = window
    }

    var draggingSourceOperationMask: NSDragOperation { [.copy, .link, .generic] }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    func resetSpringLoading() {}
}
