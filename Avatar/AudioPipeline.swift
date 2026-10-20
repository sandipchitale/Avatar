import AVFoundation
import Synchronization

/// Renders speech into audio buffers with `AVSpeechSynthesizer.write`, plays them through
/// an `AVAudioEngine`, and records a loudness envelope and word timings keyed by audio
/// frame, so the UI can ask "what is being heard right now?" at any moment.
///
/// Synthesizer and audio callbacks arrive on arbitrary threads, so this type is
/// nonisolated and guards its mutable state with a `Mutex`. Buffers are scheduled while
/// holding the lock, so `stop()` (which takes the lock first) can't interleave with them.
nonisolated final class AudioPipeline: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    /// Number of audio frames summarised by each envelope entry.
    static let windowFrames: Int64 = 256

    nonisolated struct Snapshot: Sendable {
        /// RMS loudness of the audio currently being heard (0 when silent or not playing).
        var level: Float
        /// Range, in the spoken text, of the word currently being heard.
        var wordRange: NSRange?
        /// Mouth position for the sound currently being heard.
        var viseme: Viseme
    }

    nonisolated private struct WordTiming {
        var frame: Int64
        var range: NSRange
        var visemes: [Viseme]

        /// The viseme at `progress` (0 ... 1) through the word, giving vowels more time.
        func viseme(at progress: Double) -> Viseme {
            let total = visemes.reduce(0) { $0 + $1.weight }
            var position = progress * total
            for viseme in visemes {
                position -= viseme.weight
                if position < 0 { return viseme }
            }
            return visemes.last ?? .rest
        }
    }

    /// Windows quieter than this count as silence (mouth at rest).
    private static let silenceRMS: Float = 0.02

    nonisolated private struct Timeline {
        var generation: UInt64 = 0
        var utteranceID: ObjectIdentifier?
        var text = ""
        var framesRendered: Int64 = 0
        var envelope: [Float] = []
        var windowSum: Float = 0
        var windowCount: Int64 = 0
        var words: [WordTiming] = []
        var engineStarted = false
        var renderingFinished = false
        var pitch = PitchTracker()

        /// Narrows `start..<end` to the part that is actually voiced, trimming leading and
        /// trailing silence (e.g. the pause after a comma).
        func voicedSpan(from start: Int64, to end: Int64) -> Range<Int64>? {
            let windows = Int(start / AudioPipeline.windowFrames)..<min(envelope.count, Int((end + AudioPipeline.windowFrames - 1) / AudioPipeline.windowFrames))
            guard let first = windows.first(where: { envelope[$0] >= AudioPipeline.silenceRMS }),
                  let last = windows.last(where: { envelope[$0] >= AudioPipeline.silenceRMS })
            else { return nil }
            return Int64(first) * AudioPipeline.windowFrames..<Int64(last + 1) * AudioPipeline.windowFrames
        }

        /// What is heard at `frame`.
        func snapshot(at frame: Int64) -> Snapshot {
            let index = Int(frame / AudioPipeline.windowFrames)
            let level = index < envelope.count ? envelope[index] : 0
            guard let wordIndex = words.lastIndex(where: { $0.frame <= frame }) else {
                return Snapshot(level: level, wordRange: nil, viseme: .rest)
            }
            let word = words[wordIndex]
            let end = wordIndex + 1 < words.count ? words[wordIndex + 1].frame : framesRendered
            guard level >= AudioPipeline.silenceRMS,
                  let span = voicedSpan(from: word.frame, to: end), span.contains(frame)
            else { return Snapshot(level: level, wordRange: word.range, viseme: .rest) }
            let progress = Double(frame - span.lowerBound) / Double(span.count)
            return Snapshot(level: level, wordRange: word.range, viseme: word.viseme(at: progress))
        }

        /// How the word at `range` stands out in pitch from the speech so far.
        func prosody(of range: NSRange) -> WordProsody? {
            guard let index = words.firstIndex(where: { $0.range == range }) else { return nil }
            let end = index + 1 < words.count ? words[index + 1].frame : framesRendered
            let windows = Int(words[index].frame / AudioPipeline.windowFrames)..<Int(end / AudioPipeline.windowFrames)
            return WordProsody.measure(word: windows, pitches: pitch.pitches)
        }

        /// Records the loudness envelope and the pitch of `buffer`.
        mutating func appendEnvelope(of buffer: AVAudioPCMBuffer) {
            let count = Int(buffer.frameLength)
            pitch.sampleRate = buffer.format.sampleRate
            for i in 0..<count {
                let sample: Float
                if let floats = buffer.floatChannelData {
                    sample = floats[0][i]
                } else if let ints = buffer.int16ChannelData {
                    sample = Float(ints[0][i]) / Float(Int16.max)
                } else {
                    sample = 0
                }
                pitch.append(sample)
                windowSum += sample * sample
                windowCount += 1
                if windowCount == AudioPipeline.windowFrames {
                    envelope.append((windowSum / Float(windowCount)).squareRoot())
                    windowSum = 0
                    windowCount = 0
                }
            }
        }
    }

    private let synthesizer = AVSpeechSynthesizer()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let timeline = Mutex(Timeline())
    private let onFinished: @Sendable (UInt64) -> Void

    /// - Parameter onFinished: called (on an arbitrary thread) with the generation of an
    ///   utterance once its audio has fully played, or when it was stopped.
    init(onFinished: @escaping @Sendable (UInt64) -> Void) {
        self.onFinished = onFinished
        super.init()
        synthesizer.delegate = self
        engine.attach(player)
    }

    /// Stops anything in progress and starts speaking `text`.
    /// - Returns: a generation number identifying this utterance in `onFinished`.
    func speak(_ text: String, voice: AVSpeechSynthesisVoice?, rate: Float) -> UInt64 {
        stop()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = rate
        let generation = timeline.withLock { t in
            let generation = t.generation + 1
            t = Timeline()
            t.generation = generation
            t.utteranceID = ObjectIdentifier(utterance)
            t.text = text
            return generation
        }
        synthesizer.write(utterance) { [weak self] buffer in
            self?.receive(buffer, generation: generation)
        }
        return generation
    }

    func pause() {
        player.pause()
    }

    func resume() {
        player.play()
    }

    func stop() {
        timeline.withLock { t in
            t.generation += 1
            t.utteranceID = nil
        }
        synthesizer.stopSpeaking(at: .immediate)
        player.stop()
        engine.stop()
    }

    /// What is audible right now, compensating for output latency.
    func snapshot() -> Snapshot {
        guard let nodeTime = player.lastRenderTime, nodeTime.isSampleTimeValid,
              let playerTime = player.playerTime(forNodeTime: nodeTime)
        else { return Snapshot(level: 0, wordRange: nil, viseme: .rest) }

        let latencyFrames = Int64(engine.outputNode.presentationLatency * playerTime.sampleRate)
        let frame = playerTime.sampleTime - latencyFrames
        guard frame >= 0 else { return Snapshot(level: 0, wordRange: nil, viseme: .rest) }

        return timeline.withLock { $0.snapshot(at: frame) }
    }

    /// How the word at `range` in the current text stands out in pitch, once its
    /// audio has been rendered.
    func prosody(ofWordAt range: NSRange) -> WordProsody? {
        timeline.withLock { $0.prosody(of: range) }
    }

    private func receive(_ buffer: AVAudioBuffer, generation: UInt64) {
        guard let pcm = buffer as? AVAudioPCMBuffer else { return }

        timeline.withLock { t in
            guard t.generation == generation, !t.renderingFinished else { return }

            // A zero-length buffer marks the end of the utterance (it may arrive more than once).
            if pcm.frameLength == 0 {
                t.renderingFinished = true
                // Schedule a 1-frame marker buffer whose playback completion signals the end of speech.
                guard t.engineStarted,
                      let marker = AVAudioPCMBuffer(pcmFormat: player.outputFormat(forBus: 0), frameCapacity: 1)
                else {
                    onFinished(generation)
                    return
                }
                marker.frameLength = 1
                player.scheduleBuffer(marker, completionCallbackType: .dataPlayedBack) { [onFinished] _ in
                    onFinished(generation)
                }
                return
            }

            t.appendEnvelope(of: pcm)
            t.framesRendered += Int64(pcm.frameLength)
            if !t.engineStarted {
                // Voices differ in sample rate, so connect using the format of the first buffer.
                engine.disconnectNodeOutput(player)
                engine.connect(player, to: engine.mainMixerNode, format: pcm.format)
                do {
                    try engine.start()
                } catch {
                    t.renderingFinished = true
                    onFinished(generation)
                    return
                }
                player.play()
                t.engineStarted = true
            }
            player.scheduleBuffer(pcm)
        }
    }

    // MARK: - AVSpeechSynthesizerDelegate

    /// While writing, word callbacks arrive in step with rendering, so the number of frames
    /// rendered so far is the audio position at which the word starts.
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           willSpeakRangeOfSpeechString characterRange: NSRange,
                           utterance: AVSpeechUtterance) {
        timeline.withLock { t in
            guard t.utteranceID == ObjectIdentifier(utterance) else { return }
            let word = (t.text as NSString).substring(with: characterRange)
            t.words.append(WordTiming(frame: t.framesRendered, range: characterRange,
                                      visemes: Viseme.sequence(for: word)))
        }
    }
}
