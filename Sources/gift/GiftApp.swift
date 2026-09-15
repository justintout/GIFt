import AppKit

/// Menu bar app for capturing a screen region to a GIF file.
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
        NSApp.setActivationPolicy(.accessory) // Menu bar only, no Dock icon.
        setupMenuBar()
        applySettings()
        if !settings.hasCompletedInitialSetup {
            showSettings(initialSetup: true)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showSettings(initialSetup: !settings.hasCompletedInitialSetup)
        }
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        settingsController?.refreshPermissionStatus()
    }

    static func main() {
        let app = NSApplication.shared
        let delegate = GiftApp()
        app.delegate = delegate
        app.run()
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()

        startItem = NSMenuItem(title: "Start Recording", action: #selector(startRecording), keyEquivalent: "")
        stopItem = NSMenuItem(title: "Stop Recording", action: #selector(stopRecording), keyEquivalent: "")
        menu.addItem(startItem)
        menu.addItem(stopItem)
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Select Area…", action: #selector(selectArea), keyEquivalent: ""))

        let fpsMenu = NSMenu(title: "Frame Rate")
        for fps in Settings.allowedFrameRates {
            let item = NSMenuItem(title: "\(fps) fps", action: #selector(changeFPS(_:)), keyEquivalent: "")
            item.tag = fps
            fpsMenu.addItem(item)
            fpsItems.append(item)
        }
        let fpsItem = NSMenuItem(title: "Frame Rate", action: nil, keyEquivalent: "")
        fpsItem.submenu = fpsMenu
        menu.addItem(fpsItem)

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.keyEquivalentModifierMask = [.command]
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem(title: "Screen Recording Setup…", action: #selector(openPermissionSetup), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Open Output Folder", action: #selector(openOutputFolder), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit GIFt", action: #selector(quit), keyEquivalent: ""))

        statusItem.menu = menu
        updateMenuState()
        updateStatusIcon(.idle)
    }

    /// The single place menu enablement and titles are decided, so no code path can leave the menu
    /// showing an action that is not available.
    private func updateMenuState() {
        switch recorder.state {
        case .idle:
            startItem.title = "Start Recording"
            startItem.isEnabled = true
            stopItem.isEnabled = false
        case .starting:
            startItem.title = "Starting…"
            startItem.isEnabled = false
            stopItem.isEnabled = false
        case .recording:
            startItem.title = "Recording…"
            startItem.isEnabled = false
            stopItem.isEnabled = true
        case .stopping:
            startItem.title = "Processing GIF…"
            startItem.isEnabled = false
            stopItem.isEnabled = false
        }
        // The frame rate is frozen for the duration of a recording.
        fpsItems.forEach { $0.isEnabled = recorder.state == .idle }
    }

    @objc private func startRecording() {
        guard ensureScreenRecordingAccess(onGranted: { [weak self] in self?.startRecording() }) else { return }
        guard recorder.hasSelection else {
            showMessage("Select an area to start recording.")
            presentSelection(startAfterSelection: true)
            return
        }
        beginRecording()
    }

    private func beginRecording() {
        guard recorder.state == .idle else {
            appLog.info("start requested while already recording; ignoring")
            return
        }

        recorder.start { [weak self] status in
            guard let self else { return }
            appLog.info("recorder emitted status: \(status, privacy: .public)")
            self.updateMenuState()
            self.updateStatusIcon(.recording)
            self.indicatorWindow.setRecording(true)
            EscTap.shared.enable { [weak self] in self?.cancelRecording() }
        } completion: { [weak self] result in
            guard let self else { return }
            self.updateMenuState()
            self.updateStatusIcon(.idle)
            self.indicatorWindow.setRecording(false)
            EscTap.shared.disable()

            switch result {
            case .success(let url):
                self.showMessage("Saved \(url.lastPathComponent)")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.path, forType: .string)
                self.previewController.show(url: url)
            case .failure(let error):
                if (error as? Recorder.RecorderError) != .canceled {
                    self.showMessage("Error: \(error.localizedDescription)")
                }
            }
        }
    }

    @objc private func stopRecording() {
        indicatorWindow.hide()
        recorder.stop()
        updateMenuState()
        updateStatusIcon(.processing)
        EscTap.shared.disable()
    }

    @objc func cancelRecording() {
        guard recorder.state == .recording || recorder.state == .starting else { return }
        recorder.cancel()
        indicatorWindow.setRecording(false)
        updateMenuState()
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
            guard let self, let result else { return }
            appLog.info("selection returned rect \(String(describing: result.rect), privacy: .private) on display \(result.screen.displayID, privacy: .private)")
            do {
                let selectedRect = try self.recorder.setSelection(
                    rect: result.rect,
                    on: result.screen,
                    excludedWindowID: self.indicatorWindow.windowID
                )
                self.indicatorWindow.show(rect: selectedRect, recording: false)
            } catch {
                self.showMessage("Error: \(error.localizedDescription)")
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
        showMessage("Frame rate set to \(sender.tag) fps")
    }

    @objc private func openOutputFolder() {
        NSWorkspace.shared.open(recorder.outputDirectory)
    }

    @objc private func openSettings() {
        showSettings(initialSetup: !settings.hasCompletedInitialSetup)
    }

    @objc private func openPermissionSetup() {
        showSettings(initialSetup: false)
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

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func ensureScreenRecordingAccess(onGranted: (() -> Void)? = nil) -> Bool {
        guard !CGPreflightScreenCaptureAccess() else { return true }
        showSettings(initialSetup: false, onPermissionGranted: onGranted)
        return false
    }

    /// Stands in for the system notifications the app used to post. Messages land on the start item
    /// so they are visible the next time the menu is opened, and the tooltip carries live state.
    private func showMessage(_ text: String) {
        startItem.title = text
    }

    private func updateStatusIcon(_ state: StatusIconState) {
        guard let button = statusItem.button else { return }
        switch state {
        case .idle, .recording:
            processingIndicator?.stopAnimation(nil)
            processingIndicator?.removeFromSuperview()
            processingIndicator = nil
            button.image = StatusIcon.image(for: state)
            button.toolTip = state == .recording ? "Recording" : "GIFt"
        case .processing:
            button.image = nil
            button.toolTip = "Processing GIF…"
            let indicator = processingIndicator ?? makeProcessingIndicator(in: button)
            processingIndicator = indicator
            indicator.startAnimation(nil)
        }
    }

    private func makeProcessingIndicator(in button: NSStatusBarButton) -> NSProgressIndicator {
        let indicator = StatusIcon.makeProcessingIndicator()
        button.addSubview(indicator)
        NSLayoutConstraint.activate([
            indicator.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            indicator.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            indicator.widthAnchor.constraint(equalToConstant: 16),
            indicator.heightAnchor.constraint(equalToConstant: 16)
        ])
        return indicator
    }

    private func applySettings() {
        recorder.outputDirectory = settings.outputDirectory
        recorder.fps = settings.defaultFPS
        indicatorWindow.style = settings.indicatorStyle
        fpsItems.forEach { $0.state = ($0.tag == settings.defaultFPS) ? .on : .off }
        updateMenuState()
    }
}

extension NSScreen {
    /// `kCGNullDirectDisplay` when the screen reports no display number, which makes the lookup in
    /// `Recorder.beginCapture` fail cleanly instead of capturing the wrong display.
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            ?? CGDirectDisplayID(kCGNullDirectDisplay)
    }
}
