import Foundation
import GiftCore

/// Serves `gift` command line requests for as long as the app runs.
enum AgentServer {
    static func start(handler: @escaping @MainActor (Data) async -> Data) throws {
        let listener = try AgentSocket.listen()
        Thread.detachNewThread {
            while true {
                let fd = accept(listener, nil, nil)
                guard fd >= 0 else {
                    if errno == EINTR { continue }
                    appLog.error("agent socket stopped accepting: \(AgentSocket.posixError().localizedDescription, privacy: .public)")
                    return
                }
                DispatchQueue.global().async { serve(fd, handler: handler) }
            }
        }
    }

    private static func serve(_ fd: Int32, handler: @escaping @MainActor (Data) async -> Data) {
        var uid: uid_t = 0
        var gid: gid_t = 0
        // Bounds how long a peer that never sends its request can hold this thread.
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid(), let request = try? AgentSocket.readLine(fd) else {
            close(fd)
            return
        }
        Task { @MainActor in
            let reply = await handler(request)
            try? AgentSocket.writeLine(fd, reply)
            close(fd)
        }
    }
}

extension GiftApp {
    func agentReply(to line: Data) async -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            let request: AgentRequest
            do {
                request = try JSONDecoder().decode(AgentRequest.self, from: line)
            } catch {
                return try encoder.encode(AgentReply<String>(error: "Unreadable request: \(error.localizedDescription)", code: .badRequest))
            }
            func encode<Value: Encodable>(_ result: Value) throws -> Data {
                try encoder.encode(AgentReply(result: result))
            }
            let result = try await perform(request)
            return try encode(result)
        } catch {
            let code: AgentErrorCode = switch error {
            case AgentControlError.screenRecordingNotPermitted, Recorder.RecorderError.permissionDenied: .noPermission
            case AgentRequestError.disabled: .disabled
            case is AgentRequestError: .badRequest
            default: .failed
            }
            return (try? encoder.encode(AgentReply<String>(error: error.localizedDescription, code: code))) ?? Data()
        }
    }

    private func perform(_ request: AgentRequest) async throws -> any Encodable {
        guard settings.agentControlEnabled else { throw AgentRequestError.disabled }
        switch request.command {
        case "status":
            return agentStatus()
        case "windows":
            return agentWindows()
        case "screenshot":
            let url = try await agentScreenshot(rect: request.area, grid: request.grid ?? false, spacing: request.spacing ?? ScreenGrid.defaultSpacing)
            return AgentFile(path: url.path)
        case "start":
            try await agentStart(AgentTarget(area: request.area, window: request.window), fps: request.fps, format: request.format)
            return agentStatus()
        case "stop":
            let url = try await agentStop(discard: request.discard ?? false)
            return AgentFile(path: url?.path)
        case "show":
            guard let path = request.path else { throw AgentRequestError.missing("path") }
            try agentShow(path: path)
            return AgentFile(path: path)
        default:
            throw AgentRequestError.unknownCommand(request.command)
        }
    }
}

enum AgentRequestError: LocalizedError {
    case disabled
    case unknownCommand(String)
    case missing(String)

    var errorDescription: String? {
        switch self {
        case .disabled: return "Agent control is off. Ask the user to turn on Allow Agents in GIFt's Settings, under Agents."
        case .unknownCommand(let command): return "Unknown command \(command)."
        case .missing(let field): return "The request needs \(field)."
        }
    }
}
