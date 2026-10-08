import Foundation
import Testing
@testable import Avatar

/// Speaks nothing: each utterance "lasts" `duration`, or until stopped; records what was said.
@MainActor
final class FakeVoice: AvatarVoice {
    var gender: Gender = .male
    private(set) var said: [String] = []
    private(set) var presences: [Presence.State?] = []
    private(set) var nods = 0
    private(set) var heard: [String] = []
    private var generation: UInt64 = 0
    private var stopped: UInt64 = 0
    let duration: Duration

    init(duration: Duration = .milliseconds(40)) { self.duration = duration }

    func speak(_ text: String, mood: Mood?) -> UInt64? {
        said.append(text)
        generation += 1
        return generation
    }

    func end(of generation: UInt64) async -> SpeechEnd {
        let deadline = ContinuousClock.now + duration
        while ContinuousClock.now < deadline {
            if stopped >= generation { return .stopped }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return stopped >= generation ? .stopped : .finished
    }

    func stop() { stopped = generation }
    private(set) var paused = false
    func pause() { paused = true }
    func resume() { paused = false }
    func show(presence: Presence.State?) { presences.append(presence) }
    func nod() { nods += 1 }
    func hear(_ text: String) { heard.append(text) }
    var currentWordRange: NSRange?
}

/// Hears nothing unless told to; records being started and stopped.
@MainActor
final class FakeEars: AvatarEars {
    var onStateChange: ((SpeechInputController.State) -> Void)?
    var onVolatile: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    private(set) var starts = 0
    private(set) var stops = 0
    private(set) var running = false

    func start() async {
        starts += 1
        running = true
        onStateChange?(.listening)
    }

