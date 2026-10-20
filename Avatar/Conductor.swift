import Foundation
import Observation

// The avatar's one owner of sound: what is said, in what order, and when it may listen.
//
// Claude Code sessions (each a Presence mod, attached through `avatar-link`) hand it reply segments to
// say, the face's state, and whether to listen. Segments are spoken first in, first out, each
// reported to its session as it starts and finishes.
// The microphone is opened only when nothing is being said or waiting to be said, no turn is
// running, and a moment has passed since the last word, so it never hears the avatar.

/// What the conductor needs of the face's voice: `SpeechEngine`, or a stand-in in tests.
@MainActor
protocol AvatarVoice: AnyObject {
    var gender: Gender { get set }
    func speak(_ text: String, mood: Mood?) -> UInt64?
    func end(of generation: UInt64) async -> SpeechEnd
    func stop()
    func pause()
    func resume()
    func show(presence: Presence.State?)
    func nod()
    /// Words heard so far in the phrase being spoken to the face (see `SpeechEngine.hear`).
    func hear(_ text: String)
    /// The word being said, within the utterance's text.
    var currentWordRange: NSRange? { get }
}

extension SpeechEngine: AvatarVoice {}

/// What the conductor needs of the ears: `SpeechInputController`, or a stand-in in tests.
@MainActor
protocol AvatarEars: AnyObject {
    var onStateChange: ((SpeechInputController.State) -> Void)? { get set }
    var onVolatile: ((String) -> Void)? { get set }
    var onFinal: ((String) -> Void)? { get set }
    func start() async
    func stop() async
}

extension SpeechInputController: AvatarEars {}

/// One line `avatar-link` prints for its session.
nonisolated struct AvatarEvent: Codable, Sendable, Equatable {
    var type: String
    var reply: String?
    var segment: Int?
    /// The caller's own name for the segment, echoed back (`/say`'s `key`).
    var key: String?
    var text: String?
    var state: String?
    var face: String?

    init(type: String, reply: String? = nil, segment: Int? = nil, key: String? = nil, text: String? = nil,
         state: String? = nil, face: String? = nil) {
        self.type = type; self.reply = reply; self.segment = segment; self.key = key
        self.text = text; self.state = state; self.face = face
    }

    var line: Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return ((try? encoder.encode(self)) ?? Data("{}".utf8)) + Data([0x0A])
    }
}

@MainActor
@Observable
final class Conductor {
    struct Segment: Equatable {
        var session: String
        var reply: String
        var number: Int
        var text: String
        var mood: Mood?
        var key: String?
        /// Where it sits in the bubble's reply (`bubble`): which sentence, and where in it (UTF-16) the
        /// utterance starts (0 unless played from a caret mid-sentence).
        var position = 0
        var offset = 0
        /// The bubble it belongs to (`Bubble.key` when it was queued).
        var bubbleKey = ""
    }

    private struct Attached {
        var send: (AvatarEvent) -> Void
        var turnRunning = false
    }

    @ObservationIgnored private let voice: AvatarVoice
    @ObservationIgnored private let ears: AvatarEars
    @ObservationIgnored private var sessions: [String: Attached] = [:]
    @ObservationIgnored private var queue: [Segment] = []
    @ObservationIgnored private var counters: [String: Int] = [:]
    @ObservationIgnored private var speaking: Task<Void, Never>?
    @ObservationIgnored private var earsCheck: Task<Void, Never>?
    /// How long after the last word the microphone may open.
    @ObservationIgnored let quietBeforeListening: Duration

    /// The segment being said now.
    private(set) var current: Segment?
    /// The voice is paused mid-segment (the window's Play/Pause).
    private(set) var isPaused = false
    /// The reply the speech bubble shows: the one being said, or last said, which Play says again.
    private(set) var bubble = Bubble()
    @ObservationIgnored private var replays = 0
    /// The session that last asked for anything: the one the window's Mic button works for.
    @ObservationIgnored private var activeSession: String?
    /// The session the microphone listens for (the last to turn listening on), if any.
    private(set) var listener: String?
    private(set) var isListening = false
    /// Attached sessions, for the menu.
    private(set) var sessionCount = 0
    /// Asks the app to show the face window (a session attached, or something is about to be said).
    @ObservationIgnored var onShowWindow: (() -> Void)?

