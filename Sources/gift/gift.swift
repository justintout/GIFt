import AppKit
@preconcurrency import ScreenCaptureKit
import CoreMedia
import OSLog
import Quartz
import GiftCore

private let appLog = Logger(subsystem: "com.justintout.gift", category: "app")
private let captureLog = Logger(subsystem: "com.justintout.gift", category: "capture")

private enum StatusIconState {
    case idle
    case recording
    case processing
}

// Selection context stored without keeping an NSScreen reference to remain Sendable.
struct SelectionContext: @unchecked Sendable {
    let selectionRect: CGRect
    let displayFrame: CGRect
    let displayID: CGDirectDisplayID
    let fallbackPointPixelScale: CGFloat
    let excludedWindowID: CGWindowID?
}

struct Settings: Codable {
    var outputDirectory: URL
    var autoStartAfterSelection: Bool
    var defaultFPS: Int
    var indicatorStyle: IndicatorStyle
    var hasCompletedInitialSetup: Bool

    static private let outputKey = "gift.outputDirectory"
    static private let autoStartKey = "gift.autoStartAfterSelection"
    static private let fpsKey = "gift.defaultFPS"
    static private let indicatorRedKey = "gift.indicator.red"
    static private let indicatorGreenKey = "gift.indicator.green"
    static private let indicatorBlueKey = "gift.indicator.blue"
    static private let indicatorOpacityKey = "gift.indicator.opacity"
    static private let indicatorBorderWidthKey = "gift.indicator.borderWidth"
    static private let initialSetupVersionKey = "gift.initialSetupVersion"
    static private let currentInitialSetupVersion = 1

    static func load() -> Settings {
        let defaults = UserDefaults.standard
        let defaultDir = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
        let url = defaults.url(forKey: outputKey) ?? defaultDir
        let auto = defaults.object(forKey: autoStartKey) as? Bool ?? true
        let fps = defaults.object(forKey: fpsKey) as? Int ?? 30
        let hasCompletedInitialSetup = defaults.integer(forKey: initialSetupVersionKey) >= currentInitialSetupVersion
        let indicatorStyle = IndicatorStyle(
            red: defaults.cgFloat(forKey: indicatorRedKey) ?? IndicatorStyle.default.red,
            green: defaults.cgFloat(forKey: indicatorGreenKey) ?? IndicatorStyle.default.green,
            blue: defaults.cgFloat(forKey: indicatorBlueKey) ?? IndicatorStyle.default.blue,
            fillOpacity: defaults.cgFloat(forKey: indicatorOpacityKey) ?? IndicatorStyle.default.fillOpacity,
            borderWidth: defaults.cgFloat(forKey: indicatorBorderWidthKey) ?? IndicatorStyle.default.borderWidth
        )
        return Settings(
            outputDirectory: url,
            autoStartAfterSelection: auto,
            defaultFPS: fps,
            indicatorStyle: indicatorStyle,
            hasCompletedInitialSetup: hasCompletedInitialSetup
        )
    }

    static func save(_ settings: Settings) {
        let defaults = UserDefaults.standard
        defaults.set(settings.outputDirectory, forKey: outputKey)
        defaults.set(settings.autoStartAfterSelection, forKey: autoStartKey)
        defaults.set(settings.defaultFPS, forKey: fpsKey)
        if settings.hasCompletedInitialSetup {
            defaults.set(currentInitialSetupVersion, forKey: initialSetupVersionKey)
        }
        defaults.set(Double(settings.indicatorStyle.red), forKey: indicatorRedKey)
        defaults.set(Double(settings.indicatorStyle.green), forKey: indicatorGreenKey)
        defaults.set(Double(settings.indicatorStyle.blue), forKey: indicatorBlueKey)
        defaults.set(Double(settings.indicatorStyle.fillOpacity), forKey: indicatorOpacityKey)
        defaults.set(Double(settings.indicatorStyle.borderWidth), forKey: indicatorBorderWidthKey)
    }
}

struct IndicatorStyle: Codable, Equatable {
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat
    var fillOpacity: CGFloat
    var borderWidth: CGFloat

    static let `default` = IndicatorStyle(red: 0.0, green: 0.48, blue: 1.0, fillOpacity: 0.08, borderWidth: 2)

