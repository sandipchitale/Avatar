import AVFoundation
import Observation

enum SpeechState {
    case idle, speaking, paused
}

/// The face's speech: owns the audio pipeline and publishes speech state, mouth opening, brows,
/// mood and presence, and the word being spoken.
@Observable
final class SpeechEngine {
    private(set) var state: SpeechState = .idle
    /// Current mouth, morphing smoothly toward the viseme being heard.
    private(set) var mouth = MouthShape.rest
    /// The text of the current utterance, without mood cues and mood emoji.
    private(set) var spokenText = ""
    private(set) var currentWordRange: NSRange?
    /// How far the eyebrows are raised (1, or higher for "?" and "!") or lowered (negative), 0
    /// at rest; they go up on stressed words and down a little on negative or doubtful ones.
    private(set) var brows = 0.0
    /// The mood being shown, easing from one to the next (see `Mood`).
    private(set) var expression = FaceExpression.neutral

    /// The faces on offer, each with its own voice, sorted by voice name.
    let portraits = Portrait.all.sorted { $0.voiceName < $1.voiceName }
    /// The face shown and the voice it speaks with: the man's or the woman's. Remembered.
    var gender: Gender = Gender(rawValue: UserDefaults.standard.string(forKey: "face") ?? "") ?? .male {
        didSet { UserDefaults.standard.set(gender.rawValue, forKey: "face") }
    }
    var portrait: Portrait { gender == .female ? .woman : .man }

    /// What the face shows between speeches (listening, thinking), its eased pose, and the last nod
    /// with how deep it goes (a small one while words come in, a fuller one when a phrase is done).
    private(set) var presence: Presence.State?
    private(set) var presencePose = PresencePose.neutral
    private(set) var nodStarted: Date?
    private(set) var nodDepth = SpeechEngine.fullNodDepth
    /// Words are coming in while listening: the face is attentive (see `ListeningCues`).
    private(set) var isHearing = false

    /// How far the head dips, in image pixels, for a phrase heard and for a nod while it is spoken.
    static let fullNodDepth = 3.2
    static let softNodDepth = 1.6

    /// Speech rate, from `AVSpeechUtteranceMinimumSpeechRate` to `AVSpeechUtteranceMaximumSpeechRate`;
    /// the default is a little slower than the system's. Applies from the next utterance.
    var rate: Float = SpeechEngine.rates[1].rate

    /// Speeds offered in the menu.
    static let rates: [(name: String, rate: Float)] = [("Slower", 0.34), ("Normal", 0.42), ("Faster", 0.5)]

    @ObservationIgnored private var pipeline: AudioPipeline!
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var ticker: Task<Void, Never>?
    /// Where the eyebrows are held, until when, and when they may next move, so they don't
    /// twitch on every other word.
    @ObservationIgnored private var browHold = 0.0
    @ObservationIgnored private var browHoldUntil = ContinuousClock.now
    @ObservationIgnored private var nextBrowMove = ContinuousClock.now
    /// When to nod and glance while listening, on `cueClock`.
    @ObservationIgnored private var cues = ListeningCues()
    @ObservationIgnored private let cueClock = ContinuousClock.now
    /// The text being spoken with its moods, and the mood for the words being heard.
    @ObservationIgnored private var script = Script(text: "")
    @ObservationIgnored private var mood = Mood.neutral
    /// Callers waiting for an utterance (by generation) to end; see `end(of:)`.
    @ObservationIgnored private var endWaiters: [(generation: UInt64, continuation: CheckedContinuation<SpeechEnd, Never>)] = []
    /// How the last utterance to end ended.
    @ObservationIgnored private var lastEnd: (generation: UInt64, end: SpeechEnd)?

    /// The voice chosen in the menu for each face (by `AVSpeechSynthesisVoice` identifier), when
    /// it isn't the face's own (Daniel or Samantha). Saved.
    private(set) var chosenVoices: [Portrait.ID: String] = [:]

    private static func chosenVoiceKey(_ portrait: Portrait.ID) -> String { "faceVoice.\(portrait)" }

    init() {
        pipeline = AudioPipeline { [weak self] generation in
            Task { @MainActor in self?.didFinish(generation) }
        }
        for portrait in Portrait.all {
            chosenVoices[portrait.id] = UserDefaults.standard.string(forKey: Self.chosenVoiceKey(portrait.id))
        }
    }

    /// Chooses the voice a face speaks with (nil: the face's own, Daniel or Samantha), and saves it.
    func choose(voice identifier: String?, for portrait: Portrait.ID) {
        chosenVoices[portrait] = identifier
        UserDefaults.standard.set(identifier, forKey: Self.chosenVoiceKey(portrait))
    }

    /// The voice `portrait` speaks with, or nil when none of its voices is installed (macOS then
    /// uses its default voice).
    func voice(for portrait: Portrait) -> AVSpeechSynthesisVoice? {
        Self.resolveVoice(chosen: chosenVoices[portrait.id], portrait: portrait,
                          installed: AVSpeechSynthesisVoice.speechVoices())
    }

