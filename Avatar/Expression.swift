import Foundation

/// Where one eyebrow is, in image pixels. The brow is raised by stretching the skin between
/// it and the eye and squeezing the forehead above it, so no painted-out patch is needed.
nonisolated struct BrowRegion: Sendable {
    /// Left and right edges; the lift fades to nothing toward them.
    var minX: Double
    var maxX: Double
    /// Forehead above the brow, which stays put.
    var top: Double
    /// The middle of the brow, which moves up by the lift.
    var line: Double
    /// Just above the eye, which stays put.
    var bottom: Double

    /// How much of the lift applies at `x`: 0 at the edges, 1 across the middle. `taper` is the
    /// fraction of the width at each end over which it fades.
    func weight(atX x: Double, taper: Double = 0.3) -> Double {
        let u = (x - minX) / (maxX - minX)
        guard u > 0, u < 1 else { return 0 }
        let edge = min(u, 1 - u) / taper
        guard edge < 1 else { return 1 }
        return edge * edge * (3 - 2 * edge)
    }

    /// How much of a tilt applies at `x`: nothing at the outer end, rising to 1 near the inner
    /// end (the one nearer `centerX`, the middle of the face).
    func tiltWeight(atX x: Double, centerX: Double) -> Double {
        let u = (x - minX) / (maxX - minX)
        let inner = (minX + maxX) / 2 < centerX ? u : 1 - u
        return max(0, inner) * weight(atX: x, taper: 0.1)
    }
}

/// When the eyebrows move while speaking.
nonisolated enum Emphasis {
    /// How high the eyebrows go at the end of a question or exclamation.
    static let exclaimedLift = 1.5

    /// Where the eyebrows go for the word at `range` in `text`: positive raises them, negative
    /// lowers them a little, and nil leaves them be.
    ///
    /// The last word before "?" or "!" raises them highest (`exclaimedLift`). Otherwise
    /// negative or doubtful words ("not", "never", "but", "sorry"…) lower them, and words in
    /// capitals raise them. Other words raise them when the voice stresses them: `accent`
    /// (0 ... 1) is how much the word's pitch rises (see `WordProsody`). When that isn't known,
    /// the stress is guessed from the text instead (see `raisesBrows`).
    static func brows(for range: NSRange, in text: String, accent: Double? = nil) -> Double? {
        let nsText = text as NSString
        guard range.location != NSNotFound, NSMaxRange(range) <= nsText.length else { return nil }
        if endsQuestionOrExclamation(range, in: nsText) { return exclaimedLift }
        let word = nsText.substring(with: range)
        if lowersBrows(word) { return -0.5 }
        if isShouted(word) { return 1 }
        if let accent {
            return accent >= 0.2 ? 0.6 + 0.4 * accent : nil
        }
        return raisesBrows(range, in: text) ? 1 : nil
    }

    /// Whether `word` is in capitals, like "NOT" (a single capital, like "I", doesn't count).
    private static func isShouted(_ word: String) -> Bool {
        let letters = word.filter(\.isLetter)
        return letters.count >= 2 && letters.allSatisfy(\.isUppercase)
    }

    /// Whether the word at `range` is the last before "?" or "!".
    private static func endsQuestionOrExclamation(_ range: NSRange, in text: NSString) -> Bool {
        let word = text.substring(with: range)
        let next = text.substring(from: NSMaxRange(range)).first { !$0.isWhitespace && !quotes.contains($0) }
        return next == "?" || next == "!" || word.contains("?") || word.contains("!")
    }

    /// Whether `word` is negative or doubtful: "not", "never", "can't", "but", "sorry"…
    static func lowersBrows(_ word: String) -> Bool {
        let word = word.lowercased().filter { $0.isLetter || $0 == "'" || $0 == "’" }
        return word.hasSuffix("n't") || word.hasSuffix("n’t") || lowering.contains(word)
    }

    private static let lowering: Set<String> = [
        "no", "not", "never", "nothing", "nobody", "none", "nor", "neither", "cannot",
        "but", "however", "although", "though", "unfortunately", "sadly", "sorry",
        "problem", "problems", "wrong", "error", "errors", "fail", "failed", "failure",
        "careful", "warning", "worry", "worried", "difficult", "serious", "bad", "hmm",
    ]

    /// Whether the word at `range` in `text` is stressed enough to raise the eyebrows: the
    /// first word of a sentence or clause, a word in capitals, a long word, or the last word
    /// before "?" or "!".
    static func raisesBrows(_ range: NSRange, in text: String) -> Bool {
        let text = text as NSString
        guard range.location != NSNotFound, NSMaxRange(range) <= text.length else { return false }
        let word = text.substring(with: range)
        let letters = word.filter(\.isLetter)

        // The last character before the word, other than spaces and quotes.
        let before = text.substring(to: range.location).last { !$0.isWhitespace && !Self.quotes.contains($0) }
        if before == nil || ".!?,;:—".contains(before!) {
            return true
        }
        if isShouted(word) {
            return true
        }
        if letters.count >= 7 {
            return true
        }
        return endsQuestionOrExclamation(range, in: text)
    }

    private static let quotes: Set<Character> = ["\"", "'", "“", "”", "‘", "’"]
}

