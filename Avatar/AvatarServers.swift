import Foundation

// How the Presence mod reaches the avatar. A mod can make HTTP requests over a Unix socket and read a
// child process's output, but can't keep a socket open, so:
//
// - `attach.sock` (line protocol): `avatar-link attach <session>` sends {"type":"attach","session"}
//   and prints the events that come back (`AvatarEvent`, one JSON object per line). That connection is
//   the session: when it closes, its speech and its microphone go.
// - `avatar.sock` (HTTP/1.1, one request per connection, JSON both ways), naming the session:
//
//   POST /say     {session, reply, text, mood?, key?} → {segment} or {queued:false}; `key` is echoed
//                                                   in the segment's events
//   POST /reply/end {session, reply}
//   POST /stop    {session}
//   POST /replay  {session}                       the last reply again, from the top
//   POST /state   {session, presence?: listening|thinking|none, turn?: running|idle}
//   POST /listen  {session, on}
//   POST /face    {face: male|female}
//   GET  /status                                  → {app, version, sessions, face, listening}

/// An HTTP answer: a status and a JSON body.
nonisolated struct AvatarResponse: Equatable, Sendable {
    var status: Int
    var body: String

    static func json(_ status: Int, _ object: [String: Any]) -> AvatarResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return AvatarResponse(status: status, body: String(decoding: data, as: UTF8.self))
    }

    static func error(_ status: Int, _ message: String) -> AvatarResponse { .json(status, ["error": message]) }
}

/// The HTTP routes, on the main actor (the conductor is).
@MainActor
struct AvatarRoutes {
    let conductor: Conductor
    let version: String

    func handle(method: String, path: String, body: Data) -> AvatarResponse {
        if path != "/status", path != "/debug" {
            conductor.log("\(method) \(path) \(String(decoding: body.prefix(160), as: UTF8.self))")
        }
        if method == "GET", path == "/debug" {
            return .json(200, ["state": conductor.debugState, "log": conductor.debugLog])
        }
        if method == "GET", path == "/status" {
            return .json(200, ["app": "Avatar", "version": version, "sessions": conductor.sessionCount,
                               "face": conductor.gender.rawValue, "listening": conductor.isListening])
        }
        guard method == "POST" else { return .error(405, "Use POST.") }
        let fields = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        if path == "/face" {
            guard let face = (fields["face"] as? String).flatMap(Gender.init(rawValue:)) else {
                return .error(400, "Name the face: male or female.")
            }
            conductor.setGender(face)
            return .json(200, [:])
        }
        guard let session = fields["session"] as? String, conductor.isAttached(session) else {
            return .error(409, "Unknown session: attach it first (avatar-link attach <session>).")
        }
        switch path {
        case "/say":
            guard let text = fields["text"] as? String, let reply = fields["reply"] as? String else {
                return .error(400, "Missing text or reply.")
            }
            let mood = (fields["mood"] as? String).flatMap(Mood.init(rawValue:))
            guard let segment = conductor.say(session: session, reply: reply, text: text, mood: mood,
                                              key: fields["key"] as? String) else {
                return .json(200, ["queued": false])
            }
            return .json(200, ["queued": true, "segment": segment])
        case "/reply/end":
            guard let reply = fields["reply"] as? String else { return .error(400, "Missing reply.") }
            conductor.endReply(session: session, reply: reply)
            return .json(200, [:])
        case "/stop":
            conductor.stop(session)
            return .json(200, [:])
        case "/replay":
            conductor.replay()
            return .json(200, [:])
        case "/state":
            let presence = (fields["presence"] as? String).flatMap(Presence.State.init(rawValue:))
            let turn = (fields["turn"] as? String).map { $0 == "running" }
            conductor.setState(session: session, presence: presence, turnRunning: turn)
            return .json(200, [:])
        case "/listen":
            conductor.setListening(session: session, on: fields["on"] as? Bool ?? false)
            return .json(200, [:])
        default:
            return .error(404, "No such route: \(path)")
        }
    }
}

