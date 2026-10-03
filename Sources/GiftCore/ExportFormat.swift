import Foundation

public enum ExportFormat: String, Codable, CaseIterable, Sendable {
    case gif
    case mp4

    public var displayName: String {
        switch self {
        case .gif: return "GIF"
        case .mp4: return "MP4"
        }
    }

    public func write(frames: [GIFFrame], fps: Int, outputDirectory: URL) async throws -> URL {
        switch self {
        case .gif: return try GIFWriter.write(frames: frames, fps: fps, outputDirectory: outputDirectory)
        case .mp4: return try await MP4Writer.write(frames: frames, fps: fps, outputDirectory: outputDirectory)
        }
    }
}

extension FrameEdit {
    public func estimatedByteCount(of frames: [GIFFrame], fps: Int, format: ExportFormat) async throws -> Int {
        switch format {
        case .gif: return try estimatedByteCount(of: frames, fps: fps)
        case .mp4: return try await MP4Writer.encodedByteCount(frames: try apply(to: frames), fps: fps)
        }
    }
}
