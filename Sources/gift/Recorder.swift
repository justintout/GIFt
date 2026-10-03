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
}

/// A single window to record, stored by ID rather than by `SCWindow` so it stays valid after the
/// enumeration it came from and can be re-resolved when the capture starts.
struct WindowContext: Sendable {
    let windowID: CGWindowID
    let fallbackPointPixelScale: CGFloat
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

/// A finished capture, not yet written to disk.
struct Recording: Sendable {
    let frames: [GIFFrame]
    let fps: Int
    /// Complete frames ScreenCaptureKit offered, before the throttle dropped any.
    let deliveredCount: Int
    /// Seconds from the first stored frame to the last, not counting pauses.
    let duration: Double
}

/// Frames captured so far, plus the counters that explain what happened to them.
/// Every access happens on the recorder's capture queue.
final class CapturedFrames: @unchecked Sendable {
    /// Roughly where a long recording starts risking a memory-pressure kill. Nothing caps the
    /// buffer yet, and the encode-time metrics line never prints if the process dies first, so
    /// without this a jetsam kill looks like a clean run that simply stopped.
    private static let memoryWarningBytes = 1_500_000_000

    private var frames: [GIFFrame] = []
    private var lastStoredTimestamp: CMTime?
    private var deliveredCount = 0
    private var bufferedBytes = 0
    private var parameters: RecordingParameters?
    private var isActive = false
    private var pausedAt: CMTime?
    /// Time spent paused so far, subtracted from every later timestamp so the GIF plays straight
    /// through each pause. Measured on the host clock; only the length is used, so it does not
    /// matter whether frame timestamps share that clock's origin.
    private var pausedDuration = CMTime.zero
    private var clicks: [Click] = []

    func begin(parameters: RecordingParameters) {
        reset()
        self.parameters = parameters
        isActive = true
    }

    func cancel() {
        reset()
    }

    func finish() -> Recording? {
        guard let parameters, isActive else { return nil }
        let recording = Recording(
            frames: frames,
            fps: parameters.fps,
            deliveredCount: deliveredCount,
            duration: duration()
        )
        reset()
        return recording
    }

    func setPaused(_ paused: Bool) {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        if paused, pausedAt == nil {
            pausedAt = now
        } else if !paused, let pausedAt {
            pausedDuration = pausedDuration + (now - pausedAt)
            self.pausedAt = nil
        }
    }

    func addClick(_ click: Click) {
        guard isActive, pausedAt == nil else { return }
        clicks.append(click)
    }

    /// Drop frames only when they arrive well ahead of the target interval. This caps how much a
    /// misbehaving capture can make us hold, without second-guessing normal delivery jitter.
    func append(_ image: CGImage, at timestamp: CMTime) {
        guard isActive, pausedAt == nil, let parameters else { return }
        deliveredCount += 1

        let timestamp = timestamp - pausedDuration
        if let lastStoredTimestamp {
            let elapsed = CMTimeGetSeconds(timestamp - lastStoredTimestamp)
            guard elapsed.isFinite, elapsed >= parameters.minimumSpacing else { return }
        }
        lastStoredTimestamp = timestamp
        frames.append(GIFFrame(image: highlightingClicks(on: image), timestamp: timestamp))

        let wasBelowWarning = bufferedBytes <= Self.memoryWarningBytes
        bufferedBytes += image.width * image.height * 4
        if wasBelowWarning, bufferedBytes > Self.memoryWarningBytes {
            captureLog.warning("recording has \(self.frames.count) frames buffered (~\(self.bufferedBytes / 1_000_000, privacy: .public) MB); a long recording can be killed for memory pressure before it is encoded")
        }
    }

    /// Clicks are timed on the host clock when they happen, so the frame is timed on the same clock
    /// as it arrives rather than by its own timestamp.
    private func highlightingClicks(on image: CGImage) -> CGImage {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        clicks.removeAll { CMTimeGetSeconds(now - $0.time) >= ClickHighlighter.duration }
        guard !clicks.isEmpty else { return image }
        do {
            return try ClickHighlighter.draw(clicks, at: now, on: image)
        } catch {
            captureLog.error("could not draw click highlights; keeping the frame without them: \(String(describing: error), privacy: .public)")
            return image
        }
    }

    private func duration() -> Double {
        guard let first = frames.first?.timestamp, let last = frames.last?.timestamp else { return 0 }
        return CMTimeGetSeconds(last - first)
    }

    private func reset() {
        frames.removeAll()
        lastStoredTimestamp = nil
        deliveredCount = 0
        bufferedBytes = 0
        parameters = nil
        isActive = false
        pausedAt = nil
        pausedDuration = .zero
        clicks.removeAll()
    }
}

@MainActor
final class Recorder: NSObject, SCStreamOutput {
    enum RecorderError: LocalizedError, Equatable {
        case noSelection
        case streamSetupFailed
        case permissionDenied
        case windowUnavailable
        case canceled

        var errorDescription: String? {
            switch self {
            case .noSelection: return "Select an area or window before recording."
            case .streamSetupFailed: return "Unable to start screen capture."
            case .permissionDenied: return "Screen recording permission denied."
            case .windowUnavailable: return "That window is no longer available."
            case .canceled: return "Recording canceled."
            }
        }
    }