    init(voice: AvatarVoice, ears: AvatarEars, quietBeforeListening: Duration = .milliseconds(800)) {
        self.voice = voice
        self.ears = ears
        self.quietBeforeListening = quietBeforeListening
        ears.onStateChange = { [weak self] state in self?.earsChanged(state) }
        // Heard text counts only while the microphone is meant to be open and nothing is being said:
        // a phrase finished after the microphone was told to stop may hold the avatar's own words.
        ears.onVolatile = { [weak self] text in
            guard let self, self.isListening, self.mayListen else { return }
            self.voice.hear(text)
            self.toListener(AvatarEvent(type: "ears.volatile", text: text))
        }
        ears.onFinal = { [weak self] text in
            let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let self, !words.isEmpty else { return }
            self.log("heard \(self.isListening && self.mayListen ? "" : "(dropped) ")\(words)")
            guard self.isListening, self.mayListen else { return }
            self.toListener(AvatarEvent(type: "ears.final", text: words))
        }
    }

    var gender: Gender { voice.gender }
    var queued: [Segment] { queue }

    // MARK: Sessions

    func attach(_ session: String, send: @escaping (AvatarEvent) -> Void) {
        sessions[session] = Attached(send: send)
        sessionCount = sessions.count
        activeSession = session
        send(AvatarEvent(type: "attached", face: voice.gender.rawValue))
        onShowWindow?()
    }

    /// The session's `avatar-link` ended: its speech and its microphone go with it.
    func detach(_ session: String) {
        guard sessions.removeValue(forKey: session) != nil else { return }
        sessionCount = sessions.count
        stop(session)
        if listener == session {
            listener = nil
            reconsiderEars()
        }
        counters = counters.filter { !$0.key.hasPrefix(Self.counterKey(session, "")) }
    }

    func isAttached(_ session: String) -> Bool { sessions[session] != nil }

    // MARK: Speech

    /// Queues one segment of `reply` (markdown); returns its number, or nil when there is nothing to
    /// say in it (no event will follow).
    func say(session: String, reply: String, text: String, mood: Mood?, key: String? = nil) -> Int? {
        let spoken = SpeakableText.from(markdown: text)
        guard isAttached(session), !spoken.isEmpty else { return nil }
        let counter = Self.counterKey(session, reply)
        activeSession = session
        // A new reply starts a new bubble (and becomes what Play says again).
        if counter != bubble.key { bubble = Bubble(key: counter, session: session) }
        bubble.append(spoken: spoken, mood: mood)
        // After the window's Stop, the rest of the reply waits for Play.
        if bubble.isHeld { return nil }
        return enqueue(session: session, reply: reply, text: spoken, mood: mood, key: key,
                       position: bubble.sentences.count - 1, offset: 0)
    }

    /// Queues one utterance of the bubble's reply and starts speaking; returns its number.
    private func enqueue(session: String, reply: String, text: String, mood: Mood?, key: String? = nil,
                         position: Int, offset: Int) -> Int {
        let counter = Self.counterKey(session, reply)
        let number = (counters[counter] ?? 0) + 1
        counters[counter] = number
        queue.append(Segment(session: session, reply: reply, number: number, text: text, mood: mood, key: key,
                             position: position, offset: offset, bubbleKey: bubble.key))
        stopEars()
        onShowWindow?()
        startSpeaking()
        return number
    }

    /// The reply has nothing more to say.
    func endReply(session: String, reply: String) {
        counters[Self.counterKey(session, reply)] = nil
    }

    /// Names a session's reply (for its segment numbers, and the bubble).
    private static func counterKey(_ session: String, _ reply: String) -> String { session + "\n" + reply }

    /// Takes back everything `session` asked to say: queued segments are dropped, the one being
    /// said stops.
    func stop(_ session: String) {
        let dropped = queue.filter { $0.session == session }
        queue.removeAll { $0.session == session }
        for segment in dropped { send(segment, "segment.stopped") }
        if let current, current.session == session {
            // Play picks up from the word that was being said.
            if let location = bubbleLocation(of: current) { bubble.caret = location }
            isPaused = false
            bubble.caretMoved = false
            voice.stop()
        }
        reconsiderEars()
    }

    /// Where in the bubble's text `segment` is: the word being said, else where it starts.
    private func bubbleLocation(of segment: Segment) -> Int? {
        guard segment.bubbleKey == bubble.key, segment.position < bubble.sentences.count else { return nil }
        return bubble.sentences[segment.position].start + segment.offset + (voice.currentWordRange?.location ?? 0)
    }

    /// The word being said, in the bubble's text.
    var spokenWord: NSRange? {
        guard let current, let word = voice.currentWordRange, let location = bubbleLocation(of: current) else { return nil }
        return NSRange(location: location, length: word.length)
    }