    func stop() async {
        stops += 1
        running = false
        onStateChange?(.idle)
    }
}

/// The events one session receives.
@MainActor
final class Inbox {
    private(set) var events: [AvatarEvent] = []
    func add(_ event: AvatarEvent) { events.append(event) }
    var types: [String] { events.map(\.type) }
}

@MainActor
func eventually(_ condition: () -> Bool) async {
    for _ in 0..<300 where !condition() {
        try? await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor
struct ConductorTests {
    private func make(duration: Duration = .milliseconds(40)) -> (Conductor, FakeVoice, FakeEars) {
        let voice = FakeVoice(duration: duration)
        let ears = FakeEars()
        return (Conductor(voice: voice, ears: ears, quietBeforeListening: .milliseconds(30)), voice, ears)
    }

    @Test func segmentsAreSpokenInOrderAndReportedToTheirSession() async {
        let (conductor, voice, _) = make()
        let inbox = Inbox()
        conductor.attach("s1") { inbox.add($0) }
        #expect(conductor.say(session: "s1", reply: "r1", text: "First **one**.", mood: nil) == 1)
        #expect(conductor.say(session: "s1", reply: "r1", text: "Second one.", mood: .happy, key: "k2") == 2)
        await eventually { inbox.types.filter { $0 == "segment.finished" }.count == 2 }
        #expect(voice.said == ["First one.", "Second one."])
        #expect(inbox.events.last == AvatarEvent(type: "segment.finished", reply: "r1", segment: 2, key: "k2"))
        #expect(inbox.events.dropFirst().map { "\($0.type) \($0.segment ?? 0)" }
                == ["segment.started 1", "segment.finished 1", "segment.started 2", "segment.finished 2"])
    }

    @Test func nothingToSayQueuesNothing() {
        let (conductor, _, _) = make()
        conductor.attach("s1") { _ in }
        #expect(conductor.say(session: "s1", reply: "r1", text: "---", mood: nil) == nil)
        #expect(conductor.say(session: "nobody", reply: "r1", text: "Hi.", mood: nil) == nil)
    }

    @Test func stopTakesBackOnlyThatSessionsSpeech() async {
        let (conductor, voice, _) = make(duration: .seconds(5))
        let one = Inbox(), two = Inbox()
        conductor.attach("s1") { one.add($0) }
        conductor.attach("s2") { two.add($0) }
        _ = conductor.say(session: "s1", reply: "a", text: "Long one.", mood: nil)
        _ = conductor.say(session: "s1", reply: "a", text: "Waiting one.", mood: nil)
        _ = conductor.say(session: "s2", reply: "b", text: "Other one.", mood: nil)
        await eventually { voice.said == ["Long one."] }
        conductor.stop("s1")
        await eventually { voice.said.count == 2 }
        #expect(voice.said == ["Long one.", "Other one."])
        #expect(one.types.filter { $0 == "segment.stopped" }.count == 2)
        conductor.stop("s2")
    }

    @Test func detachingTakesBackSpeechAndTheMicrophone() async {
        let (conductor, _, ears) = make()
        conductor.attach("s1") { _ in }
        conductor.setListening(session: "s1", on: true)
        await eventually { ears.running }
        conductor.detach("s1")
        await eventually { !ears.running }
        #expect(!ears.running)
        #expect(conductor.listener == nil)
        #expect(conductor.sessionCount == 0)
    }

    @Test func theMicrophoneNeverListensWhileTheAvatarSpeaks() async {
        let (conductor, voice, ears) = make(duration: .milliseconds(80))
        let inbox = Inbox()
        conductor.attach("s1") { inbox.add($0) }
        conductor.setListening(session: "s1", on: true)
        await eventually { ears.running }
        #expect(ears.starts == 1)

        _ = conductor.say(session: "s1", reply: "r", text: "Hello there.", mood: nil)
        // Off before the first word.
        #expect(!conductor.isListening)
        await eventually { !ears.running }
        await eventually { voice.said.count == 1 }
        #expect(!ears.running)
        // Back on once it has finished, after a moment's quiet.
        await eventually { ears.running }
        #expect(ears.starts == 2)
    }

    @Test func wordsHeardAfterTheMicrophoneClosedAreDropped() async {
        let (conductor, voice, ears) = make(duration: .milliseconds(200))
        let inbox = Inbox()
        conductor.attach("s1") { inbox.add($0) }
        conductor.setListening(session: "s1", on: true)
        await eventually { ears.running }
        _ = conductor.say(session: "s1", reply: "r", text: "Hello there.", mood: nil)
        // The recogniser finishes a phrase late: the avatar's own first words.
        ears.onVolatile?("Hello")
        ears.onFinal?("Hello there.")
        #expect(!inbox.types.contains("ears.final"))
        #expect(!inbox.types.contains("ears.volatile"))
        #expect(voice.heard.isEmpty)
        conductor.stop("s1")
    }

    @Test func noListeningWhileATurnRuns() async {
        let (conductor, _, ears) = make()
        conductor.attach("s1") { _ in }
        conductor.setState(session: "s1", presence: .thinking, turnRunning: true)
        conductor.setListening(session: "s1", on: true)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!ears.running)
        conductor.setState(session: "s1", presence: .listening, turnRunning: false)
        await eventually { ears.running }
        #expect(ears.running)
    }

    @Test func whatIsHeardGoesToTheListenerAndTheFace() async {
        let (conductor, voice, ears) = make()
        let one = Inbox(), two = Inbox()
        conductor.attach("s1") { one.add($0) }
        conductor.attach("s2") { two.add($0) }
        conductor.setListening(session: "s1", on: true)
        conductor.setListening(session: "s2", on: true)   // the last to ask has it
        await eventually { ears.running }
        #expect(one.events.contains(AvatarEvent(type: "ears.state", state: "taken")))
        ears.onVolatile?("send the")
        ears.onFinal?(" Send it. ")
        ears.onFinal?("  ")
        #expect(two.events.suffix(2) == [AvatarEvent(type: "ears.volatile", text: "send the"),
                                         AvatarEvent(type: "ears.final", text: "Send it.")])
        #expect(voice.heard == ["send the"])
        #expect(voice.nods == 1)
        #expect(!one.types.contains("ears.final"))
    }

    @Test func theBubbleHoldsTheReplyAndReplaySaysItAgain() async {
        let (conductor, voice, _) = make()
        conductor.attach("s1") { _ in }
        _ = conductor.say(session: "s1", reply: "r1", text: "[happy] One.", mood: nil)
        _ = conductor.say(session: "s1", reply: "r1", text: "Two.", mood: nil)
        #expect(conductor.bubble.text == "One. Two.")
        await eventually { voice.said.count == 2 && conductor.current == nil }
        // A new reply starts a new bubble.
        _ = conductor.say(session: "s1", reply: "r2", text: "Three.", mood: nil)
        #expect(conductor.bubble.text == "Three.")
        await eventually { voice.said.count == 3 && conductor.current == nil }
        conductor.replay()
        await eventually { voice.said.count == 4 && conductor.current == nil }
        #expect(voice.said.last == "Three.")
        #expect(conductor.bubble.text == "Three.")
    }

    @Test func playFromTheMiddleOfASentenceSaysTheRestThenTheSentencesAfter() async {
        let (conductor, voice, _) = make(duration: .milliseconds(100))
        conductor.attach("s1") { _ in }
        _ = conductor.say(session: "s1", reply: "r1", text: "Hello there world.", mood: nil)
        _ = conductor.say(session: "s1", reply: "r1", text: "Second one.", mood: nil)
        await eventually { voice.said.count == 2 && conductor.current == nil }
        // Inside "there": from the start of the word.
        conductor.play(from: 8)
        await eventually { conductor.current?.text == "there world." }
        #expect(conductor.current?.position == 0 && conductor.current?.offset == 6)
        await eventually { voice.said.count == 4 && conductor.current == nil }
        #expect(voice.said.suffix(2) == ["there world.", "Second one."])
        #expect(conductor.bubble.text == "Hello there world. Second one.")
        // Just past the period: the sentence's last word. On the space after it: the next sentence.
        conductor.play(from: 18)
        await eventually { voice.said.count == 6 && conductor.current == nil }
        #expect(voice.said.suffix(2) == ["world.", "Second one."])
        conductor.play(from: 19)
        await eventually { voice.said.count == 7 && conductor.current == nil }
        #expect(voice.said.last == "Second one.")
    }

    @Test func offsetsAreUTF16() async {
        let (conductor, voice, _) = make(duration: .seconds(5))
        conductor.attach("s1") { _ in }
        _ = conductor.say(session: "s1", reply: "r1", text: "𝒳 naïve café über.", mood: nil)
        _ = conductor.say(session: "s1", reply: "r1", text: "Next.", mood: nil)
        await eventually { conductor.current != nil }
        // "über" starts at UTF-16 offset 14 (𝒳 takes two).
        conductor.play(from: 15)
        await eventually { conductor.current?.text == "über." }
        #expect(conductor.current?.offset == 14)
        // Stopped on its first word: the caret is back on "über".
        voice.currentWordRange = NSRange(location: 0, length: 5)
        conductor.stopAll()
        #expect(conductor.bubble.caret == 14)
    }

    @Test func stopLeavesTheCaretOnTheWordAndPlayResumesThere() async {
        let (conductor, voice, _) = make(duration: .seconds(5))
        conductor.attach("s1") { _ in }
        _ = conductor.say(session: "s1", reply: "r1", text: "One two three.", mood: nil)
        await eventually { conductor.current != nil }
        voice.currentWordRange = NSRange(location: 4, length: 3)
        conductor.stopAll()
        #expect(conductor.bubble.caret == 4)
        await eventually { conductor.current == nil }
        voice.currentWordRange = nil
        conductor.playPause()
        await eventually { voice.said.count == 2 }
        #expect(voice.said.last == "two three.")
        conductor.stop("s1")
    }

    @Test func pausePutsTheCaretOnTheWordAndAMovedCaretPlaysFromThere() async {
        let (conductor, voice, _) = make(duration: .seconds(5))
        conductor.attach("s1") { _ in }
        _ = conductor.say(session: "s1", reply: "r1", text: "One two three.", mood: nil)
        await eventually { conductor.current != nil }
        voice.currentWordRange = NSRange(location: 4, length: 3)
        conductor.playPause()
        #expect(conductor.isPaused && conductor.bubble.caret == 4)
        // Not moved: Play resumes.
        conductor.playPause()
        #expect(!conductor.isPaused && !voice.paused && voice.said.count == 1)
        conductor.playPause()
        conductor.moveCaret(to: 8)
        voice.currentWordRange = nil
        conductor.playPause()
        await eventually { voice.said.count == 2 }
        #expect(voice.said.last == "three.")
        #expect(!conductor.isPaused)
        conductor.stop("s1")
    }

    @Test func finishingOrANewReplyPutsTheCaretBackAtTheTop() async {
        let (conductor, voice, _) = make()
        conductor.attach("s1") { _ in }
        _ = conductor.say(session: "s1", reply: "r1", text: "A b.", mood: nil)
        await eventually { voice.said.count == 1 && conductor.current == nil }
        conductor.moveCaret(to: 2)
        #expect(conductor.bubble.caret == 2)
        conductor.playPause()
        await eventually { voice.said.count == 2 && conductor.current == nil }
        #expect(voice.said.last == "b.")
        #expect(conductor.bubble.caret == nil)
        conductor.moveCaret(to: 2)
        _ = conductor.say(session: "s1", reply: "r2", text: "C.", mood: nil)
        #expect(conductor.bubble.caret == nil)
    }

    @Test func afterTheWindowsStopTheRestOfTheReplyWaitsForPlay() async {
        let (conductor, voice, _) = make(duration: .milliseconds(200))
        conductor.attach("s1") { _ in }
        _ = conductor.say(session: "s1", reply: "r1", text: "One.", mood: nil)
        await eventually { conductor.current != nil }
        conductor.stopAll()
        await eventually { conductor.current == nil }
        // Claude writes on: into the bubble, unsaid.
        #expect(conductor.say(session: "s1", reply: "r1", text: "Two.", mood: nil) == nil)
        #expect(conductor.bubble.text == "One. Two.")
        try? await Task.sleep(for: .milliseconds(50))
        #expect(voice.said == ["One."] && conductor.current == nil)
        // Play clears the hold: from the caret (the top), then what arrives next.
        conductor.playPause()
        #expect(conductor.say(session: "s1", reply: "r1", text: "Three.", mood: nil) != nil)
        await eventually { voice.said.count == 4 && conductor.current == nil }
        #expect(voice.said == ["One.", "One.", "Two.", "Three."])
        // A new reply isn't held.
        _ = conductor.say(session: "s1", reply: "r2", text: "Four.", mood: nil)
        await eventually { conductor.current != nil }
        conductor.stopAll()
        await eventually { conductor.current == nil }
        _ = conductor.say(session: "s1", reply: "r3", text: "Five.", mood: nil)
        await eventually { voice.said.last == "Five." }
        // The mod's own stop doesn't hold.
        conductor.stop("s1")
        await eventually { conductor.current == nil }
        #expect(conductor.say(session: "s1", reply: "r3", text: "Six.", mood: nil) != nil)
        await eventually { voice.said.last == "Six." && conductor.current == nil }
    }

    @Test func aNewTurnMarksTheBubbleAsThePreviousReplyUntilItSpeaks() async {
        let (conductor, voice, _) = make()
        conductor.attach("s1") { _ in }
        conductor.setState(session: "s1", presence: .thinking, turnRunning: true)
        _ = conductor.say(session: "s1", reply: "t1", text: "One.", mood: nil)
        #expect(!conductor.bubble.isPrevious)
        await eventually { voice.said.count == 1 && conductor.current == nil }
        // Between the turn's steps it stays this turn's reply.
        conductor.setState(session: "s1", presence: .thinking, turnRunning: true)
        #expect(!conductor.bubble.isPrevious)
        conductor.setState(session: "s1", presence: Presence.State.none, turnRunning: false)
        conductor.setState(session: "s1", presence: .thinking, turnRunning: true)
        #expect(conductor.bubble.isPrevious && conductor.bubble.text == "One.")
        _ = conductor.say(session: "s1", reply: "t2", text: "Two.", mood: nil)
        #expect(!conductor.bubble.isPrevious && conductor.bubble.text == "Two.")
        conductor.stop("s1")
    }

    @Test func playPausePausesAndResumesAndPlaysTheLastReplyWhenIdle() async {
        let (conductor, voice, _) = make(duration: .milliseconds(300))
        conductor.attach("s1") { _ in }
        _ = conductor.say(session: "s1", reply: "r1", text: "Hello.", mood: nil)
        await eventually { conductor.current != nil }
        conductor.playPause()
        #expect(conductor.isPaused && voice.paused)
        conductor.playPause()
        #expect(!conductor.isPaused && !voice.paused)
        await eventually { conductor.current == nil }
        // Nothing being said: Play says the last reply again.
        conductor.playPause()
        await eventually { voice.said.count == 2 }
        #expect(voice.said == ["Hello.", "Hello."])
        conductor.stop("s1")
    }

    @Test func stopAllSilencesEverySession() async {
        let (conductor, voice, _) = make(duration: .seconds(5))
        conductor.attach("s1") { _ in }
        conductor.attach("s2") { _ in }
        _ = conductor.say(session: "s1", reply: "a", text: "Long.", mood: nil)
        _ = conductor.say(session: "s2", reply: "b", text: "Other.", mood: nil)
        await eventually { voice.said.count == 1 }
        conductor.stopAll()
        await eventually { conductor.current == nil }
        #expect(conductor.queued.isEmpty)
        #expect(voice.said == ["Long."])
    }

    @Test func theWindowsMicButtonTellsItsSession() async {
        let (conductor, _, ears) = make()
        let inbox = Inbox()
        conductor.attach("s1") { inbox.add($0) }
        conductor.toggleMic()
        #expect(conductor.listener == "s1")
        #expect(inbox.events.last == AvatarEvent(type: "mic", state: "on"))
        await eventually { ears.running }
        conductor.toggleMic()
        #expect(conductor.listener == nil)
        #expect(inbox.events.last == AvatarEvent(type: "mic", state: "off"))
    }

    @Test func faceChangesReachEverySession() {
        let (conductor, voice, _) = make()
        let inbox = Inbox()
        conductor.attach("s1") { inbox.add($0) }
        #expect(inbox.events == [AvatarEvent(type: "attached", face: "male")])
        conductor.setGender(.female)
        #expect(voice.gender == .female)
        #expect(inbox.events.last == AvatarEvent(type: "face", face: "female"))
    }
}

