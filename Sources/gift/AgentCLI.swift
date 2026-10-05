import Foundation
import GiftCore

/// The `gift` command line: a client of the running app. Every command is one request over
/// `AgentSocket`, except `record`, which chains several.
enum AgentCLI {
    static let usage = """
    Usage: gift <command> [options]

    Drives the running GIFt app, which records an area of the screen or a window to a GIF or
    MP4. GIFt is launched in the background if it is not running. Results print to stdout as
    JSON; errors print to stderr.

    Coordinates are global points with the origin at the top left of the primary display, y
    growing down. Displays left of or above the primary one have negative coordinates. An area
    is X,Y,W,H, for example 100,200,640,480. Screenshots are in pixels: divide by the display's
    scale (see `gift displays`) to get points, or read points off the measurement grid labels.

    Commands:
      status                      State, settings, and whether Screen Recording is granted.
      displays                    Each display's frame, scale, and ID.
      windows                     Open windows, frontmost first, with IDs and frames.
      grid show [--spacing N]     Show the measurement grid (default 100, minimum 25 points).
      grid hide                   Hide it.
      screenshot [--area X,Y,W,H] [--grid] [--spacing N]
                                  Save a PNG of the area (default: the primary display) and
                                  print its path. --grid draws the measurement grid into it.
      select-area X,Y,W,H         Set the area to record. Prints the area as clipped to its display.
      select-window ID            Set the window to record, by ID from `gift windows`.
      start [--fps N] [--format gif|mp4]
                                  Start recording the selected target. Returns once frames are
                                  being captured. fps is one of 8, 10, 12, 15, 24, 30.
      pause | resume              Pause or resume the recording.
      stop                        Stop, wait for the file to be written, and print its path.
                                  While idle, prints the last recording's path.
      cancel                      Stop and discard the recording.
      record --seconds N [--area X,Y,W,H | --window ID] [--fps N] [--format gif|mp4]
                                  Select (when given), start, wait N seconds, stop, and print
                                  the saved file's path.
      show PATH                   Open a file in Quick Look for the user to see.
      help                        Print this text.

    Output: select-* print a rect {"x","y","width","height"}; screenshot, stop, record, and
    show print {"path"}; start, pause, resume, cancel, and grid print the status.

    Exit codes:
      0  success
      1  the app reported a failure (message on stderr)
      2  usage error
      3  GIFt is not running and could not be launched
      4  GIFt lacks Screen Recording permission; the user must grant it in the window GIFt opened
    """

    private struct Failure: Error {
        let message: String
        let status: Int32
    }

