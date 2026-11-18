import AppKit
import Testing
import ChatCore
@testable import Reglance

@Suite(.serialized, .headlessWindows)
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
        await waitUntil { !tray.drafts.isEmpty }
        #expect(tray.drafts.count == 1)
        #expect(tray.drafts.first?.kind == .image)
    }

    @Test func floatingHostingViewDoesNotClipGlass() {
        _ = NSApplication.shared
        let chats = makeChats()
        let controller = FloatingPanelController(chats: chats, openInWindow: { _ in })
        #expect(controller.panel.contentView?.clipsToBounds == false)
    }

    @Test func collapsedPanelHasAnActualDragRegion() async throws {
        _ = NSApplication.shared
        let chats = makeChats()
        let controller = FloatingPanelController(chats: chats, openInWindow: { _ in })
        defer { controller.hide() }
        #expect(await showSettled(controller))
        func hasDragRegion(_ view: NSView) -> Bool {
            (view is WindowDragView && view.bounds.width > 0 && view.bounds.height > 0)
                || view.subviews.contains(where: hasDragRegion)
        }
        #expect(controller.panel.contentView.map(hasDragRegion) == true)
        // Empty glass beside the text (the leading inset, mid-height) moves the window.
        let hosting = try #require(controller.panel.contentView)
        let text = try #require(await editor(in: controller.panel))
        let textFrame = text.convert(text.bounds, to: hosting)
        let inset = NSPoint(x: textFrame.minX - 6, y: textFrame.midY)
        #expect(hosting.hitTest(hosting.convert(inset, to: hosting.superview)) is WindowDragView,
                "Leading glass inset should drag, got \(String(describing: hosting.hitTest(inset)))")
    }

    @Test func expandedPanelDragsByItsTitle() async throws {
        _ = NSApplication.shared
        let chats = makeChats(client: ScriptedClient(replying: "Sure.", session: "title-drag-test"))
        let controller = FloatingPanelController(chats: chats, openInWindow: { _ in })
        controller.composer.chatID = chats.send("Plan a weekend trip to the mountains", model: .sonnet, to: nil)
        await chats.waitForReply(try #require(controller.composer.chatID))
        defer { controller.hide() }
        #expect(await showSettled(controller))
        let hosting = try #require(controller.panel.contentView)
        // The drag region backs the whole glass; the title starts 22pt in, centred in a
        // 26pt row 14pt below the top edge.
        let region = try #require(findView(WindowDragView.self, in: hosting))
        let glass = region.convert(region.bounds, to: nil)
        let title = NSPoint(x: glass.minX + 40, y: glass.maxY - 27)
        let hit = hosting.hitTest(hosting.superview!.convert(title, from: nil))
        #expect(hit is WindowDragView, "Title should drag the panel, got \(String(describing: hit))")
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
        await waitUntil { !tray.isPreparing }
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
            editor.keyDown(with: returnKey(.keyDown, modifiers))
            editor.keyUp(with: returnKey(.keyUp, modifiers))
        }
        editor.keyDown(with: returnKey(.keyDown))
        #expect(submits == 0, "sends on release, so a hold can turn into dictation")
        editor.keyUp(with: returnKey(.keyUp))
        #expect(submits == 1)
        #expect(editor.string.isEmpty)
        pressReturn(.shift)
        pressReturn(.option)
        #expect(submits == 1)
        #expect(editor.string == "\n\n")
    }

    @Test func holdToTalkWaitsOutATapAndSendsAfterTwoSeconds() {
        let timing = PromptTextView().holdTiming
        #expect(timing.micDelay == .milliseconds(200))
        #expect(timing.sendAfter == .seconds(2))
    }

    /// An editor with fast hold-to-talk timing that records what Return asked for.
    private final class ReturnLog {
        let editor = PromptTextView(frame: NSRect(x: 0, y: 0, width: 280, height: 40))
        var calls: [String] = []

        init(keyIsDown: Bool = true) {
            _ = NSApplication.shared
            editor.holdTiming = HoldToTalk(micDelay: .milliseconds(20), sendAfter: .milliseconds(120))
            editor.isReturnDown = { keyIsDown }
            editor.onSubmit = { [unowned self] in calls.append("submit") }
            editor.onHoldToTalk = { [unowned self] in calls.append("talk") }
            editor.onReleaseToSend = { [unowned self] in calls.append("send speech") }
            editor.onReleaseTooSoon = { [unowned self] in calls.append("too soon") }
        }

        func press() { editor.keyDown(with: returnKey(.keyDown)) }
        func release() { editor.keyUp(with: returnKey(.keyUp)) }
    }

    @Test func aTapSendsWithoutTouchingTheMic() async throws {
        let log = ReturnLog()
        log.press()
        log.release()
        try await Task.sleep(for: .milliseconds(60))
        #expect(log.calls == ["submit"])
    }

    @Test func holdingReturnTalksAndAFullHoldSendsTheSpeech() async throws {
        let log = ReturnLog()
        log.press()
        log.editor.keyDown(with: returnKey(.keyDown, repeat: true))
        #expect(await waitUntil { log.calls == ["talk"] })
        log.editor.keyDown(with: returnKey(.keyDown, repeat: true))
        try await Task.sleep(for: .milliseconds(150))
        log.release()
        #expect(log.calls == ["talk", "send speech"])
    }

    @Test func lettingGoTooSoonThrowsTheRecordingAway() async {
        let log = ReturnLog()
        log.press()
        #expect(await waitUntil { log.calls == ["talk"] })
        log.release()
        #expect(log.calls == ["talk", "too soon"])
    }

    @Test func aLostReleaseNeverStartsTheMic() async throws {
        let log = ReturnLog(keyIsDown: false)
        log.press()
        try await Task.sleep(for: .milliseconds(60))
        #expect(log.calls.isEmpty)
        // Return still works as a tap afterwards.
        log.press()
        log.release()
        #expect(log.calls == ["submit"])
    }

    @Test func nativeChatsWindowHasDockPresenceAndCanCloseAndReopen() {
        _ = NSApplication.shared
        let controller = MainWindowController(chats: makeChats())
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
        // The image keeps preparing in the background; its result must not come back.
        try? await Task.sleep(for: .milliseconds(300))
        #expect(tray.drafts.isEmpty)
        #expect(!tray.isPreparing)
    }

    @Test func sidebarIsAlwaysShownAtAReadableWidth() async throws {
        _ = NSApplication.shared
        let controller = MainWindowController(chats: makeChats())
        controller.show()
        let window = controller.window
        defer { window.performClose(nil) }
        let root = try #require(window.contentView)
        var found: NSSplitViewItem?
        await waitUntil {
            window.layoutIfNeeded()
            let controller = findView(NSSplitView.self, in: root)?.delegate as? NSSplitViewController
            found = controller?.splitViewItems.first { $0.behavior == .sidebar }
            return (found?.viewController.view.frame.width ?? 0) >= SidebarLayout.minimumWidth
        }
        let sidebar = try #require(found)
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
        let store = ChatStore(directory: testDirectory("toolbar"))
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
        let toolbar = try #require(window.toolbar)
        #expect(await waitUntil { toolbar.items.contains { $0.itemIdentifier.rawValue == "newChat" && $0.view?.window != nil } })
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
        func expectStationaryToolbar() {
            window.layoutIfNeeded()
            #expect(buttonFrames().count == 1)
            expectCenteredTitleAndClearance()
        }
        expectStationaryToolbar()

        controller.show(chatID: chat.id)
        #expect(await waitUntil { titleView.stringValue == chat.title })
        #expect(titleView.toolTip == chat.title)
        #expect(titleView.lineBreakMode == .byTruncatingMiddle)
        #expect(titleView.maximumNumberOfLines == 1)
        #expect(titleView.fittingSize.width > titleView.bounds.width, "Exercise actual truncation, not just a short label")
        for width: CGFloat in [900, 1120] {
            window.setContentSize(NSSize(width: width, height: 620))
            expectStationaryToolbar()
        }
        chats.rename(chat.id, to: "Renamed conversation")
        #expect(await waitUntil { titleView.stringValue == "Renamed conversation" })
        expectStationaryToolbar()
        window.performClose(nil)
        controller.newChat()
        #expect(await waitUntil { titleView.stringValue == "New Chat" })
        expectStationaryToolbar()
    }

    @Test func barEntranceKeepsItsWindowStableAndCancelsStaleShows() async throws {
        _ = NSApplication.shared
        let controller = FloatingPanelController(chats: makeChats(), openInWindow: { _ in })
        controller.show()
        controller.hide() // Hide before the queued entrance starts.
        await Task.yield() // Let the queued entrance run; it must see it's stale.
        #expect(!controller.isPresented && !controller.isVisible)
        controller.show()
        defer { controller.hide() }
        let frame = controller.panel.frame
        #expect(await waitUntil { controller.isPresented })
        #expect(controller.panel.frame == frame, "Presenting grows the glass inside the window, not the window")
        controller.show() // Refocus, not another entrance.
        #expect(controller.isPresented)
        controller.hide()
        #expect(!controller.isPresented)
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

private func returnKey(_ type: NSEvent.EventType, _ modifiers: NSEvent.ModifierFlags = [], repeat: Bool = false) -> NSEvent {
    NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
                     characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: `repeat`, keyCode: 36)!
}
