import CoreGraphics
import Foundation
import GiftCore
import ImageIO
import MCP
import UniformTypeIdentifiers

/// `gift mcp`: the command line's operations as MCP tools over stdio, for agent hosts that have
/// no shell, such as Claude Desktop and the ChatGPT desktop app. Every tool call is one request
/// to the running app through `AgentClient`, like a `gift` command.
enum AgentMCP {
    private static let instructions = """
    GIFt records an area of the screen or a window to a GIF or MP4 on this Mac. Coordinates are \
    global points with the origin at the top left of the primary display and y increasing \
    downward. To record part of the screen, take a screenshot with the grid, read coordinates off \
    its labels, then record that area. Recordings save to the user's output folder; \
    show_recording opens one in front of the user.
    """

    private static let area: [String: Value] = [
        "x": number("Left edge, in global points."),
        "y": number("Top edge, in global points."),
        "width": number("Width in points."),
        "height": number("Height in points.")
    ]

    private static let tools = [
        Tool(
            name: "status",
            description: "GIFt's state, its output folder, whether Screen Recording is granted, and each display's frame in global points with its pixel scale.",
            inputSchema: schema([:]),
            annotations: .init(readOnlyHint: true)
        ),
        Tool(
            name: "list_windows",
            description: "Open windows, frontmost first, with the IDs record takes and their frames in global points.",
            inputSchema: schema([:]),
            annotations: .init(readOnlyHint: true)
        ),
        Tool(
            name: "screenshot",
            description: "A screenshot of an area (default: the primary display), one image pixel per point. With grid, a measurement grid labeled in global points is drawn in, so coordinates can be read straight off the image. The grid flashes on the user's screen during the capture.",
            inputSchema: schema(area.merging([
                "grid": .object(["type": "boolean", "description": "Draw the measurement grid. Default true."]),
                "spacing": .object(["type": "integer", "description": "Grid line spacing in points. Default 100, minimum 25."])
            ]) { $1 }),
            annotations: .init(readOnlyHint: true)
        ),
        Tool(
            name: "record",
            description: "Record an area (x, y, width, height) or a window (window_id). With seconds, waits, stops, and returns the saved file's path; keep it under 50 seconds, since hosts time tool calls out. Without seconds, returns once recording has started; call stop_recording when done.",
            inputSchema: schema(area.merging([
                "window_id": .object(["type": "integer", "description": "A window ID from list_windows, instead of an area."]),
                "seconds": number("How long to record."),
                "fps": .object(["type": "integer", "enum": [8, 10, 12, 15, 24, 30], "description": "Frames per second. Default: the user's setting."]),
                "format": .object(["type": "string", "enum": ["gif", "mp4"], "description": "Default: the user's setting. mp4 is much smaller when there is a lot of motion."])
            ]) { $1 })
        ),
        Tool(
            name: "stop_recording",
            description: "Stop recording and return the saved file's path. With discard, throws the recording away instead.",
            inputSchema: schema(["discard": .object(["type": "boolean"])])
        ),
        Tool(
            name: "show_recording",
            description: "Open a recording in Quick Look on the user's screen.",
            inputSchema: schema(["path": .object(["type": "string"])], required: ["path"])
        )
    ]

    /// Runs until the host closes stdin.
    static func serve() async throws {
        // Bundle.main does not follow the `gift` symlink back into GIFt.app.
        let version = AgentClient.bundle.flatMap(Bundle.init(url:))?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let server = Server(name: "gift", version: version, instructions: instructions, capabilities: .init(tools: .init()))
        await server.withMethodHandler(ListTools.self) { _ in .init(tools: tools) }
        await server.withMethodHandler(CallTool.self) { params in
            do {
                // The socket calls block, so they run off the server's own executor.
                return try await Task.detached { try call(params.name, params.arguments ?? [:]) }.value
            } catch {
                return .init(content: [text(error.localizedDescription)], isError: true)
            }
        }
        try await server.start(transport: StdioTransport())
        await server.waitUntilCompleted()
    }