    enum State { case idle, starting, recording, stopping }

    /// What a recording is taken from. Both cases are resolved to a live ScreenCaptureKit filter
    /// when the capture starts.
    private enum Target: Sendable {
        case region(SelectionContext)
        case window(WindowContext)
    }

    /// Above this rate, narrower output keeps GIF encoding work and file size in check.
    private static let highFrameRateThreshold = 24
    private static let standardGIFPixelDimension = 1280
    private static let highFrameRateGIFPixelDimension = 960

    private(set) var state: State = .idle
    private(set) var isPaused = false
    var fps: Int = Settings.defaultFrameRate
    var highlightsClicks = Settings.standard.highlightClicks
    var hasTarget: Bool { target != nil }

    private var target: Target?
    private var stream: SCStream?
    private var clickMonitor: Any?
    private var completionHandler: ((Result<Recording, Error>) -> Void)?
    /// Identifies the recording currently in flight. Encoding runs off the main actor and can
    /// outlive its recording — a stream error sets the recorder idle while the encode is still
    /// running, which lets the next recording start. Results carry their session so a late one
    /// cannot finish somebody else's recording.
    private var session: UUID?

    private let captureQueue = DispatchQueue(label: "gift.capture", qos: .userInteractive)
    private let captureBuffer = CapturedFrames()
    private let renderContext = CIContext(options: [.useSoftwareRenderer: false])

    @discardableResult
    func setSelection(rect: CGRect, on screen: NSScreen) throws -> CGRect {
        let display = DisplayGeometry(frame: screen.frame, pointPixelScale: screen.backingScaleFactor)
        let geometry = try CaptureGeometryCalculator.geometry(for: rect, on: display)
        target = .region(SelectionContext(
            selectionRect: geometry.selectionRect,
            displayFrame: screen.frame,
            displayID: screen.displayID,
            fallbackPointPixelScale: screen.backingScaleFactor
        ))
        return geometry.selectionRect
    }

    /// Records one whole window, wherever it sits and whatever covers it. The returned rect is
    /// only for the indicator outline: the capture comes from the filter, not from a screen
    /// region, so the window can be moved afterwards without changing what is recorded.
    @discardableResult
    func setWindow(windowID: CGWindowID) async throws -> CGRect {
        // Off-screen windows included, so GIFt is listed even before any of its windows is visible.
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw RecorderError.windowUnavailable
        }

        let frame = NSScreen.appKitBounds(fromWindowBounds: window.frame)
        target = .window(WindowContext(
            windowID: window.windowID,
            fallbackPointPixelScale: NSScreen.backingScaleFactor(forAppKitBounds: frame)
        ))
        return frame
    }

