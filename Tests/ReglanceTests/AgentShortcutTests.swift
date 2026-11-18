import AppKit
import ChatCore
import Testing
@testable import Reglance

/// "/" first turns agent mode on; Delete in an empty composer turns it off again.
@MainActor
@Suite(.headlessWindows)
struct AgentShortcutTests {
    private func composer(agreeing: Bool = true, chats: ChatController = makeChats()) -> ComposerSession {
        let composer = makeComposer(chats: chats)
        composer.confirmAgentMode = { agreeing }
        return composer
    }

    @Test func slashInAnEmptyComposerTurnsAgentModeOn() {
        let composer = composer()
        #expect(composer.slashTypedFirst())
        #expect(composer.agentDirectory != nil)
        #expect(composer.text.isEmpty)
    }

    @Test func slashIsTypedWhenAgentModeIsDeclinedOrAlreadyOnOrTextComesFirst() {
        let declined = composer(agreeing: false)
        #expect(!declined.slashTypedFirst())
        #expect(declined.agentDirectory == nil)

        let on = composer()
        on.agentDirectory = testDirectory()
        #expect(!on.slashTypedFirst(), "A slash in agent mode is just a slash")

        let typing = composer()
        typing.text = "a"
        #expect(!typing.slashTypedFirst())
        #expect(typing.agentDirectory == nil)
    }

    @Test func deleteInAnEmptyComposerTurnsAgentModeOff() {
        let composer = composer()
        composer.agentDirectory = testDirectory()
        #expect(composer.deleteInEmptyComposer())
        #expect(composer.agentDirectory == nil)
        #expect(!composer.deleteInEmptyComposer(), "Already off: Delete does nothing more")
    }

    @Test func deleteKeepsAgentModeWithTextOrAnOpenAgentChat() async {
        let typing = composer()
        typing.agentDirectory = testDirectory()
        typing.text = "a"
        #expect(!typing.deleteInEmptyComposer())
        #expect(typing.agentDirectory != nil)

        let chats = makeChats(client: DemoClient(wordDelay: .zero))
        let agent = chats.send("List the files", model: .sonnet, agentDirectory: testDirectory("agent"), to: nil)
        await chats.waitForReply(agent)
        let open = composer(chats: chats)
        open.open(agent)
        #expect(!open.deleteInEmptyComposer())
        #expect(open.chatID == agent, "Delete never leaves a conversation")
    }

    @Test func onlyTypedKeysInAnEmptyEditorReachTheShortcuts() {
        _ = NSApplication.shared
        let editor = PromptTextView(frame: NSRect(x: 0, y: 0, width: 280, height: 40))
        editor.isEditable = true
        var slashTaken = true, slashes = 0, deletes = 0
        editor.onSlashFirst = { slashes += 1; return slashTaken }
        editor.onDeleteWhenEmpty = { deletes += 1; return true }

        editor.keyDown(with: key("/", keyCode: 44))
        #expect(slashes == 1 && editor.string.isEmpty, "Taken: the slash isn't typed")
        slashTaken = false
        editor.keyDown(with: key("/", keyCode: 44))
        #expect(slashes == 2 && editor.string == "/", "Declined: the slash is typed")
        editor.keyDown(with: key("/", keyCode: 44))
        #expect(slashes == 2, "Only the first character counts")

        editor.string = ""
        editor.keyDown(with: key("\u{7F}", keyCode: 51, repeat: true))
        #expect(deletes == 0, "Holding Delete to clear the text stops at empty")
        editor.keyDown(with: key("\u{7F}", keyCode: 51))
        #expect(deletes == 1)

        editor.insertText("/", replacementRange: editor.selectedRange())
        #expect(slashes == 2 && editor.string == "/", "Pasted or dictated text isn't a shortcut")
    }
}

private func key(_ characters: String, keyCode: UInt16, repeat: Bool = false) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                     characters: characters, charactersIgnoringModifiers: characters, isARepeat: `repeat`, keyCode: keyCode)!
}
