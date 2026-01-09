import AppKit
@preconcurrency import ScreenCaptureKit
import UniformTypeIdentifiers
import ImageIO
import VideoToolbox
import AVFoundation

// Selection context stored without keeping an NSScreen reference to remain Sendable.
struct SelectionContext: @unchecked Sendable {
    let rect: CGRect
    let displayID: CGDirectDisplayID
    let cropRect: CGRect
    let excludedWindowID: CGWindowID?
}

struct Settings: Codable {
    var outputDirectory: URL
    var autoStartAfterSelection: Bool
    var defaultFPS: Int

    static private let outputKey = "gift.outputDirectory"
    static private let autoStartKey = "gift.autoStartAfterSelection"
    static private let fpsKey = "gift.defaultFPS"

    static func load() -> Settings {
        let defaults = UserDefaults.standard
        let defaultDir = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
        let url = defaults.url(forKey: outputKey) ?? defaultDir
        let auto = defaults.object(forKey: autoStartKey) as? Bool ?? true
        let fps = defaults.object(forKey: fpsKey) as? Int ?? 30
        return Settings(outputDirectory: url, autoStartAfterSelection: auto, defaultFPS: fps)
    }

    static func save(_ settings: Settings) {
        let defaults = UserDefaults.standard
        defaults.set(settings.outputDirectory, forKey: outputKey)
        defaults.set(settings.autoStartAfterSelection, forKey: autoStartKey)
        defaults.set(settings.defaultFPS, forKey: fpsKey)
    }
}

