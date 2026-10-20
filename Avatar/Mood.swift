import Foundation

/// A feeling the face can show while it speaks. Moods come from hints any caller can give
/// (the `mood` field of a `/say` request, or `[mood]` cues in the text), and
/// otherwise are guessed from the text itself (see `Script`).
nonisolated enum Mood: String, CaseIterable, Sendable {
    case neutral, happy, sad, surprised, concerned, angry

    /// The mood called `name` (any case), if there is one.
    init?(name: String) {
        self.init(rawValue: name.lowercased())
    }

    /// How the face looks in this mood.
    var face: FaceExpression {
        switch self {
        case .neutral:   .neutral
        case .happy:     FaceExpression(brows: 0.3, tilt: 0, frown: 0)
        case .sad:       FaceExpression(brows: -0.2, tilt: 1.4, frown: 0.8)
        case .surprised: FaceExpression(brows: 1.1, tilt: 0, frown: 0)
        case .concerned: FaceExpression(brows: -0.3, tilt: 0.9, frown: 0.45)
        case .angry:     FaceExpression(brows: -0.4, tilt: -1.2, frown: 0.6)
        }
    }

    static let names = allCases.map(\.rawValue).joined(separator: ", ")
}

/// The face's expression, apart from the mouth shapes of speech and the stress-driven
/// eyebrow movements.
nonisolated struct FaceExpression: Sendable, Equatable {
    /// Eyebrow height: 1 raised, negative lowered.
    var brows: Double
    /// Inner ends of the eyebrows up (positive: sad, worried) or down (negative: angry).
    var tilt: Double
    /// How far the corners of the closed mouth turn down, 0 ... 1, hiding the portrait's smile.
    var frown: Double

    static let neutral = FaceExpression(brows: 0, tilt: 0, frown: 0)

    /// Moves a fraction of the way to `target`, snapping to it when close.
    func approaching(_ target: FaceExpression, rate: Double) -> FaceExpression {
        func step(_ value: Double, _ goal: Double) -> Double {
            let next = value + (goal - value) * rate
            return abs(next - goal) < 0.005 ? goal : next
        }
        return FaceExpression(brows: step(brows, target.brows), tilt: step(tilt, target.tilt),
                              frown: step(frown, target.frown))
    }
}

