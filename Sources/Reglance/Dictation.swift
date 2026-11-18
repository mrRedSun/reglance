import AVFoundation
import Observation
import Speech

/// Recognized speech. Volatile text is a guess the next update replaces; final text stays.
struct SpeechUpdate: Sendable, Equatable {
    var text: String
    var isFinal: Bool
}

/// Turns microphone audio into text. `SpeechRecognizer` is the live one; tests script one.
protocol SpeechRecognizing: AnyObject {
    /// Starts listening. Updates arrive until `stop()`, which lets the last words finish
    /// before the stream ends.
    func start() async throws -> AsyncThrowingStream<SpeechUpdate, Error>
    func stop() async
}

/// Keeps a composer's text in step with dictation: what was there before, the speech
/// already final, and the current guess, which the next update replaces.
struct DictationText {
    /// The text before dictation started (or the person's last edit) plus final speech.
    private var base: String
    private var volatile = ""
    /// What dictation last put in the composer.
    private(set) var written: String

    init(startingWith text: String) {
        base = text
        written = text
    }

    /// The composer's text after `update`. `current` is the text now: if the person edited
    /// it while dictating, their edit wins and later speech goes after it.
    mutating func apply(_ update: SpeechUpdate, current: String) -> String {
        if current != written {
            // Keep their edit, minus the guess still at its end.
            base = !volatile.isEmpty && current.hasSuffix(volatile) ? String(current.dropLast(volatile.count)) : current
            volatile = ""
        }
        let piece = update.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if update.isFinal {
            base = Self.join(base, piece)
            volatile = ""
        } else {
            volatile = piece
        }
        written = Self.join(base, volatile)
        return written
    }

    /// Joins with one space, unless either side is empty or already ends in whitespace.
    static func join(_ head: String, _ tail: String) -> String {
        guard !tail.isEmpty else { return head }
        guard let last = head.last else { return tail }
        return last.isWhitespace ? head + tail : head + " " + tail
    }
}

/// Dictation for one composer: the mic button and ⌘⇧D start and stop it, and the words go
/// into the composer's text as they're recognized.
@Observable
final class Dictation {
    enum State: Equatable { case off, starting, listening }

    private(set) var state: State = .off
    /// Why the last dictation stopped early (no microphone access, language not supported).
    private(set) var error: String?

    @ObservationIgnored private let makeRecognizer: () -> any SpeechRecognizing
    @ObservationIgnored private var recognizer: (any SpeechRecognizing)?
    @ObservationIgnored private var task: Task<Void, Never>?

    init(makeRecognizer: @escaping () -> any SpeechRecognizing = { SpeechRecognizer() }) {
        self.makeRecognizer = makeRecognizer
    }

    var isActive: Bool { state != .off }

    /// Starts listening. Each update reads the composer's text with `text` and writes the
    /// merged result with `write`.
    func start(text: @escaping () -> String, write: @escaping (String) -> Void) {
        guard state == .off else { return }
        error = nil
        state = .starting
        let recognizer = makeRecognizer()
        self.recognizer = recognizer
        let initial = text()
        task = Task { [weak self] in
            var merge = DictationText(startingWith: initial)
            do {
                let updates = try await recognizer.start()
                guard self?.recognizer === recognizer else { return await recognizer.stop() }
                self?.state = .listening
                for try await update in updates {
                    // Cancelled: a send or new chat took the text; late words must not return.
                    guard self?.recognizer === recognizer else { break }
                    write(merge.apply(update, current: text()))
                }
            } catch {
                if self?.recognizer === recognizer { self?.error = Self.message(for: error) }
            }
            guard let self, self.recognizer === recognizer else { return }
            self.recognizer = nil
            self.state = .off
        }
    }

    /// Stops listening; the words still being recognized land in the text.
    func finish() {
        guard let recognizer else { return }
        if state == .starting { return cancel() }
        Task { await recognizer.stop() }
    }