    private static func call(_ name: String, _ arguments: [String: Value]) throws -> CallTool.Result {
        switch name {
        case "status":
            return try json(AgentClient.send(AgentRequest(command: "status")))
        case "list_windows":
            return try json(AgentClient.send(AgentRequest(command: "windows")))
        case "screenshot":
            let area = try rect(arguments) ?? primaryDisplay()
            var request = AgentRequest(command: "screenshot", area: area)
            request.grid = arguments["grid"]?.boolValue ?? true
            request.spacing = arguments["spacing"]?.intValue
            let path = try filePath(AgentClient.send(request))
            let image = try pointSizedPNG(of: URL(fileURLWithPath: path), width: area.width)
            return .init(content: [
                .image(data: image.base64EncodedString(), mimeType: "image/png", annotations: nil, _meta: nil),
                text("Image pixel (px, py) is global point (\(Int(area.x)) + px, \(Int(area.y)) + py). Full resolution: \(path)")
            ])
        case "record":
            var start = AgentRequest(command: "start", area: try rect(arguments))
            start.window = arguments["window_id"]?.intValue.map(UInt32.init)
            start.fps = arguments["fps"]?.intValue
            start.format = try arguments["format"]?.stringValue.map { text in
                guard let format = ExportFormat(rawValue: text) else { throw invalid("format is gif or mp4") }
                return format
            }
            guard (start.area == nil) != (start.window == nil) else { throw invalid("give x, y, width, and height, or window_id, not both") }
            let seconds = arguments["seconds"].flatMap { Double($0) }
            _ = try AgentClient.send(start)
            guard let seconds else { return .init(content: [text("Recording. Call stop_recording when done.")]) }
            Thread.sleep(forTimeInterval: seconds)
            return try saved(AgentClient.send(AgentRequest(command: "stop")))
        case "stop_recording":
            var stop = AgentRequest(command: "stop")
            stop.discard = arguments["discard"]?.boolValue
            return try saved(AgentClient.send(stop))
        case "show_recording":
            guard let path = arguments["path"]?.stringValue else { throw invalid("path is required") }
            var show = AgentRequest(command: "show")
            show.path = path
            _ = try AgentClient.send(show)
            return .init(content: [text("Shown to the user in Quick Look.")])
        default:
            throw invalid("unknown tool \(name)")
        }
    }

    private static func rect(_ arguments: [String: Value]) throws -> AgentRect? {
        let values = ["x", "y", "width", "height"].map { arguments[$0].flatMap { Double($0) } }
        if values.allSatisfy({ $0 == nil }) { return nil }
        let given = values.compactMap { $0 }
        guard given.count == 4, given[2] > 0, given[3] > 0 else {
            throw invalid("an area needs x, y, and a positive width and height")
        }
        return AgentRect(CGRect(x: given[0], y: given[1], width: given[2], height: given[3]))
    }

    /// The screenshot is scaled to the area's size in points, so the area has to be known here.
    private static func primaryDisplay() throws -> AgentRect {
        let status = try AgentClient.send(AgentRequest(command: "status"))
        let displays = (status as? [String: Any])?["displays"] as? [[String: Any]] ?? []
        guard let frame = displays.first(where: { $0["isPrimary"] as? Bool == true })?["frame"],
              let data = try? JSONSerialization.data(withJSONObject: frame),
              let rect = try? JSONDecoder().decode(AgentRect.self, from: data) else {
            throw AgentClient.Failure(message: "GIFt reported no primary display.", kind: .failed)
        }
        return rect
    }

    private static func filePath(_ result: Any) -> String {
        (result as? [String: Any])?["path"] as? String ?? ""
    }

    private static func saved(_ result: Any) -> CallTool.Result {
        let path = filePath(result)
        guard !path.isEmpty else { return .init(content: [text("Discarded.")]) }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        return .init(content: [text("Saved \(path) (\(bytes / 1024) KB).")])
    }

    private static func json(_ result: Any) throws -> CallTool.Result {
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .withoutEscapingSlashes])
        return .init(content: [text(String(decoding: data, as: UTF8.self))])
    }

    /// Scaled to one pixel per point: the model then reads grid labels and pixel offsets in the
    /// same units, and the image is a quarter of a Retina capture's size.
    private static func pointSizedPNG(of url: URL, width: Double) throws -> Data {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw AgentClient.Failure(message: "Unreadable screenshot at \(url.path).", kind: .failed)
        }
        let scale = min(1, width / Double(image.width))
        let size = CGSize(width: (Double(image.width) * scale).rounded(), height: (Double(image.height) * scale).rounded())
        let data = NSMutableData()
        guard let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw AgentClient.Failure(message: "Could not scale the screenshot.", kind: .failed)
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: size))
        guard let scaled = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw AgentClient.Failure(message: "Could not encode the screenshot.", kind: .failed)
        }
        CGImageDestinationAddImage(destination, scaled, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw AgentClient.Failure(message: "Could not encode the screenshot.", kind: .failed)
        }
        return data as Data
    }

    private static func text(_ text: String) -> Tool.Content {
        .text(text: text, annotations: nil, _meta: nil)
    }

    private static func schema(_ properties: [String: Value], required: [String] = []) -> Value {
        .object(["type": "object", "properties": .object(properties), "required": .array(required.map { .string($0) })])
    }

    private static func number(_ description: String) -> Value {
        .object(["type": "number", "description": .string(description)])
    }

    private static func invalid(_ message: String) -> AgentClient.Failure {
        AgentClient.Failure(message: "\(message.prefix(1).uppercased())\(message.dropFirst()).", kind: .usage)
    }
}