    init(red: CGFloat, green: CGFloat, blue: CGFloat, fillOpacity: CGFloat, borderWidth: CGFloat) {
        self.red = red.clamped(to: 0...1)
        self.green = green.clamped(to: 0...1)
        self.blue = blue.clamped(to: 0...1)
        self.fillOpacity = fillOpacity.clamped(to: 0...0.4)
        self.borderWidth = borderWidth.clamped(to: 1...8)
    }

    init(color: NSColor, fillOpacity: CGFloat, borderWidth: CGFloat) {
        let color = color.usingColorSpace(.sRGB) ?? NSColor(calibratedRed: 0, green: 0.48, blue: 1, alpha: 1)
        self.init(red: color.redComponent, green: color.greenComponent, blue: color.blueComponent, fillOpacity: fillOpacity, borderWidth: borderWidth)
    }

    var color: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }
}

/// Simple status bar app for capturing a screen region to a GIF file.
@main
@MainActor
final class GiftApp: NSObject, NSApplicationDelegate {
    private let recorder = Recorder()
    private let previewController = GIFPreviewController()
    private var statusItem: NSStatusItem!
    private var startItem: NSMenuItem!
    private var stopItem: NSMenuItem!
    private var fpsItems: [NSMenuItem] = []
    private let indicatorWindow = SelectionIndicatorWindow()
    private var settings = Settings.load()
    private var settingsController: SettingsWindowController?
    private var processingIndicator: NSProgressIndicator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        appLog.info("applicationDidFinishLaunching")
        NSApp.setActivationPolicy(.accessory) // Hide dock icon, show only menu bar item
        setupMenuBar()
        applySettings()
        if !settings.hasCompletedInitialSetup {
            showSettings(initialSetup: !settings.hasCompletedInitialSetup)
        }
        appLog.info("setup complete; status item is nil? \(self.statusItem == nil, privacy: .public)")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            let needsInitialSetup = !settings.hasCompletedInitialSetup
            showSettings(initialSetup: needsInitialSetup)
        }
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        settingsController?.refreshPermissionStatus()
    }

    static func main() {
        appLog.info("entering main")
        let app = NSApplication.shared
        let delegate = GiftApp()
        app.delegate = delegate
        app.run()
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateStatusIcon(.idle)
        let menu = NSMenu()

        startItem = NSMenuItem(title: "Start Recording", action: #selector(startRecording), keyEquivalent: "")

        stopItem = NSMenuItem(title: "Stop Recording", action: #selector(stopRecording), keyEquivalent: "")
        stopItem.isEnabled = false

        menu.addItem(startItem)
        menu.addItem(stopItem)
        menu.addItem(.separator())

        let selectItem = NSMenuItem(title: "Select Area…", action: #selector(selectArea), keyEquivalent: "")
        menu.addItem(selectItem)

        let fpsMenu = NSMenu(title: "Frame Rate")
        let choices = [10, 15, 24, 30]
        for fps in choices {
            let item = NSMenuItem(title: "\(fps) fps", action: #selector(changeFPS(_:)), keyEquivalent: "")
            item.tag = fps
            item.state = fps == settings.defaultFPS ? .on : .off
            fpsMenu.addItem(item)
            fpsItems.append(item)
        }
        let fpsItem = NSMenuItem(title: "Frame Rate", action: nil, keyEquivalent: "")
        fpsItem.submenu = fpsMenu
        menu.addItem(fpsItem)

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.keyEquivalentModifierMask = [.command]
        menu.addItem(settingsItem)
        let permissionItem = NSMenuItem(title: "Screen Recording Setup…", action: #selector(openPermissionSetup), keyEquivalent: "")
        menu.addItem(permissionItem)
        let openItem = NSMenuItem(title: "Open Output Folder", action: #selector(openOutputFolder), keyEquivalent: "")
        menu.addItem(openItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit GIFt", action: #selector(quit), keyEquivalent: "")
        menu.addItem(quitItem)

        statusItem.menu = menu
        appLog.info("menu bar icon and menu configured")
    }

    @objc private func startRecording() {
        guard ensureScreenRecordingAccess(onGranted: { [weak self] in self?.startRecording() }) else { return }
        guard recorder.hasSelection else {
            notify(text: "Select an area to start recording.")
            presentSelection(startAfterSelection: true)
            return
        }
        beginRecording()
    }

    private func beginRecording() {
        guard ensureScreenRecordingAccess(onGranted: { [weak self] in self?.beginRecording() }) else { return }
        guard recorder.state == .idle else {
            appLog.info("start requested while already recording; ignoring")
            return
        }
        startItem.isEnabled = false
        stopItem.isEnabled = false

        recorder.start { [weak self] status in
            Task { @MainActor in
                appLog.info("recorder emitted status: \(status, privacy: .public)")
                self?.updateStatusIcon(.recording)
                self?.indicatorWindow.setRecording(true)
                self?.stopItem.isEnabled = true
                EscTap.shared.enable { [weak self] in self?.cancelRecording() }
                self?.notify(text: status)
            }
        } completion: { [weak self] result in
            Task { @MainActor in
                self?.startItem.isEnabled = true
                self?.stopItem.isEnabled = false
                self?.startItem.title = "Start Recording"
                self?.updateStatusIcon(.idle)
                switch result {
                case .success(let url):
                    self?.notify(text: "Saved GIF to \(url.lastPathComponent)")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.path, forType: .string)
                    self?.previewController.show(url: url)
                case .failure(let error):
                    if (error as? Recorder.RecorderError) != .canceled {
                        self?.notify(text: "Error: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    @objc private func stopRecording() {
        indicatorWindow.hide()
        startItem.title = "Processing GIF…"
        startItem.isEnabled = false
        stopItem.isEnabled = false
        updateStatusIcon(.processing)
        EscTap.shared.disable()
        DispatchQueue.main.async { [recorder] in
            recorder.stop()
        }
    }

    @objc func cancelRecording() {
        guard recorder.state == .recording || recorder.state == .starting else { return }
        recorder.cancel()
        notify(text: "Recording canceled")
        indicatorWindow.setRecording(false)
        startItem.isEnabled = true
        startItem.title = "Start Recording"
        stopItem.isEnabled = false
        updateStatusIcon(.idle)
        EscTap.shared.disable()
    }

    @objc private func selectArea() {
        presentSelection(startAfterSelection: settings.autoStartAfterSelection)
    }

    private func presentSelection(startAfterSelection: Bool) {
        guard ensureScreenRecordingAccess(onGranted: { [weak self] in self?.presentSelection(startAfterSelection: startAfterSelection) }) else { return }
        appLog.info("presenting selection overlay")
        SelectionOverlay.present { [weak self] result in
            guard let result else { return }
            guard let self else { return }
            appLog.info("selection returned rect \(String(describing: result.rect), privacy: .public) on display \(result.screen.displayID, privacy: .public)")
            do {
                let selectedRect = try self.recorder.setSelection(rect: result.rect, on: result.screen, excludedWindowID: self.indicatorWindow.windowID)
                self.indicatorWindow.show(rect: selectedRect, recording: false)
            } catch {
                self.notify(text: "Error: \(error.localizedDescription)")
                return
            }
            if startAfterSelection {
                self.beginRecording()
            }
        }
    }

    @objc private func changeFPS(_ sender: NSMenuItem) {
        recorder.fps = sender.tag
        settings.defaultFPS = sender.tag
        Settings.save(settings)
        fpsItems.forEach { $0.state = ($0 == sender) ? .on : .off }
        notify(text: "Frame rate set to \(sender.tag) fps")
    }

    @objc private func openOutputFolder() {
        NSWorkspace.shared.open(recorder.outputDirectory)
    }

    @objc private func openSettings() {
        showSettings(initialSetup: !settings.hasCompletedInitialSetup)
    }

    private func showSettings(initialSetup: Bool, onPermissionGranted: (() -> Void)? = nil) {
        if settingsController == nil {
            settingsController = SettingsWindowController(settings: settings) { [weak self] newSettings in
                guard let self else { return }
                self.settings = newSettings
                Settings.save(newSettings)
                self.applySettings()
            }
        }
        settingsController?.show(settings: settings, initialSetup: initialSetup, onPermissionGranted: onPermissionGranted)
    }

    @objc private func openPermissionSetup() {
        showSettings(initialSetup: false)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func ensureScreenRecordingAccess(onGranted: (() -> Void)? = nil) -> Bool {
        guard !CGPreflightScreenCaptureAccess() else { return true }
        showSettings(initialSetup: false, onPermissionGranted: onGranted)
        return false
    }

    private func updateStatusIcon(_ state: StatusIconState) {
        guard let button = statusItem.button else { return }
        switch state {
        case .idle, .recording:
            processingIndicator?.stopAnimation(nil)
            processingIndicator?.removeFromSuperview()
            processingIndicator = nil
            button.image = makeStatusImage(state: state)
            button.image?.isTemplate = false
            button.toolTip = state == .recording ? "Recording" : "GIFt"
        case .processing:
            button.image = nil
            button.toolTip = "Processing GIF…"
            let indicator = processingIndicator ?? makeProcessingIndicator(in: button)
            processingIndicator = indicator
            indicator.startAnimation(nil)
        }
    }

    private func makeStatusImage(state: StatusIconState) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()
        let outerRect = NSRect(x: 2, y: 2, width: size.width - 4, height: size.height - 4)
        let outerPath = NSBezierPath(ovalIn: outerRect)
        NSColor.white.setStroke()
        outerPath.lineWidth = 2
        outerPath.stroke()

        let innerSize: CGFloat = 8
        let innerRect = NSRect(x: (size.width - innerSize)/2, y: (size.height - innerSize)/2, width: innerSize, height: innerSize)
        let innerPath = NSBezierPath(ovalIn: innerRect)
        (state == .recording ? NSColor.systemRed : NSColor.clear).setFill()
        innerPath.fill()
        NSColor.white.setStroke()
        innerPath.lineWidth = 1
        innerPath.stroke()
        image.unlockFocus()
        return image
    }

    private func makeProcessingIndicator(in button: NSStatusBarButton) -> NSProgressIndicator {
        let indicator = NSProgressIndicator()
        indicator.style = .spinning
        indicator.controlSize = .small
        indicator.isIndeterminate = true
        indicator.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(indicator)
        NSLayoutConstraint.activate([
            indicator.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            indicator.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            indicator.widthAnchor.constraint(equalToConstant: 16),
            indicator.heightAnchor.constraint(equalToConstant: 16)
        ])
        return indicator
    }

    private func notify(text: String) {
        let notification = NSUserNotification()
        notification.title = "GIFt"
        notification.informativeText = text
        NSUserNotificationCenter.default.deliver(notification)
    }

    private func applySettings() {
        recorder.outputDirectory = settings.outputDirectory
        recorder.fps = settings.defaultFPS
        indicatorWindow.style = settings.indicatorStyle
        fpsItems.forEach { $0.state = ($0.tag == settings.defaultFPS) ? .on : .off }
    }
}

// MARK: - Recorder

final class Recorder: NSObject, SCStreamOutput {
    enum RecorderError: LocalizedError, Equatable {
        case noSelection
        case streamSetupFailed
        case noFrames
        case permissionDenied
        case canceled

        var errorDescription: String? {
            switch self {
            case .noSelection: return "Select an area before recording."
            case .streamSetupFailed: return "Unable to start screen capture."
            case .noFrames: return "No frames were captured."
            case .permissionDenied: return "Screen recording permission denied."
            case .canceled: return "Recording canceled."
            }
        }
    }

    enum State { case idle, starting, recording, stopping }

    private(set) var state: State = .idle
    var fps: Int = 15
    var hasSelection: Bool { selection != nil }

    private var selection: SelectionContext?
    private let captureQueue = DispatchQueue(label: "gift.capture", qos: .userInteractive)
    private let encodingQueue = DispatchQueue(label: "gift.encoding", qos: .userInitiated)
    private let renderContext = CIContext(options: [.useSoftwareRenderer: false])
    private var frames: [(CGImage, CMTime)] = []
    private var stream: SCStream?
    private var completionHandler: ((Result<URL, Error>) -> Void)?
    private var isCanceled = false
    var outputDirectory: URL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!

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

    func start(status: @escaping @Sendable (String) -> Void, completion: @escaping @Sendable (Result<URL, Error>) -> Void) {
        guard state == .idle else { return }
        guard let selection else {
            captureLog.error("start called with no selection")
            completion(.failure(RecorderError.noSelection));
            return
        }
        state = .starting
        completionHandler = completion
        captureQueue.sync {
            self.frames.removeAll()
            self.isCanceled = false
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.beginCapture(selection: selection)
                await MainActor.run { status("Recording… Press Stop when done.") }
            } catch {
                await MainActor.run {
                    self.finish(.failure(error))
                }
            }
        }
    }

    func stop() {
        guard state == .recording else { return }
        state = .stopping
        let currentStream = stream
        let fps = self.fps
        let outputDirectory = self.outputDirectory
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try await currentStream?.stopCapture()
            } catch {
                self?.finishOnMain(.failure(error))
                return
            }
            guard let self else { return }
            let capturedFrames = captureQueue.sync {
                let capturedFrames = self.frames
                self.frames.removeAll()
                self.isCanceled = false
                return capturedFrames
            }
            encodingQueue.async { [weak self] in
                let result: Result<URL, Error>
                do {
                    let gifFrames = capturedFrames.map { GIFFrame(image: $0.0, timestamp: $0.1) }
                    let url = try GIFWriter.write(frames: gifFrames, fps: fps, outputDirectory: outputDirectory)
                    captureLog.info("wrote GIF with \(capturedFrames.count, privacy: .public) frames to \(url.path, privacy: .public)")
                    result = .success(url)
                } catch {
                    result = .failure(error)
                }
                self?.finishOnMain(result)
            }
        }
    }

    func cancel() {
        guard state == .recording || state == .starting else { return }
        state = .stopping
        let currentStream = stream
        captureQueue.sync {
            self.isCanceled = true
            self.frames.removeAll()
        }
        Task { @MainActor in
            try? await currentStream?.stopCapture()
            finish(.failure(RecorderError.canceled))
        }
    }

    // MARK: ScreenCaptureKit

    private func beginCapture(selection: SelectionContext) async throws {
        // Ensure permission
        guard CGPreflightScreenCaptureAccess() else { throw RecorderError.permissionDenied }

        let content = try await SCShareableContent.current
        guard let display = content.displays.first(where: { $0.displayID == selection.displayID }) else {
            throw RecorderError.streamSetupFailed
        }

        let excludedWindows: [SCWindow]
        if let excludedID = selection.excludedWindowID {
            excludedWindows = content.windows.filter { $0.windowID == excludedID }
        } else {
            excludedWindows = []
        }

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
            on: DisplayGeometry(frame: selection.displayFrame, pointPixelScale: scale)
        )

        let config = SCStreamConfiguration()
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.scalesToFit = false
        config.showsCursor = true
        config.minimumFrameInterval = CMTime(value: 1, timescale: Int32(fps))
        config.sourceRect = geometry.sourceRect
        config.destinationRect = CGRect(x: 0, y: 0, width: geometry.outputWidth, height: geometry.outputHeight)
        config.width = geometry.outputWidth
        config.height = geometry.outputHeight
        config.queueDepth = 8
        config.colorSpaceName = CGColorSpace.sRGB as CFString
        if #available(macOS 14.0, *) {
            config.captureResolution = .best
        }

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        captureLog.info("starting capture on display \(selection.displayID, privacy: .public) source \(String(describing: geometry.sourceRect), privacy: .public) output \(geometry.outputWidth, privacy: .public)x\(geometry.outputHeight, privacy: .public) scale \(scale, privacy: .public) fps \(self.fps, privacy: .public)")
        try await stream.startCapture()
        guard state == .starting else {
            try? await stream.stopCapture()
            throw RecorderError.canceled
        }
        self.stream = stream
        state = .recording
        captureLog.info("capture started")
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              CMSampleBufferIsValid(sampleBuffer),
              let pixelBuffer = sampleBuffer.imageBuffer else { return }

        if isCanceled { return }

        // Only process complete frames to avoid duplicates/empties.
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
                frames.append((cgImage, timestamp))
            }
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        stream = nil
        state = .idle
        let completion = completionHandler
        completionHandler = nil
        completion?(result)
    }

    private func finishOnMain(_ result: Result<URL, Error>) {
        Task { @MainActor [weak self] in
            guard let self, self.completionHandler != nil else { return }
            self.finish(result)
        }
    }
}

// Listen for stream failures (e.g., queue overruns) so we don't silently stop capturing.
extension Recorder: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            captureLog.error("stream stopped with error: \(String(describing: error), privacy: .public)")
            captureQueue.sync {
                self.frames.removeAll()
                self.isCanceled = false
            }
            finish(.failure(error))
        }
    }
}

// MARK: - GIF Preview

@MainActor
final class GIFPreviewController: NSObject, @preconcurrency QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private var previewURL: NSURL?

    func show(url: URL) {
        previewURL = url as NSURL
        NSApp.activate(ignoringOtherApps: true)

        guard let panel = QLPreviewPanel.shared() else {
            // Avoid NSWorkspace.open(url): LaunchServices may route GIFs to Preview.
            openWithQuickLook(url: url)
            return
        }
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewURL == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        previewURL
    }

    private func openWithQuickLook(url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
        process.arguments = ["-p", url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            appLog.error("failed to open Quick Look preview: \(String(describing: error), privacy: .public)")
        }
    }
}

