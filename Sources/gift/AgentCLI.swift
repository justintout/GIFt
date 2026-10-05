import Foundation
import GiftCore

/// The `gift` command line: a client of the running app. Every command is one request over
/// `AgentSocket`, except `record --seconds`, which also stops the recording.
enum AgentCLI {
    static let usage = """
    Usage: gift <command> [options]

    Drives the running GIFt app, which records an area of the screen or a window to a GIF or
    MP4. GIFt is launched in the background if it is not running. Results print to stdout as
    JSON; errors print to stderr.

    Coordinates are global points with the origin at the top left of the primary display, y
    growing down. Displays left of or above the primary one have negative coordinates. An area
    is X,Y,W,H, for example 100,200,640,480. Screenshots are in pixels: read points off the
    measurement grid's labels, or divide by the display's scale from `gift status`.

    Commands:
      status                      State, displays, and whether Screen Recording is granted.
      windows                     Open windows, frontmost first, with IDs and frames.
      screenshot [--area X,Y,W,H] [--grid] [--spacing N]
                                  Save a PNG of the area (default: the primary display) and
                                  print its path. --grid draws the measurement grid into it,
                                  labeled every 100 points (--spacing sets the line spacing,
                                  minimum 25).
      record (--area X,Y,W,H | --window ID) [--seconds N] [--fps N] [--format gif|mp4]
                                  Start recording. With --seconds, wait that long, stop, and
                                  print the saved file's path. Without it, return once frames
                                  are being captured; run `gift stop` when done. fps is one of
                                  8, 10, 12, 15, 24, 30.
      stop [--discard]            Stop, wait for the file to be written, and print its path.
                                  --discard throws the recording away. While idle, prints the
                                  last recording's path.
      show PATH                   Open a file in Quick Look for the user to see.
      skill                       Print the agent skill that teaches this workflow.
      mcp                         Serve these commands as MCP tools over stdio.
      help                        Print this text.

    Exit codes:
      0  success
      1  the app reported a failure (message on stderr)
      2  usage error
      3  GIFt is not running and could not be launched
      4  GIFt lacks Screen Recording permission; the user must grant it in the window GIFt opened
      5  agent control is off; the user must turn on Allow Agents in GIFt's Settings
    """

    static func run(_ arguments: [String]) -> Int32 {
        do {
            if let output = try perform(arguments) {
                print(output)
            }
            return 0
        } catch let failure as AgentClient.Failure {
            FileHandle.standardError.write(Data("gift: \(failure.message)\n".utf8))
            return switch failure.kind {
            case .failed: 1
            case .usage: 2
            case .unreachable: 3
            case .noPermission: 4
            case .disabled: 5
            }
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
        case "status", "windows":
            break
        case "screenshot":
            request.area = try options.area("--area")
            request.grid = options.has("--grid")
            request.spacing = try options.int("--spacing")
        case "record":
            return try record(&options)
        case "stop":
            request.discard = options.has("--discard")
        case "show":
            // The app resolves paths against its own working directory, not this shell's.
            request.path = URL(fileURLWithPath: try options.positional("a path")).standardizedFileURL.path
        case "skill":
            try options.requireEmpty()
            return try skill()
        default:
            throw usageError("unknown command \(command)")
        }
        try options.requireEmpty()
        return try format(AgentClient.send(request))
    }

    private static func record(_ options: inout Options) throws -> String {
        let seconds = try options.double("--seconds")
        var start = AgentRequest(command: "start", area: try options.area("--area"), fps: try options.int("--fps"), format: try options.format())
        start.window = try options.value("--window").map(parseWindow)
        try options.requireEmpty()
        guard (start.area == nil) != (start.window == nil) else { throw usageError("record needs --area or --window, not both") }
        if let seconds, seconds <= 0 { throw usageError("--seconds must be more than 0") }

        let status = try AgentClient.send(start)
        guard let seconds else { return try format(status) }
        Thread.sleep(forTimeInterval: seconds)
        return try format(AgentClient.send(AgentRequest(command: "stop")))
    }

    /// The skill ships inside the bundle, so it always describes this build's commands.
    private static func skill() throws -> String {
        guard let url = AgentClient.bundle?.appendingPathComponent("Contents/Resources/SKILL.md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw AgentClient.Failure(message: "The skill ships inside GIFt.app, and this executable is not running from it.", kind: .failed)
        }
        return text
    }

    private static func format(_ result: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    static func parseArea(_ text: String) throws -> AgentRect {
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

    private static func usageError(_ message: String) -> AgentClient.Failure {
        AgentClient.Failure(message: "\(message). Run `gift help` for usage.", kind: .usage)
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
            guard let first = remaining.first, !first.hasPrefix("--") else { throw usageError("expected \(name)") }
            remaining.removeFirst()
            return first
        }

        func requireEmpty() throws {
            guard remaining.isEmpty else { throw usageError("unexpected \(remaining.joined(separator: " "))") }
        }
    }
}