/// Text to speak, with the moods to show along it. `parse` takes out `[mood]` cues and mood
/// emoji or emoticons (the voice would read them out), and works out which mood applies where:
///
/// - A `[mood]` cue applies from where it stands until the next cue. `[neutral]` ends one.
/// - Otherwise a mood given for the whole text (the `mood` field of a `/say` request) applies.
/// - Otherwise each sentence gets the mood its emoji and feeling words suggest, if any.
nonisolated struct Script: Sendable, Equatable {
    /// What the voice says.
    var text: String
    /// `[mood]` cues, by UTF-16 offset in `text`.
    var cues: [Mark] = []
    /// The mood given for the whole text, if any.
    var mood: Mood?
    /// The mood guessed for each sentence that suggests one.
    var sentences: [Mark] = []

    struct Mark: Sendable, Equatable {
        /// UTF-16 range in `text` (for a cue, where it applies from).
        var range: NSRange
        var mood: Mood
    }

    /// The mood at UTF-16 offset `location` in `text`.
    func mood(at location: Int) -> Mood {
        if let cue = cues.last(where: { $0.range.location <= location }) { return cue.mood }
        if let mood { return mood }
        return sentences.first { NSLocationInRange(location, $0.range) }?.mood ?? .neutral
    }

    static func parse(_ source: String, mood: Mood? = nil) -> Script {
        var text = ""
        var length = 0  // UTF-16 length of `text`
        var cues: [Mark] = []
        var emoji: [(location: Int, mood: Mood)] = []
        var skipsSpace = false

        var index = source.startIndex
        while index < source.endIndex {
            let character = source[index]
            if skipsSpace, character.isWhitespace, !character.isNewline {
                index = source.index(after: index)
                continue
            }
            skipsSpace = false

            let found: (end: String.Index, mood: Mood, isCue: Bool)? =
                cue(in: source, at: index).map { ($0.end, $0.mood, true) }
                ?? emoticon(in: source, at: index).map { ($0.end, $0.mood, false) }
                ?? emojiMoods[String(character).replacingOccurrences(of: "\u{FE0F}", with: "")]
                    .map { (source.index(after: index), $0, false) }
            if let found {
                if found.isCue {
                    cues.append(Mark(range: NSRange(location: length, length: 0), mood: found.mood))
                } else {
                    emoji.append((length, found.mood))
                }
                index = found.end
                // Don't leave a double space where the token was.
                skipsSpace = text.isEmpty || text.last!.isWhitespace
                continue
            }
            text.append(character)
            length += character.utf16.count
            index = source.index(after: index)
        }

        var script = Script(text: text, cues: cues, mood: mood)
        script.sentences = guessMoods(in: text, emoji: emoji)
        return script
    }

    // MARK: Cues, emoji and emoticons

    /// A `[mood]` cue starting at `index`.
    private static func cue(in text: String, at index: String.Index) -> (end: String.Index, mood: Mood)? {
        guard text[index] == "[",
              let close = text[index...].prefix(12).firstIndex(of: "]"),
              let mood = Mood(name: String(text[text.index(after: index)..<close]))
        else { return nil }
        return (text.index(after: close), mood)
    }

    /// An emoticon such as `:)` starting at `index`, standing on its own.
    private static func emoticon(in text: String, at index: String.Index) -> (end: String.Index, mood: Mood)? {
        guard index == text.startIndex || text[text.index(before: index)].isWhitespace else { return nil }
        for (face, mood) in emoticons where text[index...].hasPrefix(face) {
            let end = text.index(index, offsetBy: face.count)
            if end == text.endIndex || text[end].isWhitespace || ".,!?".contains(text[end]) {
                return (end, mood)
            }
        }
        return nil
    }

    private static let emoticons: [(String, Mood)] = [
        (":-)", .happy), (":)", .happy), (":-D", .happy), (":D", .happy), (";)", .happy),
        (":-(", .sad), (":(", .sad), (":'(", .sad),
        (":-O", .surprised), (":O", .surprised), (":o", .surprised),
        (":-/", .concerned), (":/", .concerned),
        (">:(", .angry),
    ]

    private static let emojiMoods: [String: Mood] = {
        var moods: [String: Mood] = [:]
        for (list, mood) in [
            ("😀😃😄😁😆😊🙂😉😍🥰😎🤩🥳🎉👍❤♥😺", Mood.happy),
            ("😢😭😞😔☹🙁😿💔", .sad),
            ("😮😯😲😱🤯😳", .surprised),
            ("😟😕🤔😬😰😥⚠", .concerned),
            ("😠😡🤬👿", .angry),
        ] {
            for emoji in list { moods[String(emoji).replacingOccurrences(of: "\u{FE0F}", with: "")] = mood }
        }
        return moods
    }()

    // MARK: Guessing from the text

    /// Words that suggest a mood when they appear in a sentence.
    private static let feelingWords: [String: Mood] = {
        var words: [String: Mood] = [:]
        for (list, mood) in [
            ("great glad happy congratulations congrats wonderful excellent awesome fantastic delighted "
                + "thanks thank love yay hooray brilliant perfect nice", Mood.happy),
            ("sorry sadly unfortunately regret sad alas condolences miss", .sad),
            ("wow whoa incredible unbelievable amazing astonishing surprise surprised surprising", .surprised),
            ("warning careful caution beware alert error errors failed fail fails failure problem problems "
                + "risk risky danger dangerous worried worry concern concerned", .concerned),
            ("angry furious unacceptable outrageous annoyed ridiculous", .angry),
        ] {
            for word in list.split(separator: " ") { words[String(word)] = mood }
        }
        return words
    }()

    /// The mood each sentence of `text` suggests: its emoji count double, then its feeling
    /// words; the most suggested mood wins, the first one on a tie.
    private static func guessMoods(in text: String, emoji: [(location: Int, mood: Mood)]) -> [Mark] {
        let ns = text as NSString
        var marks: [Mark] = []
        for (number, sentence) in sentenceRanges(in: ns).enumerated() {
            var votes: [(mood: Mood, count: Int)] = []
            func vote(_ mood: Mood, _ weight: Int) {
                if let i = votes.firstIndex(where: { $0.mood == mood }) {
                    votes[i].count += weight
                } else {
                    votes.append((mood, weight))
                }
            }
            // An emoji belongs to the sentence it follows ("Well done! 😊"), even when it stands
            // at the start of the next one; one before any text belongs to the first sentence.
            for mark in emoji where (mark.location > sentence.location && mark.location <= NSMaxRange(sentence))
                || (number == 0 && mark.location == 0) {
                vote(mark.mood, 2)
            }
            ns.enumerateSubstrings(in: sentence, options: .byWords) { word, _, _, _ in
                guard let word else { return }
                if let mood = feelingWords[word.lowercased()] { vote(mood, 1) }
            }
            if let best = votes.max(by: { $0.count < $1.count }),
               let first = votes.first(where: { $0.count == best.count }) {
                marks.append(Mark(range: sentence, mood: first.mood))
            }
        }
        return marks
    }

    /// Each sentence's range, running from its first character to the start of the next one.
    private static func sentenceRanges(in text: NSString) -> [NSRange] {
        var starts: [Int] = []
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: .bySentences) { _, range, _, _ in
            starts.append(range.location)
        }
        if starts.first != 0 { starts.insert(0, at: 0) }
        return starts.enumerated().map { i, start in
            NSRange(location: start, length: (i + 1 < starts.count ? starts[i + 1] : text.length) - start)
        }
    }
}
