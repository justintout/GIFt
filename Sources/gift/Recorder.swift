import AppKit
import CoreImage
@preconcurrency import ScreenCaptureKit
import CoreMedia
import GiftCore

/// The screen region and display a recording is taken from, stored without an NSScreen reference
/// so it can cross task boundaries.
struct SelectionContext: @unchecked Sendable {
    let selectionRect: CGRect
    let displayFrame: CGRect
    let displayID: CGDirectDisplayID
    let fallbackPointPixelScale: CGFloat
    let excludedWindowID: CGWindowID?
}

/// Everything about a recording that is fixed once it starts. The frame rate is frozen here
/// because reading it live would let a mid-recording menu change corrupt the output's timing,
/// its dimensions, and the throttle that decides which frames are kept.
struct RecordingParameters: Sendable {
    let fps: Int
    let maximumPixelDimension: Int

    var frameInterval: Double { 1.0 / Double(max(fps, 1)) }

    /// ScreenCaptureKit aims for `frameInterval` but lands a hair under it, and measured delivery
    /// gaps sit exactly on the interval. Requiring a full interval drops every other on-schedule
    /// frame and halves the output rate; measured, an on-schedule gap clears this threshold by 25%.
    /// Keeping the threshold here bounds how far the stored count can drift above the requested
    /// rate, so the frame-rate setting stays meaningful instead of being a floor.
    var minimumSpacing: Double { frameInterval * 0.75 }
}

/// Frames captured so far, plus the counters that explain what happened to them.
/// Every access happens on the recorder's capture queue.
final class CapturedFrames: @unchecked Sendable {
    struct Summary {
        let frames: [(CGImage, CMTime)]
        let parameters: RecordingParameters
        /// Complete frames ScreenCaptureKit offered, before the throttle dropped any.
        let deliveredCount: Int
        /// Seconds from the first stored frame to the last.
        let duration: Double
    }

    /// Roughly where a long recording starts risking a memory-pressure kill. Nothing caps the
    /// buffer yet, and the encode-time metrics line never prints if the process dies first, so
    /// without this a jetsam kill looks like a clean run that simply stopped.
    private static let memoryWarningBytes = 1_500_000_000

    private var frames: [(CGImage, CMTime)] = []
    private var lastStoredTimestamp: CMTime?
    private var deliveredCount = 0
    private var bufferedBytes = 0
    private var parameters: RecordingParameters?
    private var isActive = false

    func begin(parameters: RecordingParameters) {
        reset()
        self.parameters = parameters
        isActive = true
    }

    func cancel() {
        reset()
    }

    func finish() -> Summary? {
        guard let parameters, isActive else { return nil }
        let summary = Summary(
            frames: frames,
            parameters: parameters,
            deliveredCount: deliveredCount,
            duration: duration()
        )
        reset()
        return summary
    }

    /// Drop frames only when they arrive well ahead of the target interval. This caps how much a
    /// misbehaving capture can make us hold, without second-guessing normal delivery jitter.
    func append(_ image: CGImage, at timestamp: CMTime) {
        guard isActive, let parameters else { return }
        deliveredCount += 1

        if let lastStoredTimestamp {
            let elapsed = CMTimeGetSeconds(timestamp - lastStoredTimestamp)
            guard elapsed.isFinite, elapsed >= parameters.minimumSpacing else { return }
        }
        lastStoredTimestamp = timestamp
        frames.append((image, timestamp))

        let wasBelowWarning = bufferedBytes <= Self.memoryWarningBytes
        bufferedBytes += image.width * image.height * 4
        if wasBelowWarning, bufferedBytes > Self.memoryWarningBytes {
            captureLog.warning("recording has \(self.frames.count) frames buffered (~\(self.bufferedBytes / 1_000_000, privacy: .public) MB); a long recording can be killed for memory pressure before it is encoded")
        }
    }

    private func duration() -> Double {
        guard let first = frames.first?.1, let last = frames.last?.1 else { return 0 }
        return CMTimeGetSeconds(last - first)
    }

    private func reset() {
        frames.removeAll()
        lastStoredTimestamp = nil
        deliveredCount = 0
        bufferedBytes = 0
        parameters = nil
        isActive = false
    }
}

@MainActor
final class Recorder: NSObject, SCStreamOutput {
    enum RecorderError: LocalizedError, Equatable {
        case noSelection
        case streamSetupFailed
        case permissionDenied
        case canceled

        var errorDescription: String? {
            switch self {
            case .noSelection: return "Select an area before recording."
            case .streamSetupFailed: return "Unable to start screen capture."
            case .permissionDenied: return "Screen recording permission denied."
            case .canceled: return "Recording canceled."
            }
        }
    }