    private func startSpeaking() {
        guard speaking == nil else { return }
        speaking = Task { [weak self] in
            // The microphone is fully off before the first word.
            await self?.earsStopped()
            await self?.speakQueue()
            self?.speaking = nil
            self?.reconsiderEars()
        }
    }

    private func speakQueue() async {
        var end = SpeechEnd.finished
        while !queue.isEmpty {
            let segment = queue.removeFirst()
            current = segment
            send(segment, "segment.started")
            end = .finished
            if let generation = voice.speak(segment.text, mood: segment.mood) {
                end = await voice.end(of: generation)
            }
            current = nil
            send(segment, end == .finished ? "segment.finished" : "segment.stopped")
        }
        // Said to the end: Play says it again from the top.
        if end == .finished { bubble.caret = nil }
    }

    /// The window's Play/Pause: pauses or resumes what is being said (from the caret, if it was moved
    /// while paused); with nothing being said, plays the last reply from the caret.
    func playPause() {
        guard let current else {
            play(from: bubble.caret ?? 0)
            return
        }
        if isPaused {
            if bubble.caretMoved, let caret = bubble.caret {
                play(from: caret)
            } else {
                isPaused = false
                voice.resume()
            }
        } else {
            if let location = bubbleLocation(of: current) { bubble.caret = location }
            bubble.caretMoved = false
            isPaused = true
            voice.pause()
        }
    }

    /// The bubble's caret moved (by a click or a key).
    func moveCaret(to location: Int) {
        guard location != bubble.caret else { return }
        bubble.caret = location
        if isPaused { bubble.caretMoved = true }
    }

    /// The window's Stop: silence, whoever asked. What more arrives of the reply being said goes in
    /// the bubble unsaid, until Play.
    func stopAll() {
        if !bubble.key.isEmpty { bubble.isHeld = true }
        silenceAll()
    }

    private func silenceAll() {
        for session in Array(sessions.keys) { stop(session) }
    }

    /// The last reply again, from the top (`/replay`, "say that again").
    func replay() {
        play(from: 0)
    }

    /// Says the last reply from `location` in the bubble's text (UTF-16): the rest of the sentence
    /// there, from the start of the word, then the sentences after it. The bubble stays as it is.
    func play(from location: Int) {
        guard isAttached(bubble.session), !bubble.sentences.isEmpty else { return }
        bubble.isHeld = false
        bubble.caretMoved = false
        silenceAll()
        let session = bubble.session
        let sentences = bubble.sentences
        let index = bubble.sentence(at: location)
        let words = Words.ranges(in: sentences[index].shown)
        let offset = Words.containing(max(0, location - sentences[index].start), in: words)?.location ?? 0
        replays += 1
        let reply = "replay-\(replays)"
        for (position, sentence) in sentences.enumerated().dropFirst(index) {
            // Mid-sentence: the bubble's words from there on, in the mood they had there.
            let from = position == index ? offset : 0
            let text = from > 0 ? (sentence.shown as NSString).substring(from: from) : sentence.spoken
            let mood = from > 0 ? Script.parse(sentence.spoken, mood: sentence.mood).mood(at: from) : sentence.mood
            _ = enqueue(session: session, reply: reply, text: text, mood: mood, position: position, offset: from)
        }
        endReply(session: session, reply: reply)
    }

    /// The window's Mic button: listening for the most recent session, on or off; the session is told.
    func toggleMic() {
        if let listener {
            setListening(session: listener, on: false)
            sessions[listener]?.send(AvatarEvent(type: "mic", state: "off"))
        } else if let session = activeSession, isAttached(session) {
            setListening(session: session, on: true)
            sessions[session]?.send(AvatarEvent(type: "mic", state: "on"))
        }
    }

    private func send(_ segment: Segment, _ type: String) {
        sessions[segment.session]?.send(AvatarEvent(type: type, reply: segment.reply, segment: segment.number, key: segment.key))
    }

    // MARK: The face

    /// The face's state between speeches, and whether `session`'s turn is running (no listening then).
    func setState(session: String, presence: Presence.State?, turnRunning: Bool?) {
        activeSession = session
        if let presence { voice.show(presence: presence) }
        if let turnRunning, sessions[session] != nil {
            if turnRunning, sessions[session]?.turnRunning == false { bubble.isPrevious = true }
            sessions[session]?.turnRunning = turnRunning
            if turnRunning { stopEars() }
        }
        reconsiderEars()
    }

    func setGender(_ gender: Gender) {
        guard voice.gender != gender else { return }
        voice.gender = gender
        for attached in sessions.values { attached.send(AvatarEvent(type: "face", face: gender.rawValue)) }
    }

    // MARK: Diagnostics (GET /debug)

