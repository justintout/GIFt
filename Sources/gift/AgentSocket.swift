import Foundation
import GiftCore

// The wire between the `gift` command line and the running app: a Unix domain socket that takes
// one JSON request line per connection and answers with one JSON reply line. Capture has to
// happen in the app, because the Screen Recording grant belongs to GIFt.app and not to whatever
// shell the command runs in.

struct AgentRequest: Codable {
    var command: String
    var area: AgentRect?
    var window: UInt32?
    var fps: Int?
    var format: ExportFormat?
    var grid: Bool?
    var spacing: Int?
    var path: String?
}

struct AgentFile: Codable {
    let path: String
}

enum AgentErrorCode: String, Codable {
    case failed
    case badRequest = "bad-request"
    case noPermission = "no-permission"
}

/// Either `result` or `error` and `code`.
struct AgentReply<Value: Encodable>: Encodable {
    var result: Value?
    var error: String?
    var code: AgentErrorCode?
}

enum AgentSocket {
    /// Read from the user database rather than $HOME, which agent sandboxes often point elsewhere.
    static var directory: URL {
        URL(fileURLWithPath: String(cString: getpwuid(getuid())!.pointee.pw_dir)).appendingPathComponent("Library/Application Support/GIFt", isDirectory: true)
    }

    static var path: String { directory.appendingPathComponent("agent.sock").path }

    static func connect() throws -> Int32 {
        let fd = try makeSocket()
        var address = try address()
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else {
            let error = posixError()
            close(fd)
            throw error
        }
        return fd
    }

    /// Replaces any socket a previous run left behind. The directory is private to the user, and
    /// the server also checks each peer's user ID, since a socket's own mode is not honored
    /// everywhere.
    static func listen() throws -> Int32 {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        chmod(directory.path, 0o700)
        unlink(path)
        let fd = try makeSocket()
        var address = try address()
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, Darwin.listen(fd, 8) == 0 else {
            let error = posixError()
            close(fd)
            throw error
        }
        return fd
    }

    /// Reads up to the first newline, or to the end of the stream.
    static func readLine(_ fd: Int32) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw posixError()
            }
            if count == 0 { return data }
            if let newline = buffer[..<count].firstIndex(of: UInt8(ascii: "\n")) {
                data.append(contentsOf: buffer[..<newline])
                return data
            }
            data.append(contentsOf: buffer[..<count])
        }
    }

    static func writeLine(_ fd: Int32, _ data: Data) throws {
        let line = data + Data("\n".utf8)
        try line.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = write(fd, bytes.baseAddress! + offset, bytes.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw posixError()
                }
                offset += count
            }
        }
    }

    /// Writing to a peer that hung up raises SIGPIPE, which would otherwise kill the app.
    private static func makeSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw posixError() }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    private static func address() throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = path.utf8CString
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            bytes.withUnsafeBytes { destination.copyMemory(from: $0) }
        }
        return address
    }

    static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
