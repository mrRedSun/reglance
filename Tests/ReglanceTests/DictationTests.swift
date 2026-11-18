import ChatCore
import Foundation
import Testing
@testable import Reglance

/// Plays back speech the test sends, instead of the microphone.
private final class ScriptedRecognizer: SpeechRecognizing {
    var failure: Error?
    private var continuation: AsyncThrowingStream<SpeechUpdate, Error>.Continuation?
    private(set) var stopped = false
    /// What the recognizer finishes after `stop()`, like the real one finalizing its last words.
    var lastWords: SpeechUpdate?

    func start() async throws -> AsyncThrowingStream<SpeechUpdate, Error> {
        if let failure { throw failure }
        let (stream, continuation) = AsyncThrowingStream<SpeechUpdate, Error>.makeStream()
        self.continuation = continuation
        return stream
    }

    func stop() async {
        stopped = true
        if let lastWords { continuation?.yield(lastWords) }
        continuation?.finish()
    }

    func say(_ text: String, final: Bool = false) {
        continuation?.yield(SpeechUpdate(text: text, isFinal: final))
    }
}

@Test func volatileSpeechIsReplacedAndFinalSpeechStays() {
    var text = DictationText(startingWith: "")
    #expect(text.apply(SpeechUpdate(text: "What's", isFinal: false), current: "") == "What's")
    #expect(text.apply(SpeechUpdate(text: "What's the weather", isFinal: false), current: "What's") == "What's the weather")
    #expect(text.apply(SpeechUpdate(text: "What's the weather?", isFinal: true), current: "What's the weather") == "What's the weather?")
    #expect(text.apply(SpeechUpdate(text: "In Lviv", isFinal: false), current: "What's the weather?") == "What's the weather? In Lviv")
}

@Test func dictationGoesAfterWhatWasTypedWithOneSpace() {
    var text = DictationText(startingWith: "Translate:")
    #expect(text.apply(SpeechUpdate(text: " good morning ", isFinal: true), current: "Translate:") == "Translate: good morning")
    var afterSpace = DictationText(startingWith: "Translate: ")
    #expect(afterSpace.apply(SpeechUpdate(text: "hi", isFinal: false), current: "Translate: ") == "Translate: hi")
}

@Test func anEditDuringDictationWinsAndLaterSpeechFollowsIt() {
    var text = DictationText(startingWith: "")
    _ = text.apply(SpeechUpdate(text: "Hello there", isFinal: true), current: "")
    _ = text.apply(SpeechUpdate(text: "my", isFinal: false), current: "Hello there")
    // The person fixes a word while the guess "my" is still showing.
    let edited = "Hello, there my"
    #expect(text.apply(SpeechUpdate(text: "my friend", isFinal: true), current: edited) == "Hello, there my friend")
}

@MainActor
@Suite struct DictationSessionTests {
    private func composer(with recognizer: ScriptedRecognizer) -> ComposerSession {
        ComposerSession(chats: makeChats(client: DemoClient(wordDelay: .zero)),
                        lastChoice: LastModelChoice(defaults: testDefaults()),
                        dictation: Dictation(makeRecognizer: { recognizer }))
    }

    @Test func speechFillsTheComposerAndStoppingKeepsTheLastWords() async {
        let recognizer = ScriptedRecognizer()
        let session = composer(with: recognizer)
        session.text = "Hi."
        session.toggleDictation()
        #expect(await waitUntil { session.dictation.state == .listening })
        recognizer.say("how are")
        #expect(await waitUntil { session.text == "Hi. how are" })

        session.toggleDictation()
        recognizer.say("how are you", final: true)
        await session.dictation.waitUntilDone()
        #expect(recognizer.stopped)
        #expect(session.dictation.state == .off)
        #expect(session.text == "Hi. how are you")
    }

    @Test func sendingStopsDictationAndLateWordsNeverReturn() async {
        let recognizer = ScriptedRecognizer()
        let session = composer(with: recognizer)
        session.toggleDictation()
        #expect(await waitUntil { session.dictation.state == .listening })
        recognizer.say("Tell me a joke")
        #expect(await waitUntil { session.text == "Tell me a joke" })

        session.send()
        #expect(session.dictation.state == .off)
        recognizer.say("Tell me a joke.", final: true)
        await session.dictation.waitUntilDone()
        #expect(session.text.isEmpty)
        #expect(session.chat?.messages.first?.text == "Tell me a joke")
    }

    @Test func aFailureShowsWhyAndTheNextStartClearsIt() async {
        let recognizer = ScriptedRecognizer()
        recognizer.failure = DictationError.noMicrophoneAccess
        let session = composer(with: recognizer)
        session.toggleDictation()
        await session.dictation.waitUntilDone()
        #expect(session.dictation.state == .off)
        #expect(session.dictation.error?.contains("microphone") == true)

        recognizer.failure = nil
        session.toggleDictation()
        #expect(session.dictation.error == nil)
        session.dictation.cancel()
    }

    @Test func releasingReturnWaitsForTheLastWordsBeforeSending() async {
        let recognizer = ScriptedRecognizer()
        let session = composer(with: recognizer)
        session.beginHoldToTalk()
        #expect(await waitUntil { session.dictation.state == .listening })
        recognizer.say("What time")
        #expect(await waitUntil { session.text == "What time" })
        recognizer.lastWords = SpeechUpdate(text: "What time is it?", isFinal: true)
        await session.endHoldToTalk()
        session.send()
        #expect(session.chat?.messages.first?.text == "What time is it?")
        #expect(session.text.isEmpty)
    }

    @Test func lettingGoTooSoonPutsTheTypedTextBack() async {
        let recognizer = ScriptedRecognizer()
        let session = composer(with: recognizer)
        session.text = "Typed"
        session.beginHoldToTalk()
        #expect(await waitUntil { session.dictation.state == .listening })
        recognizer.say("um")
        #expect(await waitUntil { session.text == "Typed um" })
        session.abandonHoldToTalk()
        #expect(session.dictation.state == .off)
        #expect(session.text == "Typed")
        #expect(session.chat == nil)
        #expect(await waitUntil { recognizer.stopped })
    }

    @Test func holdingReturnLeavesDictationFromTheShortcutAlone() async {
        let recognizer = ScriptedRecognizer()
        let session = composer(with: recognizer)
        session.toggleDictation()
        #expect(await waitUntil { session.dictation.state == .listening })
        recognizer.say("Already talking")
        #expect(await waitUntil { session.text == "Already talking" })
        session.beginHoldToTalk()
        session.abandonHoldToTalk()
        #expect(session.dictation.state == .listening)
        #expect(session.text == "Already talking")
        session.dictation.cancel()
    }

    @Test func aNewChatCancelsDictation() async {
        let recognizer = ScriptedRecognizer()
        let session = composer(with: recognizer)
        session.toggleDictation()
        #expect(await waitUntil { session.dictation.state == .listening })
        session.startNewChat()
        #expect(session.dictation.state == .off)
        #expect(await waitUntil { recognizer.stopped })
    }
}