    @ObservationIgnored private(set) var debugLog: [String] = []

    func log(_ line: String) {
        let time = Date().formatted(.dateTime.hour().minute().second().secondFraction(.fractional(3)))
        debugLog.append("\(time) \(line)")
        if debugLog.count > 80 { debugLog.removeFirst(debugLog.count - 80) }
    }

    var debugState: [String: Any] {
        var turns: [String: Bool] = [:]
        for (name, attached) in sessions { turns[name] = attached.turnRunning }
        return ["turnRunning": turns, "listener": listener ?? "", "isListening": isListening,
                "speaking": current?.text ?? "", "queued": queue.count, "mayListen": mayListen]
    }

    // MARK: The ears

    /// `session` wants its words heard (or no longer). The last to ask has the microphone.
    func setListening(session: String, on: Bool) {
        guard sessions[session] != nil else { return }
        if on {
            if let previous = listener, previous != session {
                sessions[previous]?.send(AvatarEvent(type: "ears.state", state: "taken"))
            }
            listener = session
        } else if listener == session {
            listener = nil
        }
        reconsiderEars()
    }

    /// Nothing said, nothing waiting, no turn running, someone listening.
    var mayListen: Bool {
        guard let listener, let attached = sessions[listener] else { return false }
        return current == nil && queue.isEmpty && speaking == nil && !attached.turnRunning
    }

    /// Opens the microphone after a moment's quiet if it may listen; closes it at once if not.
    func reconsiderEars() {
        guard mayListen else {
            stopEars()
            return
        }
        guard !isListening, earsCheck == nil else { return }
        let quiet = quietBeforeListening
        earsCheck = Task { [weak self] in
            try? await Task.sleep(for: quiet)
            guard let self, !Task.isCancelled else { return }
            self.earsCheck = nil
            guard self.mayListen, !self.isListening else { return }
            self.isListening = true
            self.log("ears start")
            await self.ears.start()
        }
    }

    private func stopEars() {
        earsCheck?.cancel()
        earsCheck = nil
        guard isListening else { return }
        isListening = false
        log("ears stop")
        let ears = self.ears
        earsStopping = Task { await ears.stop() }
    }

    @ObservationIgnored private var earsStopping: Task<Void, Never>?

    /// Waits until the recogniser has actually stopped (stopping takes a moment).
    private func earsStopped() async {
        await earsStopping?.value
        earsStopping = nil
    }

    private func earsChanged(_ state: SpeechInputController.State) {
        let name: String
        switch state {
        case .idle: name = "idle"
        case .preparing: name = "preparing"
        case .listening: name = "listening"
        case .microphoneDenied: name = "denied"
        case .unavailable: name = "unavailable"
        }
        var event = AvatarEvent(type: "ears.state", state: name)
        if case .unavailable(let why) = state { event.text = why }
        if state == .microphoneDenied || { if case .unavailable = state { return true } else { return false } }() {
            isListening = false
        }
        toListener(event)
    }

    private func toListener(_ event: AvatarEvent) {
        guard let listener else { return }
        if event.type == "ears.final" { voice.nod() }
        sessions[listener]?.send(event)
    }
}

/// The reply the speech bubble shows, sentence by sentence, with where Play starts in it.
struct Bubble {
    struct Sentence {
        /// What `say` was given (mood cues kept) and its mood.
        var spoken: String
        var mood: Mood?
        /// What the bubble shows of it, and where that starts in `text` (UTF-16).
        var shown: String
        var start: Int
    }

    /// The session and reply it holds.
    var key = ""
    var session = ""
    var sentences: [Sentence] = []
    /// The sentences joined by spaces: what the bubble shows.
    var text = ""
    /// Where Play starts in `text` (UTF-16); nil: the top. Stop and Pause leave it on the word being
    /// said; the bubble's caret moves it.
    var caret: Int?
    /// The caret was moved while paused: Play plays from it rather than resuming.
    var caretMoved = false
    /// The window's Stop silenced it: what more of it arrives goes in, unsaid, until Play.
    var isHeld = false
    /// A turn has started since it was said (the bubble shows thinking instead).
    var isPrevious = false

    mutating func append(spoken: String, mood: Mood?) {
        let shown = Script.parse(spoken, mood: mood).text
        if !sentences.isEmpty { text += " " }
        sentences.append(Sentence(spoken: spoken, mood: mood, shown: shown, start: (text as NSString).length))
        text += shown
    }

    /// The sentence holding `location` in `text` (a space between two belongs to the first).
    func sentence(at location: Int) -> Int {
        sentences.lastIndex { $0.start <= location } ?? 0
    }
}