@MainActor
struct RoutesTests {
    @Test func routesDriveTheConductor() {
        let voice = FakeVoice()
        let conductor = Conductor(voice: voice, ears: FakeEars())
        let routes = AvatarRoutes(conductor: conductor, version: "test")
        let body = { (json: String) in Data(json.utf8) }
        #expect(routes.handle(method: "POST", path: "/say", body: body(#"{"session":"x","reply":"r","text":"Hi."}"#)).status == 409)
        conductor.attach("x") { _ in }
        #expect(routes.handle(method: "POST", path: "/say", body: body(#"{"session":"x","reply":"r","text":"Hi."}"#))
                == .json(200, ["queued": true, "segment": 1]))
        #expect(routes.handle(method: "POST", path: "/say", body: body(#"{"session":"x","text":"Hi."}"#)).status == 400)
        #expect(routes.handle(method: "POST", path: "/face", body: body(#"{"face":"female"}"#)).status == 200)
        #expect(voice.gender == .female)
        #expect(routes.handle(method: "POST", path: "/state", body: body(#"{"session":"x","presence":"thinking"}"#)).status == 200)
        #expect(voice.presences.last == .thinking)
        #expect(routes.handle(method: "GET", path: "/status", body: Data()).body.contains(#""sessions":1"#))
        #expect(routes.handle(method: "POST", path: "/nowhere", body: body(#"{"session":"x"}"#)).status == 404)
        conductor.stop("x")
    }

    @Test func requestsSplitAcrossReadsAreParsedWhole() {
        let full = Data("POST /stop HTTP/1.1\r\nContent-Length: 15\r\n\r\n{\"session\":\"x\"}".utf8)
        #expect(HTTPRequest.parse(full.prefix(full.count - 2)) == nil)
        #expect(HTTPRequest.parse(full) == HTTPRequest(method: "POST", path: "/stop", body: Data(#"{"session":"x"}"#.utf8)))
    }
}