    /// The name of the voice `portrait` speaks with, without its quality ("Ava", "Samantha"),
    /// or nil when macOS's default voice speaks for it.
    func voiceName(for portrait: Portrait) -> String? {
        voice(for: portrait).map { Self.plainName($0.name) }
    }

    /// The chosen voice if it is still installed and suits the face, else the best installed
    /// quality of the face's own voice.
    static func resolveVoice(chosen: String?, portrait: Portrait, installed: [AVSpeechSynthesisVoice]) -> AVSpeechSynthesisVoice? {
        if let chosen, let voice = installed.first(where: { $0.identifier == chosen }), suits(voice, portrait) {
            return voice
        }
        return bestVoice(named: portrait.voiceName, among: installed)
    }

    /// Whether `voice` is a man's voice for the man's face, or a woman's for the woman's, as macOS
    /// labels it. Voices macOS doesn't label either way aren't offered.
    static func suits(_ voice: AVSpeechSynthesisVoice, _ portrait: Portrait) -> Bool {
        voice.gender == (portrait.id == Portrait.woman.id ? .female : .male)
    }

    /// Voices `portrait` can use: installed English voices of its gender (no novelty ones), one per
    /// name at its best quality, best quality first, then by name.
    static func choosableVoices(for portrait: Portrait,
                                among installed: [AVSpeechSynthesisVoice] = AVSpeechSynthesisVoice.speechVoices()) -> [AVSpeechSynthesisVoice] {
        var best: [String: AVSpeechSynthesisVoice] = [:]
        for voice in installed where voice.language.hasPrefix("en") && !voice.voiceTraits.contains(.isNoveltyVoice)
            && suits(voice, portrait) {
            let name = plainName(voice.name)
            if let current = best[name], current.quality.rawValue >= voice.quality.rawValue { continue }
            best[name] = voice
        }
        return best.values.sorted {
            ($0.quality.rawValue, plainName($1.name)) > ($1.quality.rawValue, plainName($0.name))
        }
    }

    /// "Ava (Premium)" → "Ava".
    static func plainName(_ name: String) -> String {
        name.components(separatedBy: " (").first ?? name
    }

    /// Speaks `text`, showing `mood` throughout unless the text's own `[mood]` cues say
    /// otherwise; with no mood, the text's emoji and feeling words suggest one (see `Script`).
    /// Returns the utterance's generation, to wait for its end with `end(of:)`, or nil when
    /// there is nothing to say.
    @discardableResult
    func speak(_ text: String, mood: Mood? = nil) -> UInt64? {
        let script = Script.parse(text.trimmingCharacters(in: .whitespacesAndNewlines), mood: mood)
        let spoken = script.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else { return nil }
        // Speaking over an utterance cuts it short.
        if state != .idle { ended(.stopped) }
        self.script = script
        self.mood = script.mood(at: 0)
        spokenText = script.text
        currentWordRange = nil
        generation = pipeline.speak(script.text, voice: self.voice(for: portrait), rate: rate)
        state = .speaking
        startTicking()
        return generation
    }

    /// Waits for the utterance `generation` (from `speak`) to end: finished, or stopped (by
    /// `stop`, or by speaking something else).
    func end(of generation: UInt64) async -> SpeechEnd {
        if generation == self.generation, state != .idle {
            return await withCheckedContinuation { endWaiters.append((generation, $0)) }
        }
        if let lastEnd, lastEnd.generation == generation { return lastEnd.end }
        return .stopped
    }

    func pause() {
        guard state == .speaking else { return }
        pipeline.pause()
        state = .paused
    }

    func resume() {
        guard state == .paused else { return }
        pipeline.resume()
        state = .speaking
        startTicking()
    }

    func stop() {
        if state != .idle { ended(.stopped) }
        pipeline.stop()
        finish()
    }

    /// Shows `presence` between speeches (`none` or nil: none).
    func show(presence: Presence.State?) {
        self.presence = presence == Presence.State.none ? nil : presence
        if ticker == nil { startTicking() }
    }

    /// A one-shot nod, while the face shows presence and isn't speaking: a phrase was heard.
    func nod() {
        guard presence != nil, state == .idle else { return }
        cues.phraseEnded(at: cueTime)
        nodDepth = Self.fullNodDepth
        nodStarted = Date()
    }

    /// Words heard so far in the phrase being spoken to the face: now and then a small nod, and the
    /// face attentive while they keep coming.
    func hear(_ text: String) {
        guard presence == .listening, state == .idle else { return }
        let words = text.split(whereSeparator: \.isWhitespace).count
        if cues.heard(words: words, at: cueTime) {
            nodDepth = Self.softNodDepth
            nodStarted = Date()
        }
        if ticker == nil { startTicking() }
    }