// MARK: - Selection Overlay

struct SelectionResult {
    let rect: CGRect
    let screen: NSScreen
}

@MainActor
final class SelectionOverlay: NSWindow {
    var selectionView: SelectionView
    private var completion: (SelectionResult?) -> Void
    private var targetScreen: NSScreen
    private static var activeOverlays: [SelectionOverlay] = []

    // Designated initializer required by NSWindow subclasses.
    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        self.selectionView = SelectionView(frame: contentRect)
        self.completion = { _ in }
        self.targetScreen = NSScreen.main ?? NSScreen.screens.first!
        super.init(contentRect: contentRect, styleMask: styleMask, backing: backingStoreType, defer: flag)
        configure()
    }

    convenience init(screen: NSScreen, completion: @escaping (SelectionResult?) -> Void) {
        self.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        self.targetScreen = screen
        self.completion = completion
        self.selectionView.onComplete = { [weak self] rect in
            guard let self else { return }
            if let rect {
                // Convert window-local rect to global coordinates on the owning screen.
                let globalRect = self.convertToScreen(rect)
                self.completion(SelectionResult(rect: globalRect, screen: self.targetScreen))
            } else {
                self.completion(nil)
            }
            self.orderOut(nil)
        }
    }

    required init?(coder: NSCoder) {
        return nil
    }

    private func configure() {
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        ignoresMouseEvents = false
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = selectionView
        makeKeyAndOrderFront(nil)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    static func present(completion: @escaping (SelectionResult?) -> Void) {
        // Clean up any overlays still lingering from a previous selection.
        activeOverlays.forEach { $0.orderOut(nil) }
        activeOverlays.removeAll()
        EscTap.shared.disable()

        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            completion(nil); return
        }

        // Show a separate overlay on each screen so the window's backing scale and coordinates match that display.
        var overlays: [SelectionOverlay] = []
        var didComplete = false

        func finish(_ result: SelectionResult?) {
            guard !didComplete else { return }
            didComplete = true
            overlays.forEach { $0.orderOut(nil) }
            overlays.removeAll()
            activeOverlays.removeAll()
            EscTap.shared.disable()
            // If ESC canceled while recording, stop without saving.
            if result == nil {
                NSApp.sendAction(#selector(GiftApp.cancelRecording), to: nil, from: nil)
            }
            completion(result)
        }

        NSApp.activate(ignoringOtherApps: true)

        overlays = screens.map { screen in
            let overlay = SelectionOverlay(screen: screen, completion: finish)
            overlay.setFrame(screen.frame, display: false)
            overlay.selectionView.frame = NSRect(origin: .zero, size: screen.frame.size)
            overlay.isReleasedWhenClosed = false
            overlay.orderFrontRegardless()
            overlay.makeKeyAndOrderFront(nil)
            overlay.makeFirstResponder(overlay.selectionView)
            return overlay
        }
        activeOverlays = overlays
        EscTap.shared.enable(handler: { finish(nil) })
    }
}

