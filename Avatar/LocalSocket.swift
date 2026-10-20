import Foundation

// Unix sockets for the Presence mod: in Avatar's 0700 folder, 0600, and only this user's processes.

nonisolated enum LocalSocket {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Avatar", isDirectory: true)
    }

    /// Commands (HTTP over the socket): `AVATAR_SOCKET` overrides it.
    static var commandPath: String {
        ProcessInfo.processInfo.environment["AVATAR_SOCKET"] ?? folder.appendingPathComponent("avatar.sock").path
    }

    /// Sessions and their events (`avatar-link attach`): `AVATAR_ATTACH_SOCKET` overrides it.
    static var attachPath: String {
        ProcessInfo.processInfo.environment["AVATAR_ATTACH_SOCKET"] ?? folder.appendingPathComponent("attach.sock").path
    }

    static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw Failure(description: "Socket path too long: \(path)")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }

    /// A listening socket at `path`, replacing a stale one; refuses when another app serves it.
    static func listen(at path: String) throws -> Int32 {
        let folder = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        chmod(folder, 0o700)
        if let probe = connect(to: path) {
            close(probe)
            throw Failure(description: "Another Avatar already serves \(path)")
        }
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure(description: "socket: \(errno)") }
        var address = try address(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else {
            close(fd)
            throw Failure(description: "bind \(path): \(errno)")
        }
        chmod(path, 0o600)
        guard Darwin.listen(fd, 16) == 0 else {
            close(fd)
            throw Failure(description: "listen: \(errno)")
        }
        return fd
    }

    /// Connects to `path`; nil when nothing listens there.
    static func connect(to path: String) -> Int32? {
        guard var address = try? address(path) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            close(fd)
            return nil
        }
        noSIGPIPE(fd)
        return fd
    }

    /// Accepts a connection, keeping it only when the peer runs as this user.
    static func acceptSameUser(_ listener: Int32) -> Int32? {
        let fd = accept(listener, nil, nil)
        guard fd >= 0 else { return nil }
        var credentials = xucred()
        var length = socklen_t(MemoryLayout<xucred>.size)
        guard getsockopt(fd, 0 /* SOL_LOCAL */, LOCAL_PEERCRED, &credentials, &length) == 0,
              credentials.cr_uid == getuid() else {
            close(fd)
            return nil
        }
        noSIGPIPE(fd)
        return fd
    }

    static func noSIGPIPE(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Writes all of `data`; false once the peer has gone.
    @discardableResult
    static func write(_ data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
    }
}