    /// Seconds on the clock `cues` keep time by.
    private var cueTime: Double {
        let elapsed = ContinuousClock.now - cueClock
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }

    private func didFinish(_ finished: UInt64) {
        guard finished == generation, state != .idle else { return }
        ended(.finished)
        finish()
    }

    /// Records how the current utterance ended and tells those waiting for it.
    private func ended(_ end: SpeechEnd) {
        lastEnd = (generation, end)
        let waiting = endWaiters.filter { $0.generation == generation }
        endWaiters.removeAll { $0.generation == generation }
        for waiter in waiting { waiter.continuation.resume(returning: end) }
    }

    private func finish() {
        state = .idle
        currentWordRange = nil
        // The ticker keeps running until the mouth and brows have settled.
        if ticker == nil { startTicking() }
    }

    /// Polls the pipeline every frame while speaking and morphs the mouth toward what is heard.
    /// When paused, it lets the mouth settle to rest and then stops polling until resumed.
    private func startTicking() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    private func tick() {
        let snapshot = pipeline.snapshot()
        let current = state == .speaking ? snapshot.viseme : .rest
        // Louder sounds open the mouth a little wider.
        let target = current.shape.opened(by: 0.6 + 0.5 * Self.loudness(forRMS: snapshot.level))
        let next = mouth.interpolated(to: target, amount: 0.45)
        let mouthMoving = next.distance(to: mouth) > 0.05
        mouth = mouthMoving ? next : target

        let now = ContinuousClock.now
        if state == .speaking, let word = snapshot.wordRange, word != currentWordRange {
            currentWordRange = word
            mood = script.mood(at: word.location)
            // The voice's own stress on the word, once its audio has been rendered.
            let accent = pipeline.prosody(ofWordAt: word)?.accent
            // The end of a question or exclamation always gets its raise, even hard on the
            // heels of another move.
            if let hold = Emphasis.brows(for: word, in: spokenText, accent: accent),
               now >= nextBrowMove || hold >= Emphasis.exclaimedLift {
                browHold = hold
                // A frown or a big raise lingers a little longer than a plain raise.
                browHoldUntil = now + .milliseconds(hold > 0 && hold < Emphasis.exclaimedLift ? 420 : 550)
                nextBrowMove = now + .milliseconds(800)
            }
        }
        // Away from rest quickly, back slowly.
        let browTarget = state == .speaking && now < browHoldUntil ? browHold : 0
        brows = Self.approach(brows, browTarget, rate: abs(browTarget) > abs(brows) ? 0.25 : 0.08)
        // The mood holds through a pause and fades once the speech is over.
        let expressionTarget = state == .idle ? FaceExpression.neutral : mood.face
        expression = expression.approaching(expressionTarget, rate: 0.06)
        // The presence pose eases in and out over about a quarter of a second; neutral while speaking.
        // Listening, it follows the words coming in and the pauses between them.
        let cueNow = cueTime
        let hearing = presence == .listening && cues.isHearing(at: cueNow)
        if hearing != isHearing { isHearing = hearing }
        let poseTarget = state == .idle
            ? PresencePose.target(for: presence, hearing: hearing,
                                  glancing: presence == .listening && cues.isGlancing(at: cueNow))
            : PresencePose.neutral
        presencePose = presencePose.approaching(poseTarget, rate: 0.2)
        let posesSettled = presencePose == poseTarget && !(presence == .listening && cues.isActive(at: cueNow))

        if state != .speaking, !mouthMoving, brows == 0, expression == expressionTarget, posesSettled {
            ticker?.cancel()
            ticker = nil
        }
    }

    /// Moves `value` a fraction of the way to `target`, snapping to it when close.
    private static func approach(_ value: Double, _ target: Double, rate: Double) -> Double {
        let next = value + (target - value) * rate
        return abs(next - target) < 0.005 ? target : next
    }

    /// The highest-quality installed voice with this name ("Samantha", "Samantha (Enhanced)"…).
    static func bestVoice(named name: String,
                          among voices: [AVSpeechSynthesisVoice] = AVSpeechSynthesisVoice.speechVoices()) -> AVSpeechSynthesisVoice? {
        voices
            .filter { isVoice($0.name, named: name) }
            .max { $0.quality.rawValue < $1.quality.rawValue }
    }

    /// Whether `voiceName` is `name` in any quality: better downloads are named "Samantha
    /// (Enhanced)" or "Samantha (Premium)".
    static func isVoice(_ voiceName: String, named name: String) -> Bool {
        voiceName == name || voiceName.hasPrefix(name + " (")
    }

    /// Maps speech RMS (roughly 0 ... 0.25 for system voices) to 0 ... 1.
    private static func loudness(forRMS rms: Float) -> Double {
        let gated = max(0, Double(rms) - 0.01)
        return min(1, pow(gated / 0.2, 0.8))
    }
}