/// Serves `AvatarRoutes` as HTTP/1.1 on `avatar.sock`: one request per connection, `Connection: close`.
nonisolated final class CommandServer: @unchecked Sendable {
    private let path: String
    private let routes: @MainActor (String, String, Data) -> AvatarResponse
    private let queue = DispatchQueue(label: "com.sandipchitale.Avatar.commands")
    private var listener: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    static let maxRequestBytes = 1 << 20

    init(path: String = LocalSocket.commandPath,
         routes: @escaping @MainActor (String, String, Data) -> AvatarResponse) {
        self.path = path
        self.routes = routes
    }

    func start() throws {
        listener = try LocalSocket.listen(at: path)
        let source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptClient() }
        acceptSource = source
        source.resume()
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        if listener >= 0 { close(listener); listener = -1 }
        unlink(path)
    }

    private func acceptClient() {
        guard let fd = LocalSocket.acceptSameUser(listener) else { return }
        var received = Data()
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            let count = read(fd, &chunk, chunk.count)
            if count < 0, errno == EINTR || errno == EAGAIN { return }
            guard count > 0 else {
                source.cancel()
                return
            }
            received.append(contentsOf: chunk[0..<count])
            if received.count > Self.maxRequestBytes {
                Self.respond(fd, .error(413, "Request too large."))
                source.cancel()
                return
            }
            guard let request = HTTPRequest.parse(received) else { return }
            source.suspend()
            Task { @MainActor [weak self] in
                guard let self else { return }
                let response = self.routes(request.method, request.path, request.body)
                self.queue.async {
                    Self.respond(fd, response)
                    source.resume()
                    source.cancel()
                }
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    private static func respond(_ fd: Int32, _ response: AvatarResponse) {
        let body = Data(response.body.utf8)
        let head = "HTTP/1.1 \(response.status) \(HTTPRequest.reason(response.status))\r\n"
            + "Content-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        LocalSocket.write(Data(head.utf8) + body, to: fd)
    }
}

/// Just enough HTTP/1.1: a request line, headers, and a `Content-Length` body.
nonisolated struct HTTPRequest: Equatable {
    var method: String
    var path: String
    var body: Data

    /// The request in `data`, or nil while it is still incomplete.
    static func parse(_ data: Data) -> HTTPRequest? {
        guard let end = data.firstRange(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[data.startIndex..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return HTTPRequest(method: "", path: "", body: Data()) }
        var length = 0
        for line in lines {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == "content-length" {
                length = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        let bodyStart = end.upperBound
        guard data.distance(from: bodyStart, to: data.endIndex) >= length else { return nil }
        let body = Data(data[bodyStart..<data.index(bodyStart, offsetBy: length)])
        let target = String(requestLine[1])
        let path = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target
        return HTTPRequest(method: String(requestLine[0]), path: path, body: body)
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 400: "Bad Request"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 409: "Conflict"
        case 413: "Content Too Large"
        default: "Error"
        }
    }
}

/// Serves `attach.sock`: each connection attaches one session and receives its events until it closes.
nonisolated final class AttachServer: @unchecked Sendable {
    private let path: String
    private let attach: @MainActor (String, @escaping @Sendable (AvatarEvent) -> Void) -> Void
    private let detach: @MainActor (String) -> Void
    private let queue = DispatchQueue(label: "com.sandipchitale.Avatar.attach")
    private var listener: Int32 = -1
    private var acceptSource: DispatchSourceRead?

    init(path: String = LocalSocket.attachPath,
         attach: @escaping @MainActor (String, @escaping @Sendable (AvatarEvent) -> Void) -> Void,
         detach: @escaping @MainActor (String) -> Void) {
        self.path = path
        self.attach = attach
        self.detach = detach
    }

    func start() throws {
        listener = try LocalSocket.listen(at: path)
        let source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptClient() }
        acceptSource = source
        source.resume()
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        if listener >= 0 { close(listener); listener = -1 }
        unlink(path)
    }

    private func acceptClient() {
        guard let fd = LocalSocket.acceptSameUser(listener) else { return }
        var pending = Data()
        var session: String?
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let count = read(fd, &chunk, chunk.count)
            if count < 0, errno == EINTR || errno == EAGAIN { return }
            guard count > 0 else {
                source.cancel()
                return
            }
            pending.append(contentsOf: chunk[0..<count])
            guard session == nil, let newline = pending.firstIndex(of: 0x0A) else { return }
            let line = pending[pending.startIndex..<newline]
            pending = Data()
            guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  object["type"] as? String == "attach",
                  let name = object["session"] as? String, !name.isEmpty else {
                LocalSocket.write(AvatarEvent(type: "error", text: "Send {\"type\":\"attach\",\"session\":…} first.").line, to: fd)
                source.cancel()
                return
            }
            session = name
            let send: @Sendable (AvatarEvent) -> Void = { [queue = self.queue] event in
                queue.async { LocalSocket.write(event.line, to: fd) }
            }
            let attach = self.attach
            Task { @MainActor in attach(name, send) }
        }
        let detach = self.detach
        source.setCancelHandler {
            close(fd)
            if let name = session { Task { @MainActor in detach(name) } }
        }
        source.resume()
    }
}
