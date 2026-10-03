import Foundation
import GiftCore

/// Writes a finished recording to disk with the user's edits applied.
enum RecordingExport {
    /// Runs off the main actor: scaling and encoding a long recording takes seconds.
    static func write(_ recording: Recording, edit: FrameEdit, format: ExportFormat, to outputDirectory: URL) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let startedAt = Date()
            do {
                let frames = try edit.apply(to: recording.frames)
                let url = try await format.write(frames: frames, fps: recording.fps, outputDirectory: outputDirectory)
                captureLog.notice("\(metricsLine(recording: recording, written: frames, format: format, encodeSeconds: Date().timeIntervalSince(startedAt)), privacy: .public)")
                return url
            } catch {
                captureLog.error("\(format.displayName, privacy: .public) encoding failed: \(String(describing: error), privacy: .public)")
                throw error
            }
        }.value
    }

    /// One line per recording with everything needed to tell a capture drop apart from a slow
    /// encode apart from wrong frame delays.
    private static func metricsLine(recording: Recording, written: [GIFFrame], format: ExportFormat, encodeSeconds: Double) -> String {
        let stored = recording.frames.count
        let dropped = recording.deliveredCount - stored
        let dimensions = written.first.map { "\($0.image.width)x\($0.image.height)" } ?? "none"
        let effectiveFPS = recording.duration > 0 ? Double(stored) / recording.duration : 0
        return String(
            format: "recording delivered=%d stored=%d written=%d dropped=%d span=%.2fs output=%@ format=%@ fps=%d encode=%.2fs effectiveFPS=%.2f",
            recording.deliveredCount, stored, written.count, dropped, recording.duration,
            dimensions, format.rawValue, recording.fps, encodeSeconds, effectiveFPS
        )
    }
}
