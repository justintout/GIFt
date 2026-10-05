import AppKit
import GiftCore

// The operations an agent drives GIFt with, independent of how the agent reaches the app. Every
// rect is in global top-left points: the coordinates CoreGraphics window bounds, `screencapture
// -R`, and the measurement grid's labels use. An agent can read a rect off a gridded screenshot
// and pass it straight back.

struct AgentRect: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(_ rect: CGRect) {
        x = rect.minX
        y = rect.minY
        width = rect.width
        height = rect.height
    }

    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

struct AgentDisplay: Codable, Sendable {
    let id: UInt32
    let frame: AgentRect
    /// Pixels per point. A screenshot of this display is this many times larger than its frame.
    let scale: Double
    let isPrimary: Bool
}

struct AgentWindow: Codable, Sendable {
    let id: UInt32
    let app: String
    let title: String
    let frame: AgentRect
}

struct AgentStatus: Codable, Sendable {
    /// One of idle, starting, recording, stopping.
    let state: String
    let paused: Bool
    let hasTarget: Bool
    let fps: Int
    let format: String
    let outputDirectory: String
    /// Spacing of the visible grid in points, or nil when it is hidden.
    let gridSpacing: Int?
    let screenRecordingPermitted: Bool
    /// The file the last agent recording was saved to.
    let lastRecording: String?
}

enum AgentControlError: LocalizedError {
    case screenRecordingNotPermitted
    case busy
    case notRecording
    case offScreen
    case invalidFrameRate(Int)
    case invalidGridSpacing(Int)
    case fileNotFound(String)
    case screenshotFailed(String)

    var errorDescription: String? {
        switch self {
        case .screenRecordingNotPermitted:
            return "GIFt does not have Screen Recording permission. GIFt has opened its Settings window; ask the user to grant the permission there."
        case .busy:
            return "GIFt is already recording. Stop or cancel that recording first."
        case .notRecording:
            return "GIFt is not recording."
        case .offScreen:
            return "That area is not on any display."
        case .invalidFrameRate(let fps):
            return "\(fps) fps is not offered. Choose one of \(Settings.allowedFrameRates.map(String.init).joined(separator: ", "))."
        case .invalidGridSpacing(let spacing):
            return "Grid spacing \(spacing) is too fine. Use at least \(ScreenGrid.minimumSpacing) points."
        case .fileNotFound(let path):
            return "No file at \(path)."
        case .screenshotFailed(let reason):
            return "The screenshot failed: \(reason)"
        }
    }
}

/// Agent state the app keeps across calls: the format chosen for the recording in flight, and
/// where its result goes once it is saved.
@MainActor
final class AgentSession {
    var format: ExportFormat?
    private(set) var lastRecording: URL?
    private var result: Result<URL, Error>?
    private var inFlight = false
    private var waiters: [CheckedContinuation<URL, Error>] = []

    func recordingStarted() {
        result = nil
        inFlight = true
    }

    /// Waits for the recording in flight to be saved, or returns the last one's result.
    func awaitResult() async throws -> URL {
        if let result {
            return try result.get()
        }
        guard inFlight else { throw AgentControlError.notRecording }
        return try await withCheckedThrowingContinuation { waiters.append($0) }
    }

    func finish(_ result: Result<URL, Error>) {
        self.result = result
        inFlight = false
        if case .success(let url) = result {
            lastRecording = url
        }
        format = nil
        let waiting = waiters
        waiters.removeAll()
        waiting.forEach { $0.resume(with: result) }
    }
}

extension GiftApp {
    func agentStatus() -> AgentStatus {
        AgentStatus(
            state: "\(recorder.state)",
            paused: recorder.isPaused,
            hasTarget: recorder.hasTarget,
            fps: recorder.fps,
            format: (agentSession.format ?? settings.exportFormat).rawValue,
            outputDirectory: settings.outputDirectory.path,
            gridSpacing: gridOverlay.spacing,
            screenRecordingPermitted: CGPreflightScreenCaptureAccess(),
            lastRecording: agentSession.lastRecording?.path
        )
    }

    func agentDisplays() -> [AgentDisplay] {
        NSScreen.screens.enumerated().map { index, screen in
            AgentDisplay(id: screen.displayID, frame: AgentRect(screen.globalFrame), scale: screen.backingScaleFactor, isPrimary: index == 0)
        }
    }

    /// Frontmost first. Window frames come from the window server, which already uses global
    /// top-left points.
    func agentWindows() -> [AgentWindow] {
        openWindows().map { AgentWindow(id: $0.windowID, app: $0.ownerName, title: $0.title, frame: AgentRect($0.frame)) }
    }

    func agentShowGrid(spacing: Int = ScreenGrid.defaultSpacing) throws {
        guard spacing >= ScreenGrid.minimumSpacing else { throw AgentControlError.invalidGridSpacing(spacing) }
        gridOverlay.show(spacing: spacing)
    }

    func agentHideGrid() {
        gridOverlay.hide()
    }

