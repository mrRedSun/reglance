import AppKit
import Testing
import ChatCore
@testable import Reglance

@Suite(.serialized)
@MainActor
struct WindowAndPasteTests {
    private func imagePasteboard(withText: Bool = false) -> NSPasteboard {
        let board = NSPasteboard.withUniqueName()
        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 8, height: 8).fill()
        image.unlockFocus()
        board.setData(image.tiffRepresentation!, forType: .tiff)
        if withText { board.setString("Screenshot", forType: .string) }
        return board
    }

    @Test func imageWithTextRepresentationStillAttaches() async {
        _ = NSApplication.shared
        let board = imagePasteboard(withText: true)
        defer { board.releaseGlobally() }
        let tray = AttachmentTray()
        #expect(AttachmentPasteboard.paste(into: tray, from: board))
        for _ in 0..<100 where tray.drafts.isEmpty {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(tray.drafts.count == 1)
        #expect(tray.drafts.first?.kind == .image)
    }

    @Test func floatingHostingViewDoesNotClipGlass() {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appending(path: "window-test-\(UUID())")
        let chats = ChatController(store: ChatStore(directory: directory))
        let controller = FloatingPanelController(chats: chats, openInWindow: { _ in })
        #expect(controller.panel.contentView?.clipsToBounds == false)
    }

    @Test func collapsedPanelHasAnActualDragRegion() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appending(path: "drag-test-\(UUID())")
        let chats = ChatController(store: ChatStore(directory: directory))
        let controller = FloatingPanelController(chats: chats, openInWindow: { _ in })
        controller.show()
        defer { controller.hide() }
        // Wait out the entrance bloom, which scales the bar while it plays.
        try? await Task.sleep(for: .milliseconds(700))
        controller.panel.contentView?.layoutSubtreeIfNeeded()
        func hasDragRegion(_ view: NSView) -> Bool {
            (view is WindowDragView && view.bounds.width > 0 && view.bounds.height > 0)
                || view.subviews.contains(where: hasDragRegion)
        }
        #expect(controller.panel.contentView.map(hasDragRegion) == true)
        // Empty glass beside the text (the leading inset, mid-height) moves the window.
        let hosting = try #require(controller.panel.contentView)
        func editor(_ view: NSView) -> PromptTextView? {
            (view as? PromptTextView) ?? view.subviews.lazy.compactMap(editor).first
        }
        let text = try #require(editor(hosting))
        let textFrame = text.convert(text.bounds, to: hosting)
        let inset = NSPoint(x: textFrame.minX - 6, y: textFrame.midY)
        #expect(hosting.hitTest(hosting.convert(inset, to: hosting.superview)) is WindowDragView,
                "Leading glass inset should drag, got \(String(describing: hosting.hitTest(inset)))")
    }

    @Test func nativeEditorPastesImagesAndTextThroughTheResponderPath() async {
        _ = NSApplication.shared
        let board = imagePasteboard(withText: true)
        defer { board.releaseGlobally() }
        let tray = AttachmentTray()
        let editor = PromptTextView(frame: NSRect(x: 0, y: 0, width: 280, height: 40))
        editor.isEditable = true
        editor.string = "Question"
        editor.pasteAttachment = { AttachmentPasteboard.paste(into: tray, from: $0) }
        editor.paste(from: board)
        #expect(tray.isPreparing)
        for _ in 0..<100 where tray.isPreparing {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(tray.drafts.count == 1)
        #expect(editor.string == "Question")
        board.clearContents()
        board.setString(" follow-up", forType: .string)
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        editor.paste(from: board)
        #expect(editor.string == "Question follow-up")
        #expect(tray.drafts.count == 1)
    }

    @Test func returnSubmitsAndModifiedReturnInsertsNewline() {
        _ = NSApplication.shared
        let editor = PromptTextView(frame: NSRect(x: 0, y: 0, width: 280, height: 40))
        editor.isEditable = true
        var submits = 0
        editor.onSubmit = { submits += 1 }
        func pressReturn(_ modifiers: NSEvent.ModifierFlags) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                        timestamp: 0, windowNumber: 0, context: nil,
                                        characters: "\r", charactersIgnoringModifiers: "\r",
                                        isARepeat: false, keyCode: 36)!
            editor.keyDown(with: event)
        }
        pressReturn([])
        #expect(submits == 1)
        #expect(editor.string.isEmpty)
        pressReturn(.shift)
        pressReturn(.option)
        #expect(submits == 1)
        #expect(editor.string == "\n\n")
    }

    @Test func nativeChatsWindowHasDockPresenceAndCanCloseAndReopen() {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appending(path: "main-window-test-\(UUID())")
        let controller = MainWindowController(chats: ChatController(store: ChatStore(directory: directory)))
        controller.show()
        #expect(NSApp.activationPolicy() == .regular)
        #expect(controller.isVisible)
        let window = controller.window
        #expect(window.styleMask.contains([.closable, .miniaturizable, .resizable]))
        #expect(window.contentMinSize.width >= 900 && window.contentMinSize.height >= 620)
        window.performClose(nil)
        #expect(!controller.isVisible)
        controller.show()
        #expect(controller.isVisible)
        window.performClose(nil)
    }

    @Test func resettingComposerDoesNotCarryPendingImagesIntoNextChat() async {
        let board = imagePasteboard()
        defer { board.releaseGlobally() }
        let tray = AttachmentTray()
        _ = AttachmentPasteboard.paste(into: tray, from: board)
        _ = tray.take()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(tray.drafts.isEmpty)
        #expect(!tray.isPreparing)
    }

    @Test func sidebarIsAlwaysShownAtAReadableWidth() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appending(path: "sidebar-layout-test-\(UUID())")
        let controller = MainWindowController(chats: ChatController(store: ChatStore(directory: directory)))
        controller.show()
        let window = controller.window
        defer { window.performClose(nil) }
        try await Task.sleep(for: .milliseconds(100))
        func findSplit(in view: NSView) -> NSSplitView? {
            if let split = view as? NSSplitView { return split }
            return view.subviews.lazy.compactMap { findSplit(in: $0) }.first
        }
        let root = try #require(window.contentView)
        let split = try #require(findSplit(in: root))
        let nativeController = try #require(split.delegate as? NSSplitViewController)
        let sidebar = try #require(nativeController.splitViewItems.first { $0.behavior == .sidebar })
        #expect(!sidebar.canCollapse, "The sidebar can't be hidden")
        #expect(window.tabbingMode == .disallowed, "No window tabs, so no Show Tab Bar or New Tab button")
        #expect(!sidebar.isCollapsed)
        #expect(sidebar.minimumThickness == SidebarLayout.minimumWidth)
        #expect(sidebar.viewController.view.frame.width >= SidebarLayout.minimumWidth)
        let toolbarLabels = window.toolbar?.items.map(\.label) ?? []
        #expect(!toolbarLabels.contains { $0.lowercased().contains("sidebar") }, "No sidebar toggle in the toolbar")
    }

    @Test func toolbarTitleIsCenteredAndClearOfNewChat() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appending(path: "toolbar-test-\(UUID())")
        let store = ChatStore(directory: directory)
        var chat = Chat(firstMessage: "A saved conversation", model: .sonnet)
        chat.title = String(repeating: "A long conversation title that needs truncation. ", count: 12)
        try store.save(chat)
        let chats = ChatController(store: store)
        let controller = MainWindowController(chats: chats)
        controller.show()
        let window = controller.window
        let originalWindowFrame = window.frame
        defer {
            window.setFrame(originalWindowFrame, display: true)
            window.performClose(nil)
        }
        try await Task.sleep(for: .milliseconds(120))
        let toolbar = try #require(window.toolbar)
        func buttonFrames() -> [String: NSRect] {
            Dictionary(toolbar.items.compactMap { item in
                let role: String
                guard item.itemIdentifier.rawValue == "newChat" else { return nil }
                role = "newChat"
                guard let view = item.view else { return nil }
                return (role, view.convert(view.bounds, to: nil))
            }, uniquingKeysWith: { first, _ in first })
        }
        #expect(toolbar.items.filter { $0.itemIdentifier.rawValue == "newChat" }.count == 1)
        func findTitle(_ view: NSView) -> NSTextField? {
            if let label = view as? NSTextField, label.identifier?.rawValue == "conversationTitle" { return label }
            return view.subviews.lazy.compactMap(findTitle).first
        }
        let titleView = try #require(window.titlebarAccessoryViewControllers.lazy.compactMap { findTitle($0.view) }.first)
        #expect(titleView.stringValue == "New Chat")
        #expect(!titleView.isHiddenOrHasHiddenAncestor)
        #expect(!titleView.isEditable && !titleView.isSelectable)
        #expect(titleView.mouseDownCanMoveWindow, "The title must remain a native window drag target")
        func expectCenteredTitleAndClearance() {
            let frame = titleView.convert(titleView.bounds, to: nil)
            #expect(abs(frame.midX - window.frame.width / 2) <= 1, "The title must be centered in the window, not in the detail column")
            #expect(frame.height > 0 && frame.width > 0)
            for button in buttonFrames().values {
                #expect(frame.maxX + 12 <= button.minX, "Even a truncated title must leave space for the trailing buttons")
                #expect(abs(frame.midY - button.midY) <= 1, "Keep the title in the native toolbar row")
            }
            if let trailing = buttonFrames()["newChat"] {
                #expect((0...24).contains(window.frame.width - trailing.maxX), "Keep the actions at the window's upper-right edge")
            }
            if let zoom = window.standardWindowButton(.zoomButton) {
                #expect(frame.minX >= zoom.convert(zoom.bounds, to: nil).maxX + 12)
            }
        }
        func expectStationaryToolbar() async throws {
            #expect(buttonFrames().count == 1)
            expectCenteredTitleAndClearance()
        }
        try await expectStationaryToolbar()

        controller.show(chatID: chat.id)
        try await Task.sleep(for: .milliseconds(100))
        #expect(titleView.stringValue == chat.title)
        #expect(titleView.toolTip == chat.title)
        #expect(titleView.lineBreakMode == .byTruncatingMiddle)
        #expect(titleView.maximumNumberOfLines == 1)
        #expect(titleView.fittingSize.width > titleView.bounds.width, "Exercise actual truncation, not just a short label")
        for width: CGFloat in [900, 1120] {
            window.setContentSize(NSSize(width: width, height: 620))
            try await Task.sleep(for: .milliseconds(80))
            try await expectStationaryToolbar()
        }
        chats.rename(chat.id, to: "Renamed conversation")
        try await Task.sleep(for: .milliseconds(80))
        #expect(titleView.stringValue == "Renamed conversation")
        expectCenteredTitleAndClearance()
        window.performClose(nil)
        controller.newChat()
        try await Task.sleep(for: .milliseconds(80))
        #expect(titleView.stringValue == "New Chat")
        expectCenteredTitleAndClearance()
    }

    @Test func barEntranceKeepsItsWindowStableAndCancelsStaleShows() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appending(path: "bar-motion-test-\(UUID())")
        let bar = FloatingBarModel()
        let controller = FloatingPanelController(chats: ChatController(store: ChatStore(directory: directory)),
                                                 model: bar, openInWindow: { _ in })
        controller.show()
        controller.hide() // Hide before the queued entrance starts.
        try await Task.sleep(for: .milliseconds(30))
        #expect(!bar.isPresented && !controller.isVisible)
        controller.show()
        defer { controller.hide() }
        try await Task.sleep(for: .milliseconds(60))
        #expect(bar.isPresented)
        let frame = controller.panel.frame
        for _ in 0..<22 {
            try await Task.sleep(for: .milliseconds(16))
            #expect(controller.panel.frame == frame, "The spring must not resize or move the window each frame")
        }
        controller.show() // Refocus, not another entrance.
        #expect(bar.isPresented)
        controller.hide()
        #expect(!bar.isPresented)
    }

    @Test func motionRespectsReduceMotion() {
        #expect(FloatingPanelMotion.scale(isPresented: false, reduceMotion: true) == CGSize(width: 1, height: 1))
        #expect(FloatingPanelMotion.scale(isPresented: true, reduceMotion: false) == CGSize(width: 1, height: 1))
        let start = FloatingPanelMotion.scale(isPresented: false, reduceMotion: false)
        #expect(start.width < 1 && start.height < 1)
        // The chats sidebar uses AppKit's standard slide, which follows Reduce Motion itself.
    }

    @Test func plainTextDoesNotBecomeAnAttachment() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("hello", forType: .string)
        #expect(!AttachmentPasteboard.paste(into: AttachmentTray(), from: board))
    }
}
