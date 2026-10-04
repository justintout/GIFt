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
    private let autoStartSwitch = NSSwitch()
    private let bringWindowToFrontSwitch = NSSwitch()
    private let reviewSwitch = NSSwitch()
    private let highlightClicksSwitch = NSSwitch()
    private let launchAtLoginSwitch = NSSwitch()
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
                              styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered,
                              defer: false)
        window.title = "GIFt Settings"
        // Matches the review window: the content runs under a transparent title bar, and the
        // heading in the content takes the title's place.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
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
        let statusIcon = NSImageView()
        let statusLabel = NSTextField(labelWithString: "")
        let actions = NSStackView()
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
        guard let window, let contentView = window.contentView,
              let belowTitleBar = window.contentLayoutGuide as? NSLayoutGuide else { return }

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        titleLabel.font = .boldSystemFont(ofSize: 18)
        stack.addArrangedSubview(titleLabel)

        introLabel.maximumNumberOfLines = 0
        introLabel.textColor = .secondaryLabelColor
        introLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(introLabel)

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
        }
        addSection("Permissions", rows: permissionRows.map(makePermissionRow))

        pathField.placeholderString = "Choose a folder…"
        pathField.isEditable = false
        pathField.isBezeled = true
        pathField.bezelStyle = .roundedBezel
        pathField.lineBreakMode = .byTruncatingHead
        let browseButton = NSButton(title: "Choose…", target: self, action: #selector(browse))

        fpsPopup.addItems(withTitles: Settings.allowedFrameRates.map { "\($0) fps" })
        fpsPopup.autoenablesItems = false
        formatPopup.addItems(withTitles: ExportFormat.allCases.map(\.displayName))

        shortcutRecorder.onCapture = { [weak self] shortcut in
            self?.settings.stopShortcut = shortcut
        }
        let resetShortcutButton = NSButton(title: "Default", target: self, action: #selector(resetShortcut))
        let shortcutControls = row("Stop and save", shortcutRecorder, resetShortcutButton)
        let shortcutRow = NSStackView(views: [
            shortcutControls,
            detail("Works from any app and needs no permission. Escape still cancels a recording and discards it.")
        ])
        shortcutRow.orientation = .vertical
        shortcutRow.alignment = .leading
        shortcutRow.spacing = 2
        shortcutControls.widthAnchor.constraint(equalTo: shortcutRow.widthAnchor).isActive = true
        for control in [autoStartSwitch, bringWindowToFrontSwitch, reviewSwitch, highlightClicksSwitch, launchAtLoginSwitch] {
            control.controlSize = .small
        }

        addSection("Recording", rows: [
            row("Output folder", pathField, browseButton),
            row("Start recording immediately after selecting an area or window", autoStartSwitch),
            row("Bring the selected window to the front before recording", bringWindowToFrontSwitch),
            row("Review each recording before saving it", reviewSwitch),
            row("Highlight mouse clicks", highlightClicksSwitch),
            row("Open GIFt at login", launchAtLoginSwitch),
            row("Default frame rate", fpsPopup),
            row("Save as", formatPopup),
            shortcutRow
        ])

        addSection("Selection overlay", rows: [
            row("Color", indicatorColorWell),
            sliderRow(label: "Fill opacity", slider: opacitySlider, valueLabel: opacityValueLabel, range: IndicatorStyle.fillOpacityRange),
            sliderRow(label: "Border width", slider: borderWidthSlider, valueLabel: borderWidthValueLabel, range: IndicatorStyle.borderWidthRange)
        ])

        // The footer matches the review window's control bar: a material with a separator above.
        let footer = NSVisualEffectView()
        footer.material = .windowBackground
        footer.translatesAutoresizingMaskIntoConstraints = false
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.keyEquivalent = "\r"
        let buttonRow = NSStackView(views: [cancelButton, saveButton])
        buttonRow.spacing = 8
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(separator)
        footer.addSubview(buttonRow)
        contentView.addSubview(footer)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: belowTitleBar.topAnchor, constant: 4),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Self.inset),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Self.inset),
            stack.widthAnchor.constraint(equalToConstant: 528),
            introLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),

            // Pinned top to bottom, so the window takes its height from the content and shrinks
            // when granted permissions hide their buttons.
            footer.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 20),
            footer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            separator.topAnchor.constraint(equalTo: footer.topAnchor),
            separator.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            buttonRow.topAnchor.constraint(equalTo: footer.topAnchor, constant: 12),
            buttonRow.bottomAnchor.constraint(equalTo: footer.bottomAnchor, constant: -12),
            buttonRow.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -Self.inset),

            pathField.widthAnchor.constraint(equalToConstant: 260),
            opacitySlider.widthAnchor.constraint(equalToConstant: 200),
            borderWidthSlider.widthAnchor.constraint(equalToConstant: 200),
            opacityValueLabel.widthAnchor.constraint(equalToConstant: 40),
            borderWidthValueLabel.widthAnchor.constraint(equalToConstant: 40)
        ])

        updateMode()
    }

    private static let inset: CGFloat = 16
    /// Padding inside a section's rounded group.
    private static let groupInset: CGFloat = 12

    /// A bold heading over a rounded group of rows split by separators, as in System Settings.
    private func addSection(_ title: String, rows: [NSView]) {
        if let previous = stack.arrangedSubviews.last {
            stack.setCustomSpacing(20, after: previous)
        }
        let heading = NSTextField(labelWithString: title)
        heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        stack.addArrangedSubview(heading)

        let column = NSStackView()
        column.orientation = .vertical
        column.spacing = 5
        column.edgeInsets = NSEdgeInsets(top: 6, left: Self.groupInset, bottom: 6, right: Self.groupInset)
        for (index, row) in rows.enumerated() {
            if index > 0 {
                let separator = NSBox()
                separator.boxType = .separator
                column.addArrangedSubview(separator)
                separator.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -2 * Self.groupInset).isActive = true
            }
            column.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -2 * Self.groupInset).isActive = true
        }

        let group = NSBox()
        group.boxType = .custom
        group.titlePosition = .noTitle
        group.cornerRadius = 8
        group.borderColor = .separatorColor
        // The second stripe color is a shade lighter than the window in both appearances, which
        // is the lift System Settings gives its groups.
        group.fillColor = NSColor.alternatingContentBackgroundColors[1]
        group.contentViewMargins = .zero
        group.contentView = column
        stack.addArrangedSubview(group)
        group.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    /// A label on the leading edge and its controls on the trailing edge.
    private func row(_ title: String, _ controls: NSView...) -> NSStackView {
        let row = NSStackView()
        row.spacing = 8
        row.addView(NSTextField(labelWithString: title), in: .leading)
        controls.forEach { row.addView($0, in: .trailing) }
        // Rows with a switch, a popup, or plain text all get the same height.
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 24).isActive = true
        return row
    }

    private func detail(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        return label
    }

    /// One permission: whether it is granted, its name, what it buys, and how to get it.
    private func makePermissionRow(_ row: PermissionRow) -> NSView {
        let name = NSTextField(labelWithString: row.permission.title)
        row.statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        row.statusLabel.textColor = .secondaryLabelColor
        let header = NSStackView()
        header.addView(name, in: .leading)
        header.addView(row.statusLabel, in: .trailing)

        row.actions.spacing = 8
        row.actions.addArrangedSubview(row.grantButton)
        row.actions.addArrangedSubview(row.settingsButton)

        let text = NSStackView(views: [header, row.detailLabel, row.actions])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.setCustomSpacing(6, after: row.detailLabel)

        let container = NSStackView(views: [row.statusIcon, text])
        container.alignment = .top
        container.spacing = 8
        NSLayoutConstraint.activate([
            row.statusIcon.widthAnchor.constraint(equalToConstant: 16),
            text.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            header.widthAnchor.constraint(equalTo: text.widthAnchor),
            row.detailLabel.widthAnchor.constraint(equalTo: text.widthAnchor)
        ])
        return container
    }

    private func sliderRow(label: String, slider: NSSlider, valueLabel: NSTextField, range: ClosedRange<CGFloat>) -> NSStackView {
        slider.minValue = Double(range.lowerBound)
        slider.maxValue = Double(range.upperBound)
        slider.target = self
        slider.action = #selector(updateIndicatorLabels)
        slider.numberOfTickMarks = 0
        valueLabel.alignment = .right
        valueLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        valueLabel.textColor = .secondaryLabelColor
        return row(label, slider, valueLabel)
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
        autoStartSwitch.state = settings.autoStartAfterSelection ? .on : .off
        bringWindowToFrontSwitch.state = settings.bringWindowToFront ? .on : .off
        reviewSwitch.state = settings.reviewBeforeSaving ? .on : .off
        highlightClicksSwitch.state = settings.highlightClicks ? .on : .off
        // Read from the system rather than stored, because the user can also change it in
        // System Settings > General > Login Items.
        launchAtLoginSwitch.state = SMAppService.mainApp.status == .enabled ? .on : .off
        if let index = Settings.allowedFrameRates.firstIndex(of: settings.defaultFPS) {
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
            row.statusLabel.stringValue = granted ? "Granted" : "Not granted"
            row.actions.isHidden = granted
            let required = row.permission == .screenRecording
            let symbol = granted ? "checkmark.circle.fill" : required ? "exclamationmark.triangle.fill" : "circle.dashed"
            row.statusIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: row.statusLabel.stringValue)
            row.statusIcon.contentTintColor = granted ? .systemGreen : required ? .systemYellow : .tertiaryLabelColor
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
        let wanted = launchAtLoginSwitch.state == .on
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
        settings.autoStartAfterSelection = (autoStartSwitch.state == .on)
        settings.stopShortcut = shortcutRecorder.shortcut
        settings.bringWindowToFront = (bringWindowToFrontSwitch.state == .on)
        settings.reviewBeforeSaving = (reviewSwitch.state == .on)
        settings.highlightClicks = (highlightClicksSwitch.state == .on)
        settings.defaultFPS = Settings.allowedFrameRates[fpsPopup.indexOfSelectedItem]
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