/// How the face holds itself for a presence (see `Presence`): the brows (together and one against
/// the other) and lowered eyelids. While listening, `ListeningCues` adds nods and a glance as the
/// speaker talks and pauses. Eased like moods; neutral while speaking.
nonisolated struct PresencePose: Sendable, Equatable {
    /// Lift of both brows, in the same units as `FaceExpression.brows`.
    var brows: Double
    /// Added to the first brow and taken from the second: one lifted, the other level or knit.
    var browAsymmetry: Double
    /// How far the upper eyelids come down, 0 ... 1.
    var lids: Double

    static let neutral = PresencePose(brows: 0, browAsymmetry: 0, lids: 0)

    /// Listening: attentive, brows a little up.
    static let listening = PresencePose(brows: 0.1, browAsymmetry: 0, lids: 0)
    /// Thinking: one brow up and the other level, eyes lowered.
    static let thinking = PresencePose(brows: 0.15, browAsymmetry: 0.25, lids: 0.25)

    /// Listening, and how: brows a little higher while words are coming in, eyes narrowed a touch for
    /// a moment when the speaker pauses, as if taking in what was said.
    static func listening(hearing: Bool, glancing: Bool) -> PresencePose {
        PresencePose(brows: hearing ? 0.22 : listening.brows, browAsymmetry: 0, lids: glancing ? 0.15 : 0)
    }

    static func target(for state: Presence.State?, hearing: Bool = false, glancing: Bool = false) -> PresencePose {
        switch state {
        case .listening: .listening(hearing: hearing, glancing: glancing)
        case .thinking: .thinking
        case .some(.none), nil: .neutral
        }
    }

    /// Moves a fraction of the way to `target`, snapping to it when close.
    func approaching(_ target: PresencePose, rate: Double) -> PresencePose {
        func step(_ value: Double, _ goal: Double, snap: Double) -> Double {
            let next = value + (goal - value) * rate
            return abs(next - goal) < snap ? goal : next
        }
        return PresencePose(brows: step(brows, target.brows, snap: 0.005),
                            browAsymmetry: step(browAsymmetry, target.browAsymmetry, snap: 0.005),
                            lids: step(lids, target.lids, snap: 0.005))
    }
}

/// When a listening face reacts to what it hears: a small nod every few seconds while words keep
/// coming (irregular, like a listener's "mm-hm"), brows up while hearing, and a brief glance (eyes
/// narrowed a touch) when the speaker pauses. Times are in seconds on any steady clock.
nonisolated struct ListeningCues {
    /// How many new words, at least, between two small nods, and how far apart they are.
    static let wordsPerNod = 3
    static let nodGaps = 2.5...4.0
    /// Hearing lasts this long after the last word; a pause this long brings the glance, which lasts
    /// `glanceLength`.
    static let hearingFor = 1.0
    static let glanceAfter = 0.7
    static let glanceLength = 0.6

    private var lastHeard: Double?
    private var lastNod: Double?
    private var wordsSinceNod = 0
    private var lastWordCount = 0
    private var gap: Double
    private let nextGap: () -> Double

    init(nextGap: @escaping () -> Double = { Double.random(in: ListeningCues.nodGaps) }) {
        self.nextGap = nextGap
        gap = nextGap()
    }

    /// The phrase heard so far has `words` words, at `now`: true when the face should nod a little.
    mutating func heard(words: Int, at now: Double) -> Bool {
        // A phrase's words only grow; fewer means a new phrase began.
        wordsSinceNod += max(0, words < lastWordCount ? words : words - lastWordCount)
        lastWordCount = words
        lastHeard = now
        guard wordsSinceNod >= Self.wordsPerNod, now - (lastNod ?? -.infinity) >= gap else { return false }
        nodded(at: now)
        return true
    }

    /// The phrase is done (and the face gave it the full nod).
    mutating func phraseEnded(at now: Double) {
        lastWordCount = 0
        nodded(at: now)
    }

    func isHearing(at now: Double) -> Bool {
        guard let lastHeard else { return false }
        return now - lastHeard < Self.hearingFor
    }

    func isGlancing(at now: Double) -> Bool {
        guard let lastHeard else { return false }
        let quiet = now - lastHeard
        return quiet >= Self.glanceAfter && quiet < Self.glanceAfter + Self.glanceLength
    }

    /// Something is still to come (hearing to end, a glance to start or end).
    func isActive(at now: Double) -> Bool {
        guard let lastHeard else { return false }
        return now - lastHeard < max(Self.hearingFor, Self.glanceAfter + Self.glanceLength)
    }

    private mutating func nodded(at now: Double) {
        lastNod = now
        wordsSinceNod = 0
        gap = nextGap()
    }
}
