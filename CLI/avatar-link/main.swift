import Foundation

// avatar-link: a Claude Code session's handle on the avatar (the Presence mod runs it).
//
//   avatar-link attach <session>
//
// Connects to the avatar's attach socket, attaches the session, and copies every event that comes
// back to standard output, one JSON object per line, until the avatar closes the connection (exit 0)
// or this process is ended, which takes back the session's speech and microphone. With no avatar
// running it prints {"type":"unavailable"} and exits 3, so the caller can try again later.

func printLine(_ text: String) {
    FileHandle.standardOutput.write(Data((text + "\n").utf8))
}

func socketPath() -> String {
    if let path = ProcessInfo.processInfo.environment["AVATAR_ATTACH_SOCKET"], !path.isEmpty { return path }
    return FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Avatar/attach.sock").path
}

func connect(_ path: String) -> Int32? {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
        raw.copyBytes(from: bytes)
        raw[bytes.count] = 0
    }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    let result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    // Only an avatar run by this same user.
    var uid: uid_t = 0, gid: gid_t = 0
    guard result == 0, getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
        close(fd)
        return nil
    }
    return fd
}

let arguments = CommandLine.arguments.dropFirst()
guard arguments.first == "attach", arguments.count == 2, let session = arguments.last, !session.isEmpty else {
    FileHandle.standardError.write(Data("usage: avatar-link attach <session>\n".utf8))
    exit(2)
}

guard let fd = connect(socketPath()) else {
    printLine(#"{"type":"unavailable"}"#)
    exit(3)
}

let request = try JSONSerialization.data(withJSONObject: ["type": "attach", "session": session], options: [.sortedKeys])
let line = request + Data([0x0A])
_ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }

// Copy the avatar's events to standard output, line by line, until it closes the connection.
var buffer = [UInt8](repeating: 0, count: 64 * 1024)
var pending = Data()
while true {
    let count = read(fd, &buffer, buffer.count)
    if count < 0, errno == EINTR { continue }
    guard count > 0 else { break }
    pending.append(contentsOf: buffer[0..<count])
    while let newline = pending.firstIndex(of: 0x0A) {
        let event = pending[pending.startIndex..<newline]
        pending = Data(pending[pending.index(after: newline)...])
        if !event.isEmpty { printLine(String(decoding: event, as: UTF8.self)) }
    }
}
exit(0)