// Passive overlay to visualize the saved selection (and flash red while recording)
final class SelectionIndicatorWindow: NSWindow {
    private let indicatorView = SelectionIndicatorView()
    private var lastRect: CGRect?

    var style: IndicatorStyle = .default {
        didSet {
            indicatorView.style = style
            indicatorView.needsDisplay = true
        }
    }

    var windowID: CGWindowID { CGWindowID(windowNumber) }

    init() {
        super.init(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        ignoresMouseEvents = true
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = indicatorView
    }

    func show(rect: CGRect, recording: Bool) {
        let frame = rect.integral
        lastRect = frame
        setFrame(frame, display: true)
        indicatorView.frame = NSRect(origin: .zero, size: frame.size)
        indicatorView.isRecording = recording
        orderFrontRegardless()
        indicatorView.needsDisplay = true
    }

    func setRecording(_ recording: Bool) {
        indicatorView.isRecording = recording
        indicatorView.needsDisplay = true
        if recording {
            if let rect = lastRect {
                show(rect: rect, recording: true)
            }
        } else {
            hide()
        }
    }

    func hide() {
        orderOut(nil)
    }
}

final class SelectionIndicatorView: NSView {
    var isRecording = false
    var style: IndicatorStyle = .default

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill()

        let path = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
        path.lineWidth = style.borderWidth + (isRecording ? 1 : 0)
        let color = style.color
        color.setStroke()
        if style.fillOpacity > 0 {
            color.withAlphaComponent(style.fillOpacity).setFill()
            path.fill()
        }
        path.stroke()
    }
}