/// Simple status bar app for capturing a screen region to a GIF file.
@main
@MainActor
final class GiftApp: NSObject, NSApplicationDelegate {
    private let recorder = Recorder()
    private var statusItem: NSStatusItem!
    private var startItem: NSMenuItem!
    private var stopItem: NSMenuItem!
    private var fpsItems: [NSMenuItem] = []
    private let indicatorWindow = SelectionIndicatorWindow()
    private var settings = Settings.load()
    private var settingsController: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // Hide dock icon, show only menu bar item
        // Prompt once on launch so the permission dialog appears before first capture.
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }
        setupMenuBar()
        applySettings()
    }

    static func main() {
        let app = NSApplication.shared
        let delegate = GiftApp()
        app.delegate = delegate
        app.run()
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateStatusIcon(recording: false)
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
        let openItem = NSMenuItem(title: "Open Output Folder", action: #selector(openOutputFolder), keyEquivalent: "")
        menu.addItem(openItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit GIFt", action: #selector(quit), keyEquivalent: "")
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @objc private func startRecording() {
        guard recorder.state == .idle else { return }
        startItem.isEnabled = false
        stopItem.isEnabled = true

        EscTap.shared.enable { [weak self] in self?.cancelRecording() }

        recorder.start { [weak self] status in
            Task { @MainActor in
                self?.updateStatusIcon(recording: true)
                self?.indicatorWindow.setRecording(true)
                self?.notify(text: status)
            }
        } completion: { [weak self] result in
            Task { @MainActor in
                self?.startItem.isEnabled = true
                self?.stopItem.isEnabled = false
                self?.updateStatusIcon(recording: false)
                self?.indicatorWindow.setRecording(false)
                switch result {
                case .success(let url):
                    self?.notify(text: "Saved GIF to \(url.lastPathComponent)")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.path, forType: .string)
                case .failure(let error):
                    self?.notify(text: "Error: \(error.localizedDescription)")
                }
            }
        }
    }

    @objc private func stopRecording() {
        recorder.stop()
        EscTap.shared.disable()
    }

    @objc func cancelRecording() {
        guard recorder.state == .recording else { return }
        recorder.cancel()
        notify(text: "Recording canceled")
        indicatorWindow.setRecording(false)
        startItem.isEnabled = true
        stopItem.isEnabled = false
        updateStatusIcon(recording: false)
        EscTap.shared.disable()
    }

    @objc private func selectArea() {
        SelectionOverlay.present { [weak self] result in
            guard let result else { return }
            guard let self else { return }
            self.recorder.setSelection(rect: result.rect, on: result.screen, excludedWindowID: self.indicatorWindow.windowID)
            self.indicatorWindow.show(rect: result.rect, recording: false)
            if self.settings.autoStartAfterSelection {
                self.startRecording()
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
        if settingsController == nil {
            settingsController = SettingsWindowController(settings: settings) { [weak self] newSettings in
                guard let self else { return }
                self.settings = newSettings
                Settings.save(newSettings)
                self.applySettings()
            }
        }
        settingsController?.showWindow(nil)
        settingsController?.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func updateStatusIcon(recording: Bool) {
        guard let button = statusItem.button else { return }
        button.image = makeStatusImage(recording: recording)
        button.image?.isTemplate = false
    }

    private func makeStatusImage(recording: Bool) -> NSImage {
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
        (recording ? NSColor.systemRed : NSColor.clear).setFill()
        innerPath.fill()
        NSColor.white.setStroke()
        innerPath.lineWidth = 1
        innerPath.stroke()
        image.unlockFocus()
        return image
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
        fpsItems.forEach { $0.state = ($0.tag == settings.defaultFPS) ? .on : .off }
    }
}

// MARK: - Recorder

final class Recorder: NSObject, SCStreamOutput {
    enum RecorderError: LocalizedError {
        case noSelection
        case streamSetupFailed
        case noFrames
        case permissionDenied

        var errorDescription: String? {
            switch self {
            case .noSelection: return "Select an area before recording."
            case .streamSetupFailed: return "Unable to start screen capture."
            case .noFrames: return "No frames were captured."
            case .permissionDenied: return "Screen recording permission denied."
            }
        }
    }

    enum State { case idle, recording }

    private(set) var state: State = .idle
    var fps: Int = 15

    private var selection: SelectionContext?
    private let captureQueue = DispatchQueue(label: "gift.capture", qos: .userInteractive)
    private let renderContext = CIContext(options: [.useSoftwareRenderer: false])
    private var frames: [(CGImage, CMTime)] = []
    private var stream: SCStream?
    private var startTime: CMTime = .zero
    private var completionHandler: ((Result<URL, Error>) -> Void)?
    private var isCanceled = false
    var outputDirectory: URL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!

    func setSelection(rect: CGRect, on screen: NSScreen, excludedWindowID: CGWindowID?) {
        let crop = captureRect(rect, on: screen)
        selection = SelectionContext(rect: rect.integral, displayID: screen.displayID, cropRect: crop, excludedWindowID: excludedWindowID)
    }

    func start(status: @escaping @Sendable (String) -> Void, completion: @escaping @Sendable (Result<URL, Error>) -> Void) {
        guard state == .idle else { return }
        guard let selection else {
            completion(.failure(RecorderError.noSelection));
            return
        }
        completionHandler = completion
        frames.removeAll()

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.beginCapture(selection: selection)
                await MainActor.run { status("Recording… Press Stop when done.") }
            } catch {
                await MainActor.run { completion(.failure(error)) }
            }
        }
    }

    func stop() {
        guard state == .recording else { return }
        isCanceled = false
        Task { @MainActor in
            try? await stream?.stopCapture()
            stream = nil
            state = .idle
            do {
                let url = try writeGIF()
                completionHandler?(.success(url))
            } catch {
                completionHandler?(.failure(error))
            }
            completionHandler = nil
        }
    }

    func cancel() {
        guard state == .recording else { return }
        isCanceled = true
        Task { @MainActor in
            try? await stream?.stopCapture()
            stream = nil
            state = .idle
            frames.removeAll()
            completionHandler?(.failure(RecorderError.noFrames))
            completionHandler = nil
        }
    }

    // MARK: ScreenCaptureKit

    private func beginCapture(selection: SelectionContext) async throws {
        // Ensure permission
        let accessGranted = CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()
        guard accessGranted else { throw RecorderError.permissionDenied }
        guard selection.cropRect.width > 0, selection.cropRect.height > 0 else {
            throw RecorderError.streamSetupFailed
        }

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

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: excludedWindows)
        let config = SCStreamConfiguration()
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.scalesToFit = false
        config.showsCursor = true
        config.minimumFrameInterval = CMTime(value: 1, timescale: Int32(fps))
        config.sourceRect = selection.cropRect            // capture only the chosen region
        config.width = Int(selection.cropRect.width)
        config.height = Int(selection.cropRect.height)
        config.queueDepth = 8                             // buffer a few frames to reduce drops
        config.colorSpaceName = CGColorSpace.sRGB as CFString

        stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream?.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        state = .recording
        startTime = .zero
        try await stream?.startCapture()
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
        if startTime == .zero { startTime = timestamp }

        autoreleasepool {
            let ciImage = CIImage(cvImageBuffer: pixelBuffer)
            if let cgImage = renderContext.createCGImage(ciImage, from: ciImage.extent) {
                frames.append((cgImage, timestamp))
            }
        }
    }

    // MARK: GIF Writing

    private func writeGIF() throws -> URL {
        guard !frames.isEmpty else { throw RecorderError.noFrames }
        let url = outputDirectory.appendingPathComponent("gift-\(Int(Date().timeIntervalSince1970)).gif")

        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else {
            throw RecorderError.streamSetupFailed
        }

        let delay = 1.0 / Double(fps)
        let frameProps: CFDictionary = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]
        ] as CFDictionary
        let gifProps: CFDictionary = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ] as CFDictionary
        CGImageDestinationSetProperties(destination, gifProps)

        for frame in frames {
            CGImageDestinationAddImage(destination, frame.0, frameProps)
        }

        guard CGImageDestinationFinalize(destination) else {
            throw RecorderError.streamSetupFailed
        }
        return url
    }

    // Convert selection rect in points to pixel-based capture rect for ScreenCaptureKit
    private func captureRect(_ rect: CGRect, on screen: NSScreen) -> CGRect {
        // Convert from global screen coords to display-local pixels
        let scale = screen.backingScaleFactor
        let local = CGRect(x: rect.origin.x - screen.frame.origin.x,
                           y: rect.origin.y - screen.frame.origin.y,
                           width: rect.width,
                           height: rect.height)
        let pixelRect = CGRect(x: local.origin.x * scale,
                               y: local.origin.y * scale,
                               width: local.width * scale,
                               height: local.height * scale)
        let screenHeightPixels = screen.frame.height * scale
        let originY = screenHeightPixels - pixelRect.origin.y - pixelRect.height
        return CGRect(x: pixelRect.origin.x, y: originY, width: pixelRect.width, height: pixelRect.height).integral
    }
}

// Listen for stream failures (e.g., queue overruns) so we don't silently stop capturing.
extension Recorder: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            completionHandler?(.failure(error))
            completionHandler = nil
            state = .idle
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

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill()

        let path = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
        path.lineWidth = isRecording ? 3 : 2
        let color = isRecording ? NSColor.systemRed : NSColor.systemBlue
        color.setStroke()
        color.withAlphaComponent(isRecording ? 0.15 : 0.08).setFill()
        path.fill()
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