    /// Saves a PNG of `rect`, or of the whole primary display, and returns its path. With `grid`,
    /// the measurement grid is shown for the capture and restored to how it was afterwards.
    func agentScreenshot(rect: AgentRect?, grid: Bool, spacing: Int = ScreenGrid.defaultSpacing) async throws -> URL {
        try requireScreenRecording()
        let area = rect?.cgRect ?? NSScreen.screens.first?.globalFrame ?? .zero
        guard agentDisplays().contains(where: { $0.frame.cgRect.intersects(area) }) else { throw AgentControlError.offScreen }

        let previousSpacing = gridOverlay.spacing
        if grid {
            try agentShowGrid(spacing: spacing)
        }
        defer {
            if let previousSpacing {
                gridOverlay.show(spacing: previousSpacing)
            } else {
                gridOverlay.hide()
            }
        }
        // The window server composites the grid on its next pass; capturing sooner can miss it.
        try await Task.sleep(nanoseconds: 150_000_000)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("gift-\(Int(Date().timeIntervalSince1970 * 1000)).png")
        // screencapture runs under GIFt's Screen Recording grant and, unlike ScreenCaptureKit's
        // screenshot API, works on every macOS version GIFt supports.
        let region = "\(Int(area.minX)),\(Int(area.minY)),\(Int(area.width)),\(Int(area.height))"
        try await Self.run("/usr/sbin/screencapture", ["-x", "-t", "png", "-R", region, url.path])
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AgentControlError.screenshotFailed("screencapture wrote no file")
        }
        return url
    }

    /// Sets an area as the recording target and outlines it. Returns the area as clipped to the
    /// display it mostly covers.
    func agentSelectArea(_ rect: AgentRect) throws -> AgentRect {
        try requireScreenRecording()
        guard canChangeTarget else { throw AgentControlError.busy }
        let area = rect.cgRect.standardized
        let screen = NSScreen.screens.max { overlap($0.globalFrame, area) < overlap($1.globalFrame, area) }
        guard let screen, overlap(screen.globalFrame, area) > 0 else { throw AgentControlError.offScreen }

        let selected = try recorder.setSelection(rect: NSScreen.appKitBounds(fromWindowBounds: area), on: screen)
        indicatorWindow.show(rect: selected, recording: false)
        return AgentRect(NSScreen.appKitBounds(fromWindowBounds: selected))
    }

    /// Sets one window as the recording target. The user's Bring Window to Front setting applies,
    /// as it does when they pick the window from the menu.
    func agentSelectWindow(id: UInt32) async throws -> AgentRect {
        try requireScreenRecording()
        guard canChangeTarget else { throw AgentControlError.busy }
        if settings.bringWindowToFront, let candidate = openWindows().first(where: { $0.windowID == id }) {
            WindowForegrounding.bringToFront(candidate)
        }
        let frame = try await recorder.setWindow(windowID: id)
        indicatorWindow.show(rect: frame, recording: false)
        return AgentRect(NSScreen.appKitBounds(fromWindowBounds: frame))
    }

    /// Returns once frames are being captured. The frame rate and format apply to this recording
    /// only; the user's settings are left alone.
    func agentStart(fps: Int?, format: ExportFormat?) async throws {
        try requireScreenRecording()
        guard recorder.state == .idle else { throw AgentControlError.busy }
        guard recorder.hasTarget else { throw Recorder.RecorderError.noSelection }
        if let fps {
            guard Settings.allowedFrameRates.contains(fps) else { throw AgentControlError.invalidFrameRate(fps) }
            recorder.fps = fps
        }
        agentSession.format = format
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            beginRecording(forAgent: true) { continuation.resume(with: $0) }
        }
    }

    func agentSetPaused(_ paused: Bool) throws {
        guard recorder.state == .recording else { throw AgentControlError.notRecording }
        if recorder.isPaused != paused {
            togglePause()
        }
    }

    /// Stops the recording and returns the saved file once it is written. Called while idle, it
    /// returns the last agent recording, so a recording the user stopped from the menu is not lost.
    func agentStop() async throws -> URL {
        switch recorder.state {
        case .recording:
            stopRecording()
        case .starting:
            throw AgentControlError.notRecording
        case .idle, .stopping:
            break
        }
        return try await agentSession.awaitResult()
    }

    func agentCancel() throws {
        guard recorder.state == .recording || recorder.state == .starting else { throw AgentControlError.notRecording }
        cancelRecording()
    }

    /// Shows a recording to the user in Quick Look, the same preview GIFt opens after a save.
    func agentShow(path: String) throws {
        guard FileManager.default.fileExists(atPath: path) else { throw AgentControlError.fileNotFound(path) }
        previewController.show(url: URL(fileURLWithPath: path))
    }

    /// Saves without review in the agent's format, and leaves the clipboard alone: an agent may
    /// record several clips, and the user's clipboard is not its to overwrite.
    func finishAgentRecording(_ result: Result<Recording, Error>) {
        recorder.fps = settings.defaultFPS
        let format = agentSession.format ?? settings.exportFormat
        switch result {
        case .failure(let error):
            agentSession.finish(.failure(error))
        case .success(let recording):
            updateStatusIcon(.processing)
            Task { [weak self] in
                guard let self else { return }
                let written: Result<URL, Error>
                do {
                    let edit = FrameEdit.unchanged(frameCount: recording.frames.count)
                    written = .success(try await RecordingExport.write(recording, edit: edit, format: format, to: self.settings.outputDirectory))
                } catch {
                    written = .failure(error)
                }
                self.updateStatusIcon(self.recorder.state == .idle ? .idle : .recording)
                if case .success(let url) = written {
                    self.showMessage("Saved \(url.lastPathComponent)")
                }
                self.agentSession.finish(written)
            }
        }
    }

    private func requireScreenRecording() throws {
        guard ensureScreenRecordingAccess() else { throw AgentControlError.screenRecordingNotPermitted }
    }

    private func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }

    private static func run(_ executable: String, _ arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.terminationHandler = { process in
                if process.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: AgentControlError.screenshotFailed("\(executable) exited with \(process.terminationStatus)"))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