@MainActor
final class SelectionView: NSView {
    var onComplete: ((CGRect?) -> Void)?
    private var startPoint: CGPoint?
    private var currentRect: CGRect = .zero

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        startPoint = event.locationInWindow
        currentRect = .zero
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = startPoint else { return }
        let current = event.locationInWindow
        currentRect = CGRect(x: min(start.x, current.x),
                             y: min(start.y, current.y),
                             width: abs(start.x - current.x),
                             height: abs(start.y - current.y))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard startPoint != nil else { return }
        onComplete?(currentRect.isEmpty ? nil : currentRect)
        startPoint = nil
        currentRect = .zero
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            onComplete?(nil)
        } else {
            super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.black.withAlphaComponent(0.35).setFill()
        dirtyRect.fill()

        if !currentRect.isEmpty {
            NSColor.clear.setFill()
            currentRect.fill(using: .sourceOut)
            NSColor.systemBlue.setStroke()
            let path = NSBezierPath(rect: currentRect)
            path.lineWidth = 2
            path.stroke()
        }
    }
}

// MARK: - Helpers

private extension NSScreen {
    var displayID: CGDirectDisplayID {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! CGDirectDisplayID
    }
}

private extension NSScreen {
    static func screen(containing rect: CGRect) -> NSScreen? {
        // Prefer the screen with the largest intersection with the rect.
        NSScreen.screens.max(by: { $0.frame.intersection(rect).area < $1.frame.intersection(rect).area })
    }
}