    /// Stops at once and drops anything still being recognized.
    func cancel() {
        guard let recognizer else { return }
        self.recognizer = nil
        state = .off
        task?.cancel()
        Task { await recognizer.stop() }
    }

    /// Waits for the current dictation to end.
    func waitUntilDone() async {
        await task?.value
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

enum DictationError: LocalizedError {
    case noMicrophoneAccess
    case unsupportedLanguage(String)
    case noAudioFormat

    var errorDescription: String? {
        switch self {
        case .noMicrophoneAccess:
            "Dictation needs the microphone. Allow ReGlance in System Settings › Privacy & Security › Microphone."
        case .unsupportedLanguage(let language):
            "Dictation isn't available in \(language) yet."
        case .noAudioFormat:
            "Dictation couldn't read the microphone."
        }
    }
}

/// Hands a microphone buffer to the converter's input block, which runs synchronously inside
/// `convert`. Some SDKs mark `AVAudioPCMBuffer` Sendable and some don't; this builds on both.
private nonisolated struct AudioBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
}

/// On-device speech recognition with `SpeechAnalyzer` and Apple's dictation model, in the
/// system language. The first use downloads the model.
final class SpeechRecognizer: SpeechRecognizing {
    private let engine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var isTapping = false

    func start() async throws -> AsyncThrowingStream<SpeechUpdate, Error> {
        guard await AVAudioApplication.requestRecordPermission() else { throw DictationError.noMicrophoneAccess }
        let language = Locale.current
        guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: language) else {
            throw DictationError.unsupportedLanguage(language.localizedString(forIdentifier: language.identifier) ?? language.identifier)
        }
        let transcriber = DictationTranscriber(locale: locale, preset: .progressiveLongDictation)
        if let download = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await download.downloadAndInstall()
        }

        let microphone = engine.inputNode.outputFormat(forBus: 0)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber],
                                                                        considering: microphone) else {
            throw DictationError.noAudioFormat
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.prepareToAnalyze(in: format)
        let (audio, input) = AsyncStream<AnalyzerInput>.makeStream()
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: microphone,
                                    block: Self.tap(from: microphone, to: format, into: input))
        isTapping = true
        engine.prepare()
        try engine.start()
        try await analyzer.start(inputSequence: audio)
        self.analyzer = analyzer
        self.input = input

        return AsyncThrowingStream { updates in
            let reader = Task {
                do {
                    for try await result in transcriber.results {
                        updates.yield(SpeechUpdate(text: String(result.text.characters), isFinal: result.isFinal))
                    }
                    updates.finish()
                } catch {
                    updates.finish(throwing: error)
                }
            }
            updates.onTermination = { _ in reader.cancel() }
        }
    }

    func stop() async {
        if isTapping {
            engine.inputNode.removeTap(onBus: 0)
            isTapping = false
        }
        engine.stop()
        input?.finish()
        input = nil
        // Finishes the words in flight, then ends the results stream.
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        analyzer = nil
    }

    /// Converts microphone buffers to the analyzer's format. Runs on the audio thread.
    nonisolated private static func tap(from source: AVAudioFormat, to target: AVAudioFormat,
                                        into input: AsyncStream<AnalyzerInput>.Continuation) -> AVAudioNodeTapBlock {
        let converter = source == target ? nil : AVAudioConverter(from: source, to: target)
        return { buffer, _ in
            guard let converter else {
                input.yield(AnalyzerInput(buffer: buffer))
                return
            }
            let ratio = target.sampleRate / source.sampleRate
            let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1
            guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            nonisolated(unsafe) var supplied = false
            let source = AudioBuffer(buffer: buffer)
            var error: NSError?
            converter.convert(to: converted, error: &error) { _, status in
                if supplied {
                    status.pointee = .noDataNow
                    return nil
                }
                supplied = true
                status.pointee = .haveData
                return source.buffer
            }
            if error == nil, converted.frameLength > 0 { input.yield(AnalyzerInput(buffer: converted)) }
        }
    }
}
