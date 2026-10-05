import Foundation

/// The client side of `AgentSocket`, shared by the `gift` command line and `gift mcp`. Each call
/// is one connection, so a client outlives GIFt relaunching underneath it.
enum AgentClient {
    struct Failure: LocalizedError {
        enum Kind {
            case failed, usage, unreachable, noPermission, disabled
        }

        let message: String
        let kind: Kind

        var errorDescription: String? { message }
    }

    /// Sends one request and returns the reply's result, launching the app first if nothing is
    /// listening.
    static func send(_ request: AgentRequest) throws -> Any {
        let fd = try connectLaunchingIfNeeded()
        defer { close(fd) }
        try AgentSocket.writeLine(fd, JSONEncoder().encode(request))
        let line = try AgentSocket.readLine(fd)
        guard let reply = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            throw Failure(message: "GIFt closed the connection without replying.", kind: .failed)
        }
        if let error = reply["error"] as? String {
            let kind: Failure.Kind = switch AgentErrorCode(rawValue: reply["code"] as? String ?? "") {
            case .noPermission: .noPermission
            case .badRequest: .usage
            case .disabled: .disabled
            default: .failed
            }
            throw Failure(message: error, kind: kind)
        }
        return reply["result"] ?? [:]
    }

    /// The GIFt.app this executable belongs to. `gift` is usually a symlink to the executable
    /// inside it, so the link is resolved first.
    static var bundle: URL? {
        let executable = URL(fileURLWithPath: Bundle.main.executablePath!).resolvingSymlinksInPath()
        let bundle = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return bundle.pathExtension == "app" ? bundle : nil
    }

    private static func connectLaunchingIfNeeded() throws -> Int32 {
        do {
            return try AgentSocket.connect()
        } catch let error as POSIXError where error.code == .ENOENT || error.code == .ECONNREFUSED {
            try launchApp()
        }
        // A cold launch takes a second or two; past ten, something is wrong.
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let fd = try? AgentSocket.connect() {
                return fd
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        throw Failure(message: "GIFt was launched but did not start listening within 10 seconds.", kind: .unreachable)
    }

    /// Launches the bundle this executable belongs to, so the command and the app are always the
    /// same build.
    private static func launchApp() throws {
        guard let bundle else {
            throw Failure(message: "No GIFt is listening at \(AgentSocket.path), and this executable is not inside GIFt.app to launch it. Open GIFt.app first.", kind: .unreachable)
        }
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        // -g keeps GIFt from taking focus from whatever the agent is working in.
        open.arguments = ["-g", bundle.path]
        try open.run()
        open.waitUntilExit()
        guard open.terminationStatus == 0 else {
            throw Failure(message: "Could not launch \(bundle.path).", kind: .unreachable)
        }
        FileHandle.standardError.write(Data("gift: launched \(bundle.path)\n".utf8))
    }
}
