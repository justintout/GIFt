import AppKit
import GiftCore

/// Menu bar app for capturing a screen region to a GIF file.
@main
@MainActor
final class GiftApp: NSObject, NSApplicationDelegate {
    private let recorder = Recorder()
    private let previewController = GIFPreviewController()
    private var statusItem: NSStatusItem!
    private var startItem: NSMenuItem!
    private var stopItem: NSMenuItem!
    private var pauseItem: NSMenuItem!
    private var selectAreaItem: NSMenuItem!
    private var selectWindowItem: NSMenuItem!
    private let windowMenu = NSMenu(title: "Select Window")
    private var fpsItems: [NSMenuItem] = []
    private let indicatorWindow = SelectionIndicatorWindow()
    private let controlsPanel = RecordingControlsPanel()
    private var editors: [RecordingEditorController] = []
    private var settings = Settings.load()
    private var settingsController: SettingsWindowController?
    private var processingIndicator: NSProgressIndicator?
    private var appearanceObservation: NSKeyValueObservation?
    private var iconState: StatusIconState = .idle
    private var stopHotkey: GlobalHotkey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // Menu bar only, no Dock icon.
        setupMenuBar()
        controlsPanel.onTogglePause = { [weak self] in self?.togglePause() }
        controlsPanel.onStop = { [weak self] in self?.stopRecording() }
        applySettings()
        // The status icon resolves its colors when it is built, so a light/dark switch needs a rebuild.
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.updateStatusIcon(self.iconState)
            }
        }
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
        // Without this, AppKit's automatic validation re-enables any item whose action this object
        // implements, silently overriding every isEnabled that updateMenuState sets. Measured: with
        // auto-validation on, Stop showed as clickable while idle and Start while recording.
        menu.autoenablesItems = false
        menu.delegate = self

        startItem = NSMenuItem(title: "Start Recording", action: #selector(startRecording), keyEquivalent: "")
        stopItem = NSMenuItem(title: "Stop Recording", action: #selector(stopRecording), keyEquivalent: "")
        pauseItem = NSMenuItem(title: "Pause Recording", action: #selector(togglePause), keyEquivalent: "")
        menu.addItem(startItem)
        menu.addItem(stopItem)
        menu.addItem(pauseItem)
        menu.addItem(.separator())

        selectAreaItem = NSMenuItem(title: "Select Area…", action: #selector(selectArea), keyEquivalent: "")
        menu.addItem(selectAreaItem)

        selectWindowItem = NSMenuItem(title: "Select Window", action: nil, keyEquivalent: "")
        windowMenu.autoenablesItems = false
        selectWindowItem.submenu = windowMenu
        menu.addItem(selectWindowItem)

        menu.addItem(.separator())

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
            startItem.title = recorder.isPaused ? "Paused" : "Recording…"
            startItem.isEnabled = false
            stopItem.isEnabled = true
        case .stopping:
            startItem.title = "Stopping…"
            startItem.isEnabled = false
            stopItem.isEnabled = false
        }
        pauseItem.title = recorder.isPaused ? "Resume Recording" : "Pause Recording"
        pauseItem.isEnabled = recorder.state == .recording
        // The frame rate is frozen for the duration of a recording, and a target can only be
        // replaced while idle.
        fpsItems.forEach { $0.isEnabled = canChangeTarget }
        selectAreaItem.isEnabled = canChangeTarget
        selectWindowItem.isEnabled = canChangeTarget
    }

    /// The recording reads its target and frame rate when it starts, so neither may move underneath
    /// a recording that is already running.
    private var canChangeTarget: Bool { recorder.state == .idle }

    @objc private func startRecording() {
        guard ensureScreenRecordingAccess(onGranted: { [weak self] in self?.startRecording() }) else { return }
        guard recorder.hasTarget else {
            showMessage("Select an area or window to start recording.")
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

        // Enabled before the capture starts, because preparing it can take seconds and this is the
        // only way out until the stream is running.
        EscTap.shared.enable { [weak self] in self?.cancelRecording() }

        recorder.start { [weak self] status in
            guard let self else { return }
            appLog.info("recorder emitted status: \(status, privacy: .public)")
            self.updateMenuState()
            self.updateStatusIcon(.recording)
            self.indicatorWindow.setRecording(true)
            self.controlsPanel.show(beside: self.indicatorWindow.frame)
        } completion: { [weak self] result in
            guard let self else { return }
            self.updateMenuState()
            self.updateStatusIcon(.idle)
            self.indicatorWindow.setRecording(false)
            self.controlsPanel.hide()
            EscTap.shared.disable()

            switch result {
            case .success(let recording):
                if self.settings.reviewBeforeSaving {
                    self.review(recording)
                } else {
                    self.save(recording, edit: .unchanged(frameCount: recording.frames.count))
                }
            case .failure(let error):
                if (error as? Recorder.RecorderError) != .canceled {
                    self.showMessage("Error: \(error.localizedDescription)")
                }
            }
        }
    }

    @objc private func stopRecording() {
        indicatorWindow.hide()
        controlsPanel.hide()
        recorder.stop()
        updateMenuState()
        updateStatusIcon(.processing)
        EscTap.shared.disable()
    }

    @objc func cancelRecording() {
        guard recorder.state == .recording || recorder.state == .starting else { return }
        recorder.cancel()
        indicatorWindow.setRecording(false)
        controlsPanel.hide()
        updateMenuState()
        updateStatusIcon(.idle)
        EscTap.shared.disable()
    }

    @objc private func togglePause() {
        recorder.setPaused(!recorder.isPaused)
        controlsPanel.setPaused(recorder.isPaused)
        updateMenuState()
    }

    private func review(_ recording: Recording) {
        let editor = RecordingEditorController(recording: recording) { [weak self] editor, edit in
            guard let self else { return }
            self.editors.removeAll { $0 === editor }
            if let edit {
                self.save(recording, edit: edit)
            }
        }
        editors.append(editor)
        editor.show()
    }

    private func save(_ recording: Recording, edit: FrameEdit) {
        updateStatusIcon(.processing)
        let outputDirectory = settings.outputDirectory

        Task { [weak self] in
            let result: Result<URL, Error>
            do {
                result = .success(try await RecordingExport.write(recording, edit: edit, to: outputDirectory))
            } catch {
                result = .failure(error)
            }
            guard let self else { return }
            // A new recording may have started while this one was encoding.
            self.updateStatusIcon(self.recorder.state == .idle ? .idle : .recording)

            switch result {
            case .success(let url):
                // The file itself rather than its path, so pasting into a chat or an issue
                // attaches the GIF.
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([url as NSURL])
                self.showMessage("Saved and copied \(url.lastPathComponent)")
                self.previewController.show(url: url)
            case .failure(let error):
                self.showMessage("Error: \(error.localizedDescription)")
            }
        }
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
                let selectedRect = try self.recorder.setSelection(rect: result.rect, on: result.screen)
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

    /// Mirrors the area flow: resolve the picked window, outline it, bring its app forward when the
    /// user has asked for that, and start recording when they have asked for that too.
    @objc private func selectWindow(_ sender: NSMenuItem) {
        guard ensureScreenRecordingAccess(onGranted: { [weak self] in self?.selectWindow(sender) }) else { return }
        guard let candidate = sender.representedObject as? WindowCandidate else { return }

        Task { [weak self] in
            guard let self else { return }
            if self.settings.bringWindowToFront {
                WindowForegrounding.bringToFront(candidate)
            }
            do {
                let frame = try await self.recorder.setWindow(windowID: candidate.windowID)
                appLog.info("window \(candidate.windowID, privacy: .public) chosen as the recording target")
                self.indicatorWindow.show(rect: frame, recording: false)
                if self.settings.autoStartAfterSelection {
                    self.beginRecording()
                }
            } catch {
                self.showMessage("Error: \(error.localizedDescription)")
            }
        }
    }

    /// Rebuilt every time the menu opens, because windows open and close constantly and the window
    /// server's list is the only source that is never stale.
    private func rebuildWindowMenu() {
        windowMenu.removeAllItems()

        let candidates = openWindows()
        guard !candidates.isEmpty else {
            let empty = NSMenuItem(title: "No Windows Available", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            windowMenu.addItem(empty)
            return
        }

        // Frontmost first, the order the window server reports.
        for candidate in candidates {
            let item = NSMenuItem(title: windowTitle(for: candidate), action: #selector(selectWindow(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = candidate
            item.toolTip = candidate.label
            item.isEnabled = canChangeTarget
            windowMenu.addItem(item)
        }
    }

    /// Read from the window server rather than ScreenCaptureKit because the menu has to be built
    /// synchronously as it opens. The chosen window is resolved to an `SCWindow` when it is picked.
    private func openWindows() -> [WindowCandidate] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let listed = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        let ownProcessID = ProcessInfo.processInfo.processIdentifier
        return listed.compactMap { info in
            // Layer 0 is the layer ordinary windows live on, which keeps the menu bar, the Dock,
            // and other system chrome out of the list. GIFt's own windows are left out too: its
            // settings window and indicator outline are not recording targets.
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let windowID = info[kCGWindowNumber as String] as? CGWindowID,
                  let ownerProcessID = info[kCGWindowOwnerPID as String] as? pid_t,
                  ownerProcessID != ownProcessID,
                  let ownerName = info[kCGWindowOwnerName as String] as? String,
                  !ownerName.isEmpty,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds),
                  frame.width >= 1,
                  frame.height >= 1
            else { return nil }

            return WindowCandidate(
                windowID: windowID,
                ownerProcessID: ownerProcessID,
                ownerName: ownerName,
                title: (info[kCGWindowName as String] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                frame: frame
            )
        }
    }

    /// Windows are often untitled and a long title would widen the whole menu, so the owning
    /// application always appears and the title is clipped.
    private func windowTitle(for candidate: WindowCandidate) -> String {
        guard !candidate.title.isEmpty else { return candidate.ownerName }
        return "\(candidate.title.truncated(to: 60)) (\(candidate.ownerName))"
    }

    @objc private func changeFPS(_ sender: NSMenuItem) {
        recorder.fps = sender.tag
        settings.defaultFPS = sender.tag
        Settings.save(settings)
        fpsItems.forEach { $0.state = ($0 == sender) ? .on : .off }
        showMessage("Frame rate set to \(sender.tag) fps")
    }

    @objc private func openOutputFolder() {
        NSWorkspace.shared.open(settings.outputDirectory)
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
        iconState = state
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
        recorder.fps = settings.defaultFPS
        recorder.highlightsClicks = settings.highlightClicks
        indicatorWindow.style = settings.indicatorStyle
        fpsItems.forEach { $0.state = ($0.tag == settings.defaultFPS) ? .on : .off }
        updateMenuState()
        registerStopHotkey()
    }

    /// Held for as long as the app runs rather than only while recording: the user chose the
    /// combination, so reserving it is what they would expect, and pressing it when nothing is
    /// recording simply does nothing.
    private func registerStopHotkey() {
        stopHotkey?.unregister()
        stopHotkey = nil

        let shortcut = settings.stopShortcut
        guard shortcut.isValid else {
            appLog.error("stop shortcut has no modifier; not registering it")
            return
        }

        stopHotkey = GlobalHotkey(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers) { [weak self] in
            self?.stopFromShortcut()
        }

        if stopHotkey == nil {
            appLog.error("could not register \(shortcut.displayString, privacy: .public); another application may already own it")
            showMessage("\(shortcut.displayString) is taken by another app")
        }
    }

    private func stopFromShortcut() {
        // The shortcut stays registered whether or not a recording is in flight, so the guard is
        // what makes it a no-op the rest of the time.
        guard recorder.state == .recording else { return }
        stopRecording()
    }
}

extension GiftApp: NSMenuDelegate {
    /// Refreshed as the menu opens rather than kept in a snapshot: windows appear and disappear
    /// constantly, and the submenu is built from the list before the user can reach it.
    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildWindowMenu()
    }
}

/// One window offered in the Select Window submenu, as the window server described it.
struct WindowCandidate {
    let windowID: CGWindowID
    let ownerProcessID: pid_t
    let ownerName: String
    let title: String
    /// Screen coordinates as the window server reports them, kept so the window can be matched
    /// against the Accessibility API's windows when bringing it to the front.
    let frame: CGRect

    /// The untruncated label, which the menu item carries as its tooltip so a clipped title is
    /// still readable.
    var label: String {
        title.isEmpty ? ownerName : "\(title) (\(ownerName))"
    }
}

private extension String {
    func truncated(to limit: Int) -> String {
        count <= limit ? self : "\(prefix(limit - 1))…"
    }
}

extension NSScreen {
    /// `kCGNullDirectDisplay` when the screen reports no display number, which makes the lookup in
    /// `Recorder.beginCapture` fail cleanly instead of capturing the wrong display.
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            ?? CGDirectDisplayID(kCGNullDirectDisplay)
    }

    /// CoreGraphics window bounds are measured from the top left of the primary display and AppKit
    /// screen coordinates from its bottom left, so a window frame has to be flipped before it can
    /// be placed on screen.
    static func appKitBounds(fromWindowBounds bounds: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(
            x: bounds.minX,
            y: primaryHeight - bounds.maxY,
            width: bounds.width,
            height: bounds.height
        )
    }

    /// The scale of the display a window sits on, for the systems where ScreenCaptureKit does not
    /// report the filter's own scale.
    static func backingScaleFactor(forAppKitBounds bounds: CGRect) -> CGFloat {
        let screen = NSScreen.screens.first { $0.frame.intersects(bounds) } ?? NSScreen.screens.first
        return screen?.backingScaleFactor ?? 1
    }
}