/// The two sockets, as the mod and `avatar-link` use them.
@MainActor
struct ServerTests {
    private func path(_ name: String) -> String {
        NSTemporaryDirectory() + "av-\(name)-\(UUID().uuidString.prefix(6)).sock"
    }

    /// One HTTP request over a Unix socket: the status and body.
    nonisolated private static func post(_ path: String, _ route: String, _ body: String) -> (Int, String) {
        guard let fd = LocalSocket.connect(to: path) else { return (0, "") }
        defer { close(fd) }
        LocalSocket.write(Data("POST \(route) HTTP/1.1\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8), to: fd)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &buffer, buffer.count)
            guard count > 0 else { break }
            data.append(contentsOf: buffer[0..<count])
        }
        let text = String(decoding: data, as: UTF8.self)
        let status = Int(text.split(separator: " ").dropFirst().first ?? "") ?? 0
        return (status, text.components(separatedBy: "\r\n\r\n").dropFirst().joined())
    }

    @Test func attachThenSayOverTheSockets() async throws {
        let voice = FakeVoice()
        let conductor = Conductor(voice: voice, ears: FakeEars())
        let routes = AvatarRoutes(conductor: conductor, version: "test")
        let commandPath = path("cmd"), attachPath = path("att")
        let commands = CommandServer(path: commandPath) { routes.handle(method: $0, path: $1, body: $2) }
        let attach = AttachServer(path: attachPath,
                                  attach: { session, send in conductor.attach(session, send: send) },
                                  detach: { session in conductor.detach(session) })
        try commands.start()
        try attach.start()
        defer { commands.stop(); attach.stop() }
        let mode = try FileManager.default.attributesOfItem(atPath: commandPath)[.posixPermissions] as? Int
        #expect(mode == 0o600)

        // What avatar-link does: attach, then read events.
        let fd = try #require(LocalSocket.connect(to: attachPath))
        LocalSocket.write(Data(#"{"type":"attach","session":"s1"}"#.utf8 + [0x0A]), to: fd)
        await eventually { conductor.isAttached("s1") }

        let answer = await Task.detached { Self.post(commandPath, "/say", #"{"session":"s1","reply":"r1","text":"Hello."}"#) }.value
        #expect(answer.0 == 200)
        #expect(answer.1 == #"{"queued":true,"segment":1}"#)

        let lines = await Task.detached { () -> String in
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while !String(decoding: data, as: UTF8.self).contains("segment.finished") {
                let count = read(fd, &buffer, buffer.count)
                guard count > 0 else { break }
                data.append(contentsOf: buffer[0..<count])
            }
            return String(decoding: data, as: UTF8.self)
        }.value
        #expect(lines.contains(#"{"face":"male","type":"attached"}"#))
        #expect(lines.contains(#"{"reply":"r1","segment":1,"type":"segment.started"}"#))
        #expect(voice.said == ["Hello."])

        // Closing the connection detaches the session.
        close(fd)
        await eventually { !conductor.isAttached("s1") }
        #expect(!conductor.isAttached("s1"))
    }
}
