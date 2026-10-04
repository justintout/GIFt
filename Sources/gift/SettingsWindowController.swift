import AppKit
import GiftCore
import ServiceManagement

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let titleLabel = NSTextField(labelWithString: "")
    private let introLabel = NSTextField(wrappingLabelWithString: "")
    private var permissionRows: [PermissionRow] = []
    private let stack = NSStackView()
    private let pathField = NSTextField()
    private let autoStartCheckbox = NSButton(checkboxWithTitle: "Start recording immediately after selecting an area or window", target: nil, action: nil)
    private let bringWindowToFrontCheckbox = NSButton(checkboxWithTitle: "Bring the selected window to the front before recording", target: nil, action: nil)
    private let reviewCheckbox = NSButton(checkboxWithTitle: "Review each recording before saving it", target: nil, action: nil)
    private let highlightClicksCheckbox = NSButton(checkboxWithTitle: "Highlight mouse clicks", target: nil, action: nil)
    private let launchAtLoginCheckbox = NSButton(checkboxWithTitle: "Open GIFt at login", target: nil, action: nil)
    private let fpsPopup = NSPopUpButton()
    private let formatPopup = NSPopUpButton()
    private let shortcutRecorder = ShortcutRecorderView()
    private let indicatorColorWell = NSColorWell()
    private let opacitySlider = NSSlider()
    private let opacityValueLabel = NSTextField(labelWithString: "")
    private let borderWidthSlider = NSSlider()
    private let borderWidthValueLabel = NSTextField(labelWithString: "")
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private var settings: Settings
    private let onSave: (Settings) -> Void
    private var isInitialSetup = false
    private var onPermissionGranted: (() -> Void)?
    private var relaunchWatcher: Process?

    init(settings: Settings, onSave: @escaping (Settings) -> Void) {
        self.settings = settings
        self.onSave = onSave
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 500),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        window.title = "GIFt Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        setupUI()
        apply(settings: settings)
        updatePermissionRows()
    }

    required init?(coder: NSCoder) {
        nil
    }

    /// One row in the permissions list. The views live together so a single refresh can update all
    /// three from one place.
    @MainActor
    private final class PermissionRow {
        let permission: Permission
        let statusLabel = NSTextField(labelWithString: "")
        let detailLabel = NSTextField(wrappingLabelWithString: "")
        let grantButton = NSButton(title: "Grant…", target: nil, action: nil)
        let settingsButton = NSButton(title: "System Settings", target: nil, action: nil)

        init(permission: Permission) {
            self.permission = permission
            detailLabel.stringValue = permission.explanation
            detailLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            detailLabel.textColor = .secondaryLabelColor
            detailLabel.maximumNumberOfLines = 0
            detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
    }

    func show(settings: Settings, initialSetup: Bool, onPermissionGranted: (() -> Void)? = nil) {
        self.settings = settings
        self.isInitialSetup = initialSetup
        self.onPermissionGranted = onPermissionGranted
        apply(settings: settings)
        updatePermissionRows()
        updateMode()
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [weak self] in
            self?.refreshPermissionStatus()
        }
    }

    func refreshPermissionStatus() {
        updatePermissionRows()
        // A pending recording is waiting on Screen Recording specifically; the optional two can
        // arrive at any time without anything else changing.
        if Permission.screenRecording.isGranted, onPermissionGranted != nil {
            finishPermissionGranted()
        }
    }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }
        contentView.wantsLayer = true

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        titleLabel.font = .boldSystemFont(ofSize: 18)
        stack.addArrangedSubview(titleLabel)

        introLabel.maximumNumberOfLines = 0
        introLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(introLabel)

        addSectionHeader("Permissions")

        // Every permission the app can use is listed with what it buys, so nobody has to guess why
        // GIFt wants to watch keystrokes or reach into another application's windows.
        for (index, permission) in Permission.allCases.enumerated() {
            let row = PermissionRow(permission: permission)
            row.grantButton.target = self
            row.grantButton.action = #selector(grantPermission(_:))
            row.grantButton.tag = index
            row.settingsButton.target = self
            row.settingsButton.action = #selector(openPermissionSettings(_:))
            row.settingsButton.tag = index
            permissionRows.append(row)
            stack.addArrangedSubview(makePermissionRow(row))
        }

        addSectionHeader("Recording")

        let pathRow = NSStackView()
        pathRow.orientation = .horizontal
        pathRow.alignment = .firstBaseline
        pathRow.spacing = 8

        pathRow.addArrangedSubview(NSTextField(labelWithString: "Output folder:"))

        pathField.placeholderString = "Choose a folder…"
        pathField.isEditable = false
        pathField.isBezeled = true
        pathField.bezelStyle = .roundedBezel
        pathField.lineBreakMode = .byTruncatingHead
        pathField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pathRow.addArrangedSubview(pathField)

        let browseButton = NSButton(title: "Choose…", target: self, action: #selector(browse))
        pathRow.addArrangedSubview(browseButton)
        stack.addArrangedSubview(pathRow)

        stack.addArrangedSubview(autoStartCheckbox)
        stack.addArrangedSubview(bringWindowToFrontCheckbox)
        stack.addArrangedSubview(reviewCheckbox)
        stack.addArrangedSubview(highlightClicksCheckbox)
        stack.addArrangedSubview(launchAtLoginCheckbox)

        let fpsRow = NSStackView()
        fpsRow.orientation = .horizontal
        fpsRow.alignment = .centerY
        fpsRow.spacing = 8
        fpsRow.addArrangedSubview(NSTextField(labelWithString: "Default frame rate:"))
        fpsPopup.addItems(withTitles: Settings.allowedFrameRates.map(String.init))
        fpsPopup.autoenablesItems = false
        fpsRow.addArrangedSubview(fpsPopup)
        fpsRow.addArrangedSubview(NSTextField(labelWithString: "Save as:"))
        formatPopup.addItems(withTitles: ExportFormat.allCases.map(\.displayName))
        fpsRow.addArrangedSubview(formatPopup)
        fpsRow.setCustomSpacing(16, after: fpsPopup)
        stack.addArrangedSubview(fpsRow)

        let shortcutRow = NSStackView()
        shortcutRow.orientation = .horizontal
        shortcutRow.alignment = .centerY
        shortcutRow.spacing = 8
        shortcutRow.addArrangedSubview(NSTextField(labelWithString: "Stop and save:"))

        shortcutRecorder.onCapture = { [weak self] shortcut in
            self?.settings.stopShortcut = shortcut
        }
        shortcutRow.addArrangedSubview(shortcutRecorder)

        let resetShortcutButton = NSButton(title: "Default", target: self, action: #selector(resetShortcut))
        shortcutRow.addArrangedSubview(resetShortcutButton)
        stack.addArrangedSubview(shortcutRow)

        let shortcutNote = NSTextField(wrappingLabelWithString: "Works from any app and needs no permission. Escape still cancels a recording and discards it.")
        shortcutNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        shortcutNote.textColor = .secondaryLabelColor
        shortcutNote.maximumNumberOfLines = 0
        shortcutNote.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(shortcutNote)

        addSectionHeader("Selection overlay")

        let colorRow = NSStackView()
        colorRow.orientation = .horizontal
        colorRow.alignment = .centerY
        colorRow.spacing = 8
        colorRow.addArrangedSubview(NSTextField(labelWithString: "Color:"))
        colorRow.addArrangedSubview(indicatorColorWell)
        stack.addArrangedSubview(colorRow)

        stack.addArrangedSubview(sliderRow(
            label: "Fill opacity:",
            slider: opacitySlider,
            valueLabel: opacityValueLabel,
            range: IndicatorStyle.fillOpacityRange,
            action: #selector(updateIndicatorLabels)
        ))

        stack.addArrangedSubview(sliderRow(
            label: "Border width:",
            slider: borderWidthSlider,
            valueLabel: borderWidthValueLabel,
            range: IndicatorStyle.borderWidthRange,
            action: #selector(updateIndicatorLabels)
        ))

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 8

        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.keyEquivalent = "\r"

        buttonRow.addView(cancelButton, in: .trailing)
        buttonRow.addView(saveButton, in: .trailing)
        stack.setCustomSpacing(20, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(buttonRow)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            // Pinned on all sides, so the window takes its height from the content and shrinks
            // when granted permissions hide their buttons.
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
            stack.widthAnchor.constraint(equalToConstant: 528),
            buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            borderWidthSlider.leadingAnchor.constraint(equalTo: opacitySlider.leadingAnchor),
            introLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            shortcutNote.widthAnchor.constraint(equalTo: stack.widthAnchor),
            pathField.widthAnchor.constraint(greaterThanOrEqualToConstant: 300),
            opacitySlider.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
            borderWidthSlider.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
            opacityValueLabel.widthAnchor.constraint(equalToConstant: 48),
            borderWidthValueLabel.widthAnchor.constraint(equalToConstant: 48)
        ])

        // The explanations wrap, so each needs the full width rather than its intrinsic one.
        NSLayoutConstraint.activate(permissionRows.map { $0.detailLabel.widthAnchor.constraint(equalTo: stack.widthAnchor) })

        updateMode()
    }

    private func addSectionHeader(_ title: String) {
        if let previous = stack.arrangedSubviews.last {
            stack.setCustomSpacing(24, after: previous)
        }
        let label = NSTextField(labelWithString: title)
        label.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        stack.addArrangedSubview(label)
        stack.setCustomSpacing(8, after: label)
    }

    /// One permission: its name, whether it is granted, what it buys, and how to get it.
    private func makePermissionRow(_ row: PermissionRow) -> NSStackView {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 2

        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .firstBaseline
        header.spacing = 6

        let name = NSTextField(labelWithString: row.permission.title)
        name.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        header.addArrangedSubview(name)

        row.statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        header.addArrangedSubview(row.statusLabel)
        container.addArrangedSubview(header)

        container.addArrangedSubview(row.detailLabel)

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.addArrangedSubview(row.grantButton)
        buttons.addArrangedSubview(row.settingsButton)
        container.addArrangedSubview(buttons)

        return container
    }

    private func sliderRow(label: String, slider: NSSlider, valueLabel: NSTextField, range: ClosedRange<CGFloat>, action: Selector) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.addArrangedSubview(NSTextField(labelWithString: label))
        slider.minValue = Double(range.lowerBound)
        slider.maxValue = Double(range.upperBound)
        slider.target = self
        slider.action = action
        slider.numberOfTickMarks = 0
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(slider)
        valueLabel.alignment = .right
        valueLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        row.addArrangedSubview(valueLabel)
        return row
    }

    private func updateMode() {
        window?.title = isInitialSetup ? "GIFt Setup" : "GIFt Settings"
        titleLabel.stringValue = isInitialSetup ? "Finish setting up GIFt" : "GIFt Settings"
        introLabel.stringValue = isInitialSetup
            ? "Choose where GIFt saves recordings, then grant Screen Recording access when you are ready."
            : "Manage recording permissions, output, and selection overlay settings."
        cancelButton.title = isInitialSetup ? "Later" : "Cancel"
        saveButton.title = isInitialSetup ? "Save and Continue" : "Save"
    }

    private func apply(settings: Settings) {
        pathField.stringValue = settings.outputDirectory.path
        autoStartCheckbox.state = settings.autoStartAfterSelection ? .on : .off
        bringWindowToFrontCheckbox.state = settings.bringWindowToFront ? .on : .off
        reviewCheckbox.state = settings.reviewBeforeSaving ? .on : .off
        highlightClicksCheckbox.state = settings.highlightClicks ? .on : .off
        // Read from the system rather than stored, because the user can also change it in
        // System Settings > General > Login Items.
        launchAtLoginCheckbox.state = SMAppService.mainApp.status == .enabled ? .on : .off
        if let index = fpsPopup.itemTitles.firstIndex(of: "\(settings.defaultFPS)") {
            fpsPopup.selectItem(at: index)
        }
        shortcutRecorder.shortcut = settings.stopShortcut
        formatPopup.selectItem(at: ExportFormat.allCases.firstIndex(of: settings.exportFormat) ?? 0)
        indicatorColorWell.color = settings.indicatorStyle.color
        opacitySlider.doubleValue = Double(settings.indicatorStyle.fillOpacity)
        borderWidthSlider.doubleValue = Double(settings.indicatorStyle.borderWidth)
        updateIndicatorLabels()
    }

    private func updatePermissionRows() {
        for row in permissionRows {
            let granted = row.permission.isGranted
            row.statusLabel.stringValue = granted ? "granted" : "not granted"
            row.statusLabel.textColor = granted ? .systemGreen : .secondaryLabelColor
            row.grantButton.isHidden = granted
            row.settingsButton.isHidden = granted
        }
    }

    @objc private func grantPermission(_ sender: NSButton) {
        let permission = permissionRows[sender.tag].permission
        guard permission == .screenRecording else {
            // macOS has no inline prompt for these two; requesting sends the user to System Settings.
            permission.request()
            updatePermissionRows()
            return
        }
        requestScreenRecording()
    }

    /// Screen Recording is the only one macOS grants inline, and the capture stack needs the app
    /// restarted afterwards to pick it up.
    private func requestScreenRecording() {
        updateSettingsFromControls()
        onSave(settings)

        if Permission.screenRecording.isGranted {
            finishPermissionGranted()
            return
        }

        let relaunchScheduled = startRelaunchWatcher()
        if Permission.screenRecording.request() {
            if relaunchScheduled {
                screenRecordingRow?.statusLabel.stringValue = "Restarting GIFt…"
                NSApp.terminate(nil)
            } else {
                finishPermissionGranted()
            }
        } else {
            cancelRelaunchWatcher()
            if isInitialSetup {
                settings.hasCompletedInitialSetup = false
                onSave(settings)
            }
            updatePermissionRows()
        }
    }

    private var screenRecordingRow: PermissionRow? {
        permissionRows.first { $0.permission == .screenRecording }
    }

    @objc private func openPermissionSettings(_ sender: NSButton) {
        let permission = permissionRows[sender.tag].permission
        if !NSWorkspace.shared.open(permission.settingsURL) {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
        }
    }

    @objc private func browse() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = settings.outputDirectory
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.settings.outputDirectory = url
            self?.pathField.stringValue = url.path
        }
    }

    @objc private func save() {
        updateSettingsFromControls()
        onSave(settings)
        onPermissionGranted = nil
        window?.performClose(nil)
        applyLaunchAtLogin()
    }

    private func applyLaunchAtLogin() {
        let wanted = launchAtLoginCheckbox.state == .on
        let service = SMAppService.mainApp
        guard wanted != (service.status == .enabled) else { return }

        do {
            if wanted {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            settingsLog.error("could not change launch at login: \(String(describing: error), privacy: .public)")
            NSAlert(error: error).runModal()
            return
        }
        // Registered, but the user has switched GIFt off in Login Items before; only they can
        // switch it back on.
        if wanted, service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    private func updateSettingsFromControls() {
        settings.autoStartAfterSelection = (autoStartCheckbox.state == .on)
        settings.stopShortcut = shortcutRecorder.shortcut
        settings.bringWindowToFront = (bringWindowToFrontCheckbox.state == .on)
        settings.reviewBeforeSaving = (reviewCheckbox.state == .on)
        settings.highlightClicks = (highlightClicksCheckbox.state == .on)
        if let title = fpsPopup.selectedItem?.title, let fps = Int(title) {
            settings.defaultFPS = fps
        }
        settings.exportFormat = ExportFormat.allCases[formatPopup.indexOfSelectedItem]
        settings.indicatorStyle = IndicatorStyle(
            color: indicatorColorWell.color,
            fillOpacity: CGFloat(opacitySlider.doubleValue),
            borderWidth: CGFloat(borderWidthSlider.doubleValue.rounded())
        )
        if isInitialSetup {
            settings.hasCompletedInitialSetup = true
        }
    }

    @objc private func resetShortcut() {
        shortcutRecorder.shortcut = .default
        settings.stopShortcut = .default
    }

    @objc private func updateIndicatorLabels() {
        opacityValueLabel.stringValue = "\(Int((opacitySlider.doubleValue * 100).rounded()))%"
        borderWidthValueLabel.stringValue = "\(Int(borderWidthSlider.doubleValue.rounded())) pt"
    }

    @objc private func cancel() {
        apply(settings: settings)
        onPermissionGranted = nil
        window?.performClose(nil)
    }

    private func finishPermissionGranted() {
        updatePermissionRows()
        let callback = onPermissionGranted
        onPermissionGranted = nil
        if callback != nil {
            window?.performClose(nil)
        }
        callback?()
    }

    func windowWillClose(_ notification: Notification) {
        onPermissionGranted = nil
    }

    private func startRelaunchWatcher() -> Bool {
        guard relaunchWatcher == nil,
              Bundle.main.bundleURL.pathExtension == "app" else { return false }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "i=0; while [ $i -lt 300 ]; do if ! kill -0 \"$GIFT_PARENT_PID\" 2>/dev/null; then open -n \"$GIFT_BUNDLE_PATH\"; exit 0; fi; i=$((i + 1)); sleep 0.2; done"
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["GIFT_PARENT_PID"] = "\(ProcessInfo.processInfo.processIdentifier)"
        environment["GIFT_BUNDLE_PATH"] = Bundle.main.bundleURL.path
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            relaunchWatcher = process
            return true
        } catch {
            settingsLog.error("failed to start relaunch watcher: \(String(describing: error), privacy: .private)")
            return false
        }
    }

    private func cancelRelaunchWatcher() {
        relaunchWatcher?.terminate()
        relaunchWatcher = nil
    }
}