    func start(status: @escaping (String) -> Void, completion: @escaping (Result<Recording, Error>) -> Void) {
        guard state == .idle else {
            captureLog.error("start called while \(String(describing: self.state), privacy: .public); ignoring")
            return
        }
        guard let target else {
            captureLog.error("start called with no recording target")
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
                try await self.beginCapture(target: target, parameters: parameters)
                status("Recording… Press Stop when done.")
            } catch {
                self.finish(.failure(error), session: session)
            }
        }
    }

    func stop() {
        guard state == .recording, let stream, let session else { return }
        state = .stopping

        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try await stream.stopCapture()
            } catch {
                // Losing the teardown must not lose the recording, so keep what was captured.
                captureLog.error("stopCapture failed; keeping captured frames anyway: \(String(describing: error), privacy: .public)")
            }
            guard let self else { return }
            let result: Result<Recording, Error>
            if let recording = self.takeCapturedFrames(), !recording.frames.isEmpty {
                result = .success(recording)
            } else {
                result = .failure(GIFWritingError.noFrames)
            }
            await self.finish(result, session: session)
        }
    }

    func setPaused(_ paused: Bool) {
        guard state == .recording, paused != isPaused else { return }
        isPaused = paused
        captureQueue.async { [captureBuffer] in captureBuffer.setPaused(paused) }
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

    private func beginCapture(target: Target, parameters: RecordingParameters) async throws {
        guard CGPreflightScreenCaptureAccess() else { throw RecorderError.permissionDenied }

        let content = try await SCShareableContent.current

        let config = SCStreamConfiguration()
        config.pixelFormat = kCVPixelFormatType_32BGRA
        // ScreenCaptureKit produces the final GIF dimensions, so full-resolution frames are never
        // held in memory and the encoder has nothing left to rescale.
        config.scalesToFit = true
        config.showsCursor = true
        config.minimumFrameInterval = CMTime(value: 1, timescale: Int32(parameters.fps))
        config.queueDepth = 8
        config.colorSpaceName = CGColorSpace.sRGB as CFString
        if #available(macOS 14.0, *) {
            config.captureResolution = .best
        }

        let filter: SCContentFilter
        switch target {
        case .region(let selection):
            guard let display = content.displays.first(where: { $0.displayID == selection.displayID }) else {
                throw RecorderError.streamSetupFailed
            }
            // Excluding the whole app covers windows opened after the capture starts too: the
            // outline, the recording controls, and any GIFt window dragged over the area.
            let ownProcessID = ProcessInfo.processInfo.processIdentifier
            let ownApplication = content.applications.filter { $0.processID == ownProcessID }
            if ownApplication.isEmpty {
                captureLog.error("GIFt is missing from the shareable content; its own windows may appear in the recording")
            }
            filter = SCContentFilter(display: display, excludingApplications: ownApplication, exceptingWindows: [])

            let scale = Self.pointPixelScale(of: filter, fallback: selection.fallbackPointPixelScale)
            let geometry = try CaptureGeometryCalculator.geometry(
                for: selection.selectionRect,
                on: DisplayGeometry(frame: selection.displayFrame, pointPixelScale: scale),
                maximumPixelDimension: parameters.maximumPixelDimension
            )
            config.sourceRect = geometry.sourceRect
            config.width = geometry.outputWidth
            config.height = geometry.outputHeight
            captureLog.notice("starting capture on display \(selection.displayID, privacy: .public) source \(String(describing: geometry.sourceRect), privacy: .public) output \(geometry.outputWidth, privacy: .public)x\(geometry.outputHeight, privacy: .public) scale \(scale, privacy: .public) fps \(parameters.fps, privacy: .public)")

        case .window(let window):
            guard let scWindow = content.windows.first(where: { $0.windowID == window.windowID }) else {
                throw RecorderError.windowUnavailable
            }
            filter = SCContentFilter(desktopIndependentWindow: scWindow)

            // A window filter hands over the window's whole content, so there is no source rect to
            // set and the output size follows from the window's own frame.
            let scale = Self.pointPixelScale(of: filter, fallback: window.fallbackPointPixelScale)
            let size = try CaptureGeometryCalculator.outputSize(
                forFrame: scWindow.frame,
                pointPixelScale: scale,
                maximumPixelDimension: parameters.maximumPixelDimension
            )
            config.width = size.width
            config.height = size.height
            captureLog.notice("starting capture on window \(window.windowID, privacy: .public) source \(String(describing: scWindow.frame), privacy: .public) output \(size.width, privacy: .public)x\(size.height, privacy: .public) scale \(scale, privacy: .public) fps \(parameters.fps, privacy: .public)")
        }

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)

        try await stream.startCapture()
        guard state == .starting else {
            try? await stream.stopCapture()
            throw RecorderError.canceled
        }
        self.stream = stream
        state = .recording
        if highlightsClicks {
            startClickMonitor(target: target)
        }
    }

    // MARK: Clicks

    /// Mouse-down events from other applications need no permission, unlike key events. Clicks on
    /// GIFt's own windows, such as the pause button, are never reported here.
    private func startClickMonitor(target: Target) {
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            // Global monitors call back on the main thread.
            MainActor.assumeIsolated { self?.recordClick(target: target) }
        }
    }

    private func stopClickMonitor() {
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
        }
        clickMonitor = nil
    }

    private func recordClick(target: Target) {
        let time = CMClockGetTime(CMClockGetHostTimeClock())
        guard !isPaused, let frame = Self.currentFrame(of: target), frame.width > 0, frame.height > 0 else { return }

        let mouse = NSEvent.mouseLocation
        let location = CGPoint(x: (mouse.x - frame.minX) / frame.width, y: (mouse.y - frame.minY) / frame.height)
        guard (0...1).contains(location.x), (0...1).contains(location.y) else { return }
        captureQueue.async { [captureBuffer] in
            captureBuffer.addClick(Click(location: location, time: time))
        }
    }

    /// Where the recorded content is on screen now, in AppKit coordinates. A window can move during
    /// a recording, so its frame is looked up for each click.
    private static func currentFrame(of target: Target) -> CGRect? {
        switch target {
        case .region(let selection):
            return selection.selectionRect
        case .window(let window):
            guard let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, window.windowID) as? [[String: Any]])?.first,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds) else { return nil }
            return NSScreen.appKitBounds(fromWindowBounds: frame)
        }
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

    private nonisolated func takeCapturedFrames() -> Recording? {
        captureQueue.sync { captureBuffer.finish() }
    }

    /// ScreenCaptureKit reports a filter's own point-to-pixel scale from macOS 14 on. Before
    /// that, the display the filter covers is the only source for it.
    private static func pointPixelScale(of filter: SCContentFilter, fallback: CGFloat) -> CGFloat {
        if #available(macOS 14.0, *) {
            let filterScale = CGFloat(filter.pointPixelScale)
            return filterScale > 0 ? filterScale : fallback
        }
        return fallback
    }

    private static func maximumPixelDimension(for fps: Int) -> Int {
        fps >= highFrameRateThreshold ? highFrameRateGIFPixelDimension : standardGIFPixelDimension
    }

    private func finish(_ result: Result<Recording, Error>, session: UUID) {
        guard session == self.session else {
            captureLog.info("ignoring a result from a superseded recording")
            return
        }
        self.session = nil
        stream = nil
        stopClickMonitor()
        isPaused = false
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