private extension CGRect {
    var area: CGFloat { width * height }

    func clamped(to bounds: CGRect) -> CGRect {
        let x1 = max(minX, bounds.minX)
        let y1 = max(minY, bounds.minY)
        let x2 = min(maxX, bounds.maxX)
        let y2 = min(maxY, bounds.maxY)
        if x2 <= x1 || y2 <= y1 { return .zero }
        return CGRect(x: x1, y: y1, width: x2 - x1, height: y2 - y1)
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

private extension UserDefaults {
    func cgFloat(forKey key: String) -> CGFloat? {
        guard let value = object(forKey: key) as? Double else { return nil }
        return CGFloat(value)
    }
}

// Global ESC catcher using a CGEvent tap so we get key presses even when another app is frontmost.
@MainActor
private final class EscTap {
    static let shared = EscTap()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var handler: (() -> Void)?

    func enable(handler: @escaping () -> Void) {
        self.handler = handler
        if tap == nil {
            let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                    place: .headInsertEventTap,
                                    options: .listenOnly,
                                    eventsOfInterest: mask,
                                    callback: { _, type, event, refcon in
                                        guard type == .keyDown else { return Unmanaged.passUnretained(event) }
                                        if event.getIntegerValueField(.keyboardEventKeycode) == 53 {
                                            let tap = Unmanaged<EscTap>.fromOpaque(refcon!).takeUnretainedValue()
                                            tap.handler?()
                                        }
                                        return Unmanaged.passUnretained(event)
                                    },
                                    userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))
            if let tap {
                source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            }
        }
        if let source {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
    }

    func disable() {
        handler = nil
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
    }
}

// Allow Recorder to cross task boundaries; internal state is only mutated on the capture queue or main thread.
extension Recorder: @unchecked Sendable {}
