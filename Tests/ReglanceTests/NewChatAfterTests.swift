import AppKit
import Testing
import ChatCore
@testable import Reglance

@Suite(.serialized, .headlessWindows)
@MainActor
struct NewChatAfterTests {
    private final class Clock { var now = Date(timeIntervalSince1970: 0) }

    private func makeController(limit: TimeInterval, clock: Clock) -> (FloatingPanelController, ComposerSession) {
        _ = NSApplication.shared
        let controller = FloatingPanelController(chats: makeChats(),
                                                 newChatAfter: { limit }, now: { clock.now },
                                                 openInWindow: { _ in })
        return (controller, controller.composer)
    }

    @Test func reopeningAfterTheLimitStartsANewChatAndKeepsTheDraft() {
        let clock = Clock()
        let (controller, bar) = makeController(limit: 300, clock: clock)
        controller.show()
        bar.chatID = UUID()
        bar.text = "half-written"
        controller.hide()
        clock.now += 300
        controller.show()
        defer { controller.hide() }
        #expect(bar.chatID == nil)
        #expect(bar.text == "half-written")
    }

    @Test func eachReopenRestartsTheTimer() {
        let clock = Clock()
        let (controller, bar) = makeController(limit: 300, clock: clock)
        controller.show()
        let chat = UUID()
        bar.chatID = chat
        controller.hide()
        clock.now += 240
        controller.show()
        #expect(bar.chatID == chat)
        controller.hide()
        clock.now += 240 // 480s since the first hide, but only 240s since the last.
        controller.show()
        defer { controller.hide() }
        #expect(bar.chatID == chat)
    }

    @Test func neverKeepsTheChat() {
        let clock = Clock()
        let (controller, bar) = makeController(limit: 0, clock: clock)
        controller.show()
        let chat = UUID()
        bar.chatID = chat
        controller.hide()
        clock.now += 24 * 60 * 60
        controller.show()
        defer { controller.hide() }
        #expect(bar.chatID == chat)
    }

    @Test func defaultIsFiveMinutes() throws {
        let defaults = try #require(UserDefaults(suiteName: "new-chat-after-\(UUID())"))
        #expect(NewChatAfter.current(in: defaults) == 300)
        defaults.set(0.0, forKey: NewChatAfter.defaultsKey)
        #expect(NewChatAfter.current(in: defaults) == 0)
    }
}
