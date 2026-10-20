import Accelerate
import Foundation

/// Tracks the pitch of speech audio as it is rendered, one estimate per envelope window
/// (`AudioPipeline.windowFrames` samples), so each word's pitch can be compared with the
/// speaker's usual pitch.
nonisolated struct PitchTracker: Sendable {
    /// Samples analysed for each estimate: enough for two periods of a low (70 Hz) voice.
    static let frameLength = 1024

    var sampleRate = 22_050.0
    /// Fundamental frequency (Hz) per window; 0 where the sound isn't voiced.
    private(set) var pitches: [Float] = []
    private var recent: [Float] = []
    private var sinceEstimate = 0

    mutating func append(_ sample: Float) {
        recent.append(sample)
        sinceEstimate += 1
        guard sinceEstimate == Int(AudioPipeline.windowFrames) else { return }
        sinceEstimate = 0
        if recent.count > 2 * Self.frameLength {
            recent.removeFirst(recent.count - Self.frameLength)
        }
        pitches.append(recent.count >= Self.frameLength
            ? Self.fundamental(of: Array(recent.suffix(Self.frameLength)), sampleRate: sampleRate)
            : 0)
    }

    /// The fundamental frequency of `samples` in Hz (70–400 Hz), or 0 when they are too
    /// quiet or not periodic enough to be voiced speech. Uses normalised autocorrelation and
    /// prefers the shortest strongly-correlated period, which avoids octave-low errors.
    static func fundamental(of samples: [Float], sampleRate: Double) -> Float {
        let minLag = Int(sampleRate / 400)
        let maxLag = min(Int(sampleRate / 70), samples.count / 2)
        let width = samples.count - maxLag
        guard minLag < maxLag, width > 0 else { return 0 }

        return samples.withUnsafeBufferPointer { buffer -> Float in
            let x = buffer.baseAddress!
            var energy: Float = 0
            vDSP_dotpr(x, 1, x, 1, &energy, vDSP_Length(width))
            guard (energy / Float(width)).squareRoot() >= 0.02 else { return 0 }

            var shiftedEnergy: Float = 0
            vDSP_dotpr(x + minLag, 1, x + minLag, 1, &shiftedEnergy, vDSP_Length(width))
            var correlations = [Float](repeating: 0, count: maxLag + 1)
            for lag in minLag...maxLag {
                if lag > minLag {
                    // Slide the shifted window along by one sample.
                    let leaving = x[lag - 1], entering = x[lag + width - 1]
                    shiftedEnergy += entering * entering - leaving * leaving
                }
                var product: Float = 0
                vDSP_dotpr(x, 1, x + lag, 1, &product, vDSP_Length(width))
                correlations[lag] = product / max(1e-9, (energy * max(0, shiftedEnergy)).squareRoot())
            }

            let best = correlations[minLag...maxLag].max() ?? 0
            guard best >= 0.5 else { return 0 }
            for lag in minLag + 1..<maxLag
            where correlations[lag] >= 0.85 * best
                && correlations[lag] >= correlations[lag - 1] && correlations[lag] >= correlations[lag + 1] {
                return Float(sampleRate) / Float(lag)
            }
            return 0
        }
    }
}

/// How a spoken word stands out in pitch from the rest of the speech.
nonisolated struct WordProsody: Sendable, Equatable {
    /// The word's pitch, in semitones above the speaker's median.
    var semitones: Double
    /// How far this speaker's pitch usually rises (semitones from the median to the 90th
    /// percentile), so voices with a lively intonation don't look over-excited and flatter
    /// ones still move.
    var spread: Double

    /// How strongly the word is accented, 0 ... 1: its rise above the median as a share of the
    /// speaker's range. Speakers mark stress mostly with a pitch rise.
    var accent: Double {
        let rise = semitones / max(2, spread)
        return min(1, max(0, (rise - 0.8) / 0.6))
    }

    /// The prosody of the windows `word`, compared with all the voiced windows so far, or nil
    /// when there isn't enough voiced sound yet.
    static func measure(word: Range<Int>, pitches: [Float]) -> WordProsody? {
        let voiced = pitches.filter { $0 > 0 }
        let inWord = pitches.indices.filter { word.contains($0) && pitches[$0] > 0 }.map { pitches[$0] }
        guard !inWord.isEmpty, voiced.count >= 8 else { return nil }

        let median = Double(percentile(voiced, 0.5))
        func semitones(_ pitch: Float) -> Double { 12 * log2(Double(pitch) / median) }
        return WordProsody(semitones: semitones(percentile(inWord, 0.75)),
                           spread: semitones(percentile(voiced, 0.9)))
    }

    private static func percentile(_ values: [Float], _ fraction: Double) -> Float {
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))]
    }
}
