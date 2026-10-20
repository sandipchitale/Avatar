import AVFoundation
import Speech

// On-device speech recognition.
//
// AVAudioEngine input tap → AsyncStream<AnalyzerInput> → SpeechAnalyzer +
// SpeechTranscriber, with volatile results rendered as interim text and only
// finalised results acted on.

/// Why the ears can't start, in words for the user.
private nonisolated struct EarsFailure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// The converter is touched only from the audio thread, which calls the tap
/// serially. Boxing it keeps that promise explicit rather than implicit.
private final class ConverterBox: @unchecked Sendable {
    let converter: AVAudioConverter
    let format: AVAudioFormat
    init(converter: AVAudioConverter, format: AVAudioFormat) {
        self.converter = converter
        self.format = format
    }
}

@MainActor
final class SpeechInputController {

    enum State: Equatable, Sendable {
        case idle
        /// Model assets are downloading.
        case preparing
        case listening
        case microphoneDenied
        case unavailable(String)

        var isRunning: Bool { self == .listening || self == .preparing }
    }

    private(set) var state: State = .idle {
        didSet { if state != oldValue { onStateChange?(state) } }
    }

    var onStateChange: ((State) -> Void)?
    /// Interim hypothesis; replaced in place, never committed.
    var onVolatile: ((String) -> Void)?
    /// A committed result: inserted, or dispatched as a command.
    var onFinal: ((String) -> Void)?

    private let engine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var reservedLocale: Locale?

    // MARK: Permission

    /// Requested at first microphone activation, never at launch.
    private static func microphoneAuthorized() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    // MARK: Lifecycle

    func start() async {
        guard !state.isRunning else { return }

        guard await Self.microphoneAuthorized() else {
            state = .microphoneDenied
            return
        }

        do {
            let resolved = try await resolveLocale()
            let transcriber = SpeechTranscriber(
                locale: resolved,
                transcriptionOptions: [],
                reportingOptions: [.volatileResults],
                attributeOptions: [.audioTimeRange])
            self.transcriber = transcriber

            // Model assets may need downloading on first use; the mic control
            // shows "Preparing…" rather than silently failing.
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                state = .preparing
                try await request.downloadAndInstall()
            }
            if try await AssetInventory.reserve(locale: resolved) {
                reservedLocale = resolved
            }

            guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
                compatibleWith: [transcriber]) else {
                state = .unavailable("This Mac has no compatible audio format for transcription.")
                return
            }

            let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
            inputContinuation = continuation

            let analyzer = SpeechAnalyzer(inputSequence: stream, modules: [transcriber])
            self.analyzer = analyzer

            try startEngine(converting: analyzerFormat)
            consumeResults(from: transcriber)
            state = .listening

        } catch {
            state = .unavailable(error.localizedDescription)
            await teardown()
        }
    }

    func stop() async {
        guard state != .idle else { return }
        await teardown()
        state = .idle
    }

    private func teardown() async {
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        inputContinuation?.finish()
        inputContinuation = nil
        resultsTask?.cancel()
        resultsTask = nil
        // Interim text outstanding at stop is discarded, not committed.
        onVolatile?("")
        if let analyzer {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        analyzer = nil
        transcriber = nil
        if let reservedLocale {
            _ = await AssetInventory.release(reservedLocale: reservedLocale)
            self.reservedLocale = nil
        }
    }

    // MARK: Audio

    private func startEngine(converting analyzerFormat: AVAudioFormat) throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            throw EarsFailure("No audio input device is available.")
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: analyzerFormat) else {
            throw EarsFailure("Cannot convert this microphone's audio for transcription.")
        }
        let box = ConverterBox(converter: converter, format: analyzerFormat)
        let continuation = inputContinuation

        // The tap runs on a realtime audio thread. Written inline it would
        // inherit this type's @MainActor isolation and trap on the first
        // buffer, so it is declared @Sendable explicitly and touches nothing
        // isolated: the converter is boxed, and the continuation is already Sendable.
        let tap: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = { buffer, _ in
            guard let converted = Self.convert(buffer, with: box) else { return }
            continuation?.yield(AnalyzerInput(buffer: converted))
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat, block: tap)

        engine.prepare()
        try engine.start()
    }

    private nonisolated static func convert(_ buffer: AVAudioPCMBuffer,
                                            with box: ConverterBox) -> AVAudioPCMBuffer? {
        let ratio = box.format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: box.format, frameCapacity: capacity) else {
            return nil
        }

        var supplied = false
        var error: NSError?
        let status = box.converter.convert(to: output, error: &error) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil, output.frameLength > 0 else { return nil }
        return output
    }

    // MARK: Results

    private func consumeResults(from transcriber: SpeechTranscriber) {
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard !Task.isCancelled else { return }
                    let text = String(result.text.characters)
                    await MainActor.run {
                        guard let self else { return }
                        if result.isFinal {
                            self.onVolatile?("")
                            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty { self.onFinal?(trimmed) }
                        } else {
                            self.onVolatile?(text)
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self?.state = .unavailable(error.localizedDescription)
                }
            }
        }
    }

    // MARK: Locale

    /// US English, or another English, or failing that any installed language.
    private func resolveLocale() async throws -> Locale {
        let english = Locale(identifier: "en-US")
        let supported = await SpeechTranscriber.supportedLocales
        if let match = supported.first(where: { $0.identifier(.bcp47) == english.identifier(.bcp47) })
            ?? supported.first(where: { $0.language.languageCode == english.language.languageCode })
            ?? supported.first {
            return match
        }
        throw EarsFailure("No speech transcription languages are installed.")
    }
}