    enum State { case idle, starting, recording, stopping }

    /// Above this rate, narrower output keeps GIF encoding work and file size in check.
    private static let highFrameRateThreshold = 24
    private static let standardGIFPixelDimension = 1280
    private static let highFrameRateGIFPixelDimension = 960

    private(set) var state: State = .idle
    var fps: Int = Settings.defaultFrameRate
    var outputDirectory: URL = Settings.standard.outputDirectory
    var hasSelection: Bool { selection != nil }

    private var selection: SelectionContext?
    private var stream: SCStream?
    private var completionHandler: ((Result<URL, Error>) -> Void)?
    /// Identifies the recording currently in flight. Encoding runs off the main actor and can
    /// outlive its recording — a stream error sets the recorder idle while the encode is still
    /// running, which lets the next recording start. Results carry their session so a late one
    /// cannot finish somebody else's recording.
    private var session: UUID?

    private let captureQueue = DispatchQueue(label: "gift.capture", qos: .userInteractive)
    private let captureBuffer = CapturedFrames()
    private let renderContext = CIContext(options: [.useSoftwareRenderer: false])

    @discardableResult
    func setSelection(rect: CGRect, on screen: NSScreen, excludedWindowID: CGWindowID?) throws -> CGRect {
        let display = DisplayGeometry(frame: screen.frame, pointPixelScale: screen.backingScaleFactor)
        let geometry = try CaptureGeometryCalculator.geometry(for: rect, on: display)
        selection = SelectionContext(
            selectionRect: geometry.selectionRect,
            displayFrame: screen.frame,
            displayID: screen.displayID,
            fallbackPointPixelScale: screen.backingScaleFactor,
            excludedWindowID: excludedWindowID
        )
        return geometry.selectionRect
    }