    static func run(_ arguments: [String]) -> Int32 {
        do {
            if let output = try perform(arguments) {
                print(output)
            }
            return 0
        } catch let failure as Failure {
            FileHandle.standardError.write(Data("gift: \(failure.message)\n".utf8))
            return failure.status
        } catch {
            FileHandle.standardError.write(Data("gift: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    private static func perform(_ arguments: [String]) throws -> String? {
        var options = Options(arguments.dropFirst())
        guard let command = arguments.first, !["help", "-h", "--help"].contains(command), !options.has("--help") else {
            return usage
        }

        var request = AgentRequest(command: command)
        switch command {
        case "status", "displays", "windows", "pause", "resume", "stop", "cancel":
            break
        case "grid":
            request.spacing = try options.int("--spacing")
            let action = try options.positional("show or hide")
            guard action == "show" || action == "hide" else { throw usageError("grid takes show or hide") }
            request.command = "grid-\(action)"
        case "screenshot":
            request.area = try options.area("--area")
            request.grid = options.has("--grid")
            request.spacing = try options.int("--spacing")
        case "select-area":
            request.area = try parseArea(try options.positional("X,Y,W,H"))
        case "select-window":
            request.window = try parseWindow(try options.positional("a window ID"))
        case "start":
            request.fps = try options.int("--fps")
            request.format = try options.format()
        case "show":
            // The app resolves paths against its own working directory, not this shell's.
            request.path = URL(fileURLWithPath: try options.positional("a path")).standardizedFileURL.path
        case "record":
            return try record(&options)
        default:
            throw usageError("unknown command \(command)")
        }
        try options.requireEmpty()
        return try format(send(request))
    }

    private static func record(_ options: inout Options) throws -> String {
        guard let seconds = try options.double("--seconds"), seconds > 0 else { throw usageError("record needs --seconds N") }
        let area = try options.area("--area")
        let window = try options.value("--window").map(parseWindow)
        let start = AgentRequest(command: "start", fps: try options.int("--fps"), format: try options.format())
        try options.requireEmpty()
        guard area == nil || window == nil else { throw usageError("give --area or --window, not both") }

        if let area {
            _ = try send(AgentRequest(command: "select-area", area: area))
        } else if let window {
            _ = try send(AgentRequest(command: "select-window", window: window))
        }
        _ = try send(start)
        Thread.sleep(forTimeInterval: seconds)
        return try format(send(AgentRequest(command: "stop")))
    }

    /// Sends one request and returns the reply's result, launching the app first if nothing is
    /// listening.
    private static func send(_ request: AgentRequest) throws -> Any {
        let fd = try connectLaunchingIfNeeded()
        defer { close(fd) }
        try AgentSocket.writeLine(fd, JSONEncoder().encode(request))
        let line = try AgentSocket.readLine(fd)
        guard let reply = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            throw Failure(message: "GIFt closed the connection without replying.", status: 1)
        }
        if let error = reply["error"] as? String {
            let status: Int32 = switch AgentErrorCode(rawValue: reply["code"] as? String ?? "") {
            case .noPermission: 4
            case .badRequest: 2
            default: 1
            }
            throw Failure(message: error, status: status)
        }
        return reply["result"] ?? [:]
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
        throw Failure(message: "GIFt was launched but did not start listening within 10 seconds.", status: 3)
    }

    /// Launches the bundle this executable belongs to, so the command and the app are always the
    /// same build. `gift` is usually a symlink to the executable inside GIFt.app.
    private static func launchApp() throws {
        let executable = URL(fileURLWithPath: Bundle.main.executablePath!).resolvingSymlinksInPath()
        let bundle = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard bundle.pathExtension == "app" else {
            throw Failure(message: "No GIFt is listening at \(AgentSocket.path), and \(executable.path) is not inside GIFt.app to launch it. Open GIFt.app first.", status: 3)
        }
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        // -g keeps GIFt from taking focus from whatever the agent is working in.
        open.arguments = ["-g", bundle.path]
        try open.run()
        open.waitUntilExit()
        guard open.terminationStatus == 0 else {
            throw Failure(message: "Could not launch \(bundle.path).", status: 3)
        }
        FileHandle.standardError.write(Data("gift: launched \(bundle.path)\n".utf8))
    }

    private static func format(_ result: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    private static func parseArea(_ text: String) throws -> AgentRect {
        let parts = text.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 4, let x = parts[0], let y = parts[1], let width = parts[2], let height = parts[3], width > 0, height > 0 else {
            throw usageError("an area is X,Y,W,H with a positive width and height, got \(text)")
        }
        return AgentRect(CGRect(x: x, y: y, width: width, height: height))
    }

    private static func parseWindow(_ text: String) throws -> UInt32 {
        guard let id = UInt32(text) else { throw usageError("a window ID is a number from `gift windows`, got \(text)") }
        return id
    }

    private static func usageError(_ message: String) -> Failure {
        Failure(message: "\(message). Run `gift help` for usage.", status: 2)
    }

    /// The arguments after the command, consumed as they are read so leftovers can be reported.
    private struct Options {
        private var remaining: [String]

        init(_ arguments: ArraySlice<String>) {
            remaining = Array(arguments)
        }

        mutating func has(_ flag: String) -> Bool {
            guard let index = remaining.firstIndex(of: flag) else { return false }
            remaining.remove(at: index)
            return true
        }

        mutating func value(_ flag: String) throws -> String? {
            guard let index = remaining.firstIndex(of: flag) else { return nil }
            guard index + 1 < remaining.count else { throw usageError("\(flag) needs a value") }
            let value = remaining[index + 1]
            remaining.removeSubrange(index...index + 1)
            return value
        }

        mutating func int(_ flag: String) throws -> Int? {
            try value(flag).map { text in
                guard let number = Int(text) else { throw usageError("\(flag) takes a whole number, got \(text)") }
                return number
            }
        }

        mutating func double(_ flag: String) throws -> Double? {
            try value(flag).map { text in
                guard let number = Double(text) else { throw usageError("\(flag) takes a number, got \(text)") }
                return number
            }
        }

        mutating func area(_ flag: String) throws -> AgentRect? {
            try value(flag).map(parseArea)
        }

        mutating func format() throws -> ExportFormat? {
            try value("--format").map { text in
                guard let format = ExportFormat(rawValue: text) else { throw usageError("--format is gif or mp4, got \(text)") }
                return format
            }
        }

        mutating func positional(_ name: String) throws -> String {
            // Areas left of or above the primary display start with a minus sign, so only known
            // flags are treated as flags.
            guard let first = remaining.first, !first.hasPrefix("--") else { throw usageError("expected \(name)") }
            remaining.removeFirst()
            return first
        }

        func requireEmpty() throws {
            guard remaining.isEmpty else { throw usageError("unexpected \(remaining.joined(separator: " "))") }
        }
    }
}