    func start(status: @escaping (String) -> Void, completion: @escaping (Result<URL, Error>) -> Void) {
        guard state == .idle else {
            captureLog.error("start called while \(String(describing: self.state), privacy: .public); ignoring")
            return
        }
        guard let selection else {
            captureLog.error("start called with no selection")
            completion(.failure(RecorderError.noSelection))
            return
        }

        let parameters = RecordingParameters(
            fps: fps,
            maximumPixelDimension: Self.maximumPixelDimension(for: fps)
        )
        let session = UUID()
        self.session = session
        state = .starting
        completionHandler = completion
        captureQueue.sync { captureBuffer.begin(parameters: parameters) }

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.beginCapture(selection: selection, parameters: parameters)
                status("Recording… Press Stop when done.")
            } catch {
                self.finish(.failure(error), session: session)
            }
        }
    }

    func stop() {
        guard state == .recording, let stream, let session else { return }
        state = .stopping
        let outputDirectory = self.outputDirectory

        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try await stream.stopCapture()
            } catch {
                // Losing the teardown must not lose the recording, so encode what was captured.
                captureLog.error("stopCapture failed; encoding captured frames anyway: \(String(describing: error), privacy: .public)")
            }
            guard let self else { return }
            let summary = self.takeCapturedFrames()
            let result = Self.encode(summary: summary, outputDirectory: outputDirectory)
            await self.finish(result, session: session)
        }
    }

    func cancel() {
        guard state == .recording || state == .starting, let session else { return }
        state = .stopping
        captureQueue.sync { captureBuffer.cancel() }
        let stream = self.stream

        Task { [weak self] in
            try? await stream?.stopCapture()
            self?.finish(.failure(RecorderError.canceled), session: session)
        }
    }

    // MARK: ScreenCaptureKit

    private func beginCapture(selection: SelectionContext, parameters: RecordingParameters) async throws {
        guard CGPreflightScreenCaptureAccess() else { throw RecorderError.permissionDenied }

        let content = try await SCShareableContent.current
        guard let display = content.displays.first(where: { $0.displayID == selection.displayID }) else {
            throw RecorderError.streamSetupFailed
        }

        let excludedWindows = content.windows.filter { $0.windowID == selection.excludedWindowID }
        let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)

        let scale: CGFloat
        if #available(macOS 14.0, *) {
            let filterScale = CGFloat(filter.pointPixelScale)
            scale = filterScale > 0 ? filterScale : selection.fallbackPointPixelScale
        } else {
            scale = selection.fallbackPointPixelScale
        }

        let geometry = try CaptureGeometryCalculator.geometry(
            for: selection.selectionRect,
            on: DisplayGeometry(frame: selection.displayFrame, pointPixelScale: scale),
            maximumPixelDimension: parameters.maximumPixelDimension
        )

        let config = SCStreamConfiguration()
        config.pixelFormat = kCVPixelFormatType_32BGRA
        // ScreenCaptureKit produces the final GIF dimensions, so full-resolution frames are never
        // held in memory and the encoder has nothing left to rescale.
        config.scalesToFit = true
        config.showsCursor = true
        config.minimumFrameInterval = CMTime(value: 1, timescale: Int32(parameters.fps))
        config.sourceRect = geometry.sourceRect
        config.width = geometry.outputWidth
        config.height = geometry.outputHeight
        config.queueDepth = 8
        config.colorSpaceName = CGColorSpace.sRGB as CFString
        if #available(macOS 14.0, *) {
            config.captureResolution = .best
        }

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        captureLog.info("starting capture on display \(selection.displayID, privacy: .private) source \(String(describing: geometry.sourceRect), privacy: .private) output \(geometry.outputWidth, privacy: .public)x\(geometry.outputHeight, privacy: .public) scale \(scale, privacy: .public) fps \(parameters.fps, privacy: .public)")

        try await stream.startCapture()
        guard state == .starting else {
            try? await stream.stopCapture()
            throw RecorderError.canceled
        }
        self.stream = stream
        state = .recording
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // Runs on captureQueue, which is where CapturedFrames lives.
        guard type == .screen,
              CMSampleBufferIsValid(sampleBuffer),
              let pixelBuffer = sampleBuffer.imageBuffer else { return }

        // ScreenCaptureKit also delivers idle and blank frames; keep only complete ones.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let statusRaw = attachments.first?[.status] as? Int,
           let status = SCFrameStatus(rawValue: statusRaw),
           status != .complete {
            return
        }

        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        autoreleasepool {
            let ciImage = CIImage(cvImageBuffer: pixelBuffer)
            if let cgImage = renderContext.createCGImage(ciImage, from: ciImage.extent) {
                captureBuffer.append(cgImage, at: timestamp)
            }
        }
    }

    // MARK: Encoding

    private nonisolated func takeCapturedFrames() -> CapturedFrames.Summary? {
        captureQueue.sync { captureBuffer.finish() }
    }

    private nonisolated static func encode(summary: CapturedFrames.Summary?, outputDirectory: URL) -> Result<URL, Error> {
        guard let summary else { return .failure(RecorderError.noSelection) }

        let frames = summary.frames.map { GIFFrame(image: $0.0, timestamp: $0.1) }
        let dimensions = frames.first.map { "\($0.image.width)x\($0.image.height)" } ?? "none"
        let startedAt = Date()

        do {
            let url = try GIFWriter.write(frames: frames, fps: summary.parameters.fps, outputDirectory: outputDirectory)
            let elapsed = Date().timeIntervalSince(startedAt)
            let effectiveFPS = summary.duration > 0 ? Double(frames.count) / summary.duration : 0
            captureLog.info("\(metricsLine(summary: summary, written: frames.count, dimensions: dimensions, encodeSeconds: elapsed, effectiveFPS: effectiveFPS), privacy: .public)")
            return .success(url)
        } catch {
            captureLog.error("GIF encoding failed: \(String(describing: error), privacy: .public)")
            return .failure(error)
        }
    }

    /// One line per recording with everything needed to tell a capture drop apart from a slow
    /// encode apart from wrong frame delays.
    private nonisolated static func metricsLine(
        summary: CapturedFrames.Summary,
        written: Int,
        dimensions: String,
        encodeSeconds: Double,
        effectiveFPS: Double
    ) -> String {
        let stored = summary.frames.count
        let dropped = summary.deliveredCount - stored
        return String(
            format: "recording delivered=%d stored=%d written=%d dropped=%d span=%.2fs output=%@ fps=%d encode=%.2fs effectiveFPS=%.2f",
            summary.deliveredCount, stored, written, dropped, summary.duration,
            dimensions, summary.parameters.fps, encodeSeconds, effectiveFPS
        )
    }

    private static func maximumPixelDimension(for fps: Int) -> Int {
        fps >= highFrameRateThreshold ? highFrameRateGIFPixelDimension : standardGIFPixelDimension
    }

    private func finish(_ result: Result<URL, Error>, session: UUID) {
        guard session == self.session else {
            captureLog.info("ignoring a result from a superseded recording")
            return
        }
        self.session = nil
        stream = nil
        state = .idle
        let completion = completionHandler
        completionHandler = nil
        completion?(result)
    }
}

extension Recorder: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        captureLog.error("stream stopped with error: \(String(describing: error), privacy: .private)")
        Task { @MainActor [weak self] in
            guard let self, let session = self.session else { return }
            self.captureQueue.sync { self.captureBuffer.cancel() }
            self.finish(.failure(error), session: session)
        }
    }
}
