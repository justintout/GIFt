import AppKit
import GiftCore
import ServiceManagement

/// Settings in panes: a sidebar of sections, each a scrolling column of grouped rows, and a footer
/// with the update status. Every control applies as soon as it changes.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    /// Applies one change to the app's current settings, then saves and re-applies them. A change
    /// rather than a whole copy, so a value changed elsewhere (the menu's frame rate) is never
    /// overwritten by a stale one held here.
    typealias Change = ((inout Settings) -> Void) -> Void

    private struct Pane {
        let title: String
        let symbol: String
        let view: NSView
    }

    private let setupTitle = NSTextField(labelWithString: "Finish setting up GIFt")
    private let setupIntro = NSTextField(wrappingLabelWithString: "Grant Screen Recording so GIFt can capture the screen. The output folder and everything else are in the other sections, and changes apply as you make them.")
    private var permissionRows: [PermissionRow] = []
    private var panes: [Pane] = []
    private let sidebar = NSTableView()
    private let paneHolder = NSView()
    private let pathField = NSTextField()
    private let autoStartSwitch = NSSwitch()
    private let bringWindowToFrontSwitch = NSSwitch()
    private let reviewSwitch = NSSwitch()
    private let highlightClicksSwitch = NSSwitch()
    private let launchAtLoginSwitch = NSSwitch()
    private let agentSwitch = NSSwitch()
    private let commandStatus = NSTextField(labelWithString: "")
    private let installCommandButton = NSButton(title: "Install…", target: nil, action: nil)
    private let fpsPopup = NSPopUpButton()
    private let formatPopup = NSPopUpButton()
    private let shortcutRecorder = ShortcutRecorderView()
    private let indicatorColorWell = NSColorWell()
    private let opacitySlider = NSSlider()
    private let opacityValueLabel = NSTextField(labelWithString: "")
    private let borderWidthSlider = NSSlider()
    private let borderWidthValueLabel = NSTextField(labelWithString: "")
    private let footerStack = NSStackView()
    private let laterButton = NSButton(title: "Later", target: nil, action: nil)
    private let doneButton = NSButton(title: "Done", target: nil, action: nil)
    private let updateRow = NSStackView()
    private let updateLabel = NSTextField(labelWithString: "")
    private let updateButton = NSButton(title: "", target: nil, action: nil)
    private let updateChecker: UpdateChecker
    private var settings: Settings
    private let change: Change
    private var isInitialSetup = false
    private var onPermissionGranted: (() -> Void)?
    private var relaunchWatcher: Process?

    init(settings: Settings, updateChecker: UpdateChecker, change: @escaping Change) {
        self.settings = settings
        self.updateChecker = updateChecker
        self.change = change
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "GIFt Settings"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        setupUI()
        apply(settings: settings)
        updatePermissionRows()
        updateChecker.onChange = { [weak self] in self?.updateUpdateStatus() }
        updateUpdateStatus()
    }

    required init?(coder: NSCoder) {
        nil
    }

    /// One row in the permissions list. The views live together so a single refresh can update all
    /// of them from one place.
    @MainActor
    private final class PermissionRow {
        let permission: Permission
        let statusIcon = NSImageView()
        let statusLabel = NSTextField(labelWithString: "")
        let actions = NSStackView()
        let grantButton = NSButton(title: "Grant…", target: nil, action: nil)
        let settingsButton = NSButton(title: "System Settings", target: nil, action: nil)

        init(permission: Permission) {
            self.permission = permission
        }
    }

    func show(settings: Settings, initialSetup: Bool, onPermissionGranted: (() -> Void)? = nil) {
        self.settings = settings
        self.isInitialSetup = initialSetup
        self.onPermissionGranted = onPermissionGranted
        apply(settings: settings)
        updatePermissionRows()
        updateMode()
        // Setup, and a recording waiting on Screen Recording, both start where the grant is.
        if initialSetup || onPermissionGranted != nil {
            select(paneTitled: "Permissions")
        }
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

    private static let size = NSSize(width: 700, height: 500)
    private static let sidebarWidth: CGFloat = 180
    private static let inset: CGFloat = 20

    private func setupUI() {
        guard let window else { return }

        pathField.isEditable = false
        pathField.isBezeled = true
        pathField.bezelStyle = .roundedBezel
        pathField.lineBreakMode = .byTruncatingHead
        let browseButton = NSButton(title: "Choose…", target: self, action: #selector(browse))
        fpsPopup.addItems(withTitles: Settings.allowedFrameRates.map { "\($0) fps" })
        formatPopup.addItems(withTitles: ExportFormat.allCases.map(\.displayName))
        for control in [autoStartSwitch, bringWindowToFrontSwitch, reviewSwitch, highlightClicksSwitch, launchAtLoginSwitch, agentSwitch] as [NSControl] {
            control.controlSize = .small
        }
        for control in [autoStartSwitch, bringWindowToFrontSwitch, reviewSwitch, highlightClicksSwitch, agentSwitch, fpsPopup, formatPopup, indicatorColorWell, opacitySlider, borderWidthSlider] as [NSControl] {
            control.target = self
            control.action = #selector(controlChanged(_:))
        }
        launchAtLoginSwitch.target = self
        launchAtLoginSwitch.action = #selector(applyLaunchAtLogin)
        shortcutRecorder.onCapture = { [weak self] shortcut in
            self?.change { $0.stopShortcut = shortcut }
        }
        let resetShortcutButton = NSButton(image: NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: "Reset to Default")!, target: self, action: #selector(resetShortcut))
        resetShortcutButton.isBordered = false
        resetShortcutButton.toolTip = "Reset to ⌘⎋"

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
        installCommandButton.target = self
        installCommandButton.action = #selector(installCommand)
        commandStatus.textColor = .secondaryLabelColor
        let skillButton = NSButton(title: "Open Guide", target: self, action: #selector(openAgentGuide))
        let mcpButton = NSButton(title: "Open Guide", target: self, action: #selector(openMCPGuide))

        setupTitle.font = .boldSystemFont(ofSize: 15)
        setupIntro.textColor = .secondaryLabelColor

        panes = [
            Pane(title: "General", symbol: "gearshape", view: paneView([
                section("Output", [
                    row("Folder", controls: pathField, browseButton),
                    row("Save as", info: "The format GIFt saves in when review is off.", controls: formatPopup),
                    row("Review before saving", info: "Opens the review window to trim and size a recording before anything is written.", controls: reviewSwitch)
                ]),
                section("Behavior", [
                    row("Start recording after selecting", info: "Starts recording as soon as you pick an area or window, instead of waiting for Start Recording.", controls: autoStartSwitch),
                    row("Bring window to front", info: "Raises the window you pick above everything else before recording starts.", controls: bringWindowToFrontSwitch),
                    row("Open at login", controls: launchAtLoginSwitch)
                ])
            ])),
            Pane(title: "Recording", symbol: "record.circle", view: paneView([
                section("Recording", [
                    row("Frame rate", info: "Higher rates look smoother and make larger files. The menu's Frame Rate changes it too.", controls: fpsPopup),
                    row("Highlight clicks", info: "Draws a ring wherever you click.", controls: highlightClicksSwitch)
                ]),
                section("Shortcut", [
                    row("Stop and save", info: "Works from any app and needs no permission. Escape still cancels a recording and discards it.", controls: shortcutRecorder, resetShortcutButton)
                ])
            ])),
            Pane(title: "Overlay", symbol: "rectangle.dashed", view: paneView([
                section("Selection outline", [
                    row("Color", controls: indicatorColorWell),
                    sliderRow("Fill opacity", slider: opacitySlider, valueLabel: opacityValueLabel, range: IndicatorStyle.fillOpacityRange),
                    sliderRow("Border width", slider: borderWidthSlider, valueLabel: borderWidthValueLabel, range: IndicatorStyle.borderWidthRange)
                ])
            ])),
            Pane(title: "Agents", symbol: "sparkles", view: paneView([
                section("Agents", [
                    row("Allow agents", info: "Lets coding agents and AI apps take screenshots and record through GIFt, using the gift command or MCP. While this is on, any app running as you can do the same.", controls: agentSwitch)
                ]),
                section("Setup", [
                    row("gift command", info: "Links \(AgentSetup.commandPath) to GIFt, so agents with a shell can run gift. macOS asks for your password.", controls: commandStatus, installCommandButton),
                    row("Agent skill", info: "Teaches an agent the screenshot, grid, and record workflow. The guide shows how to add it to your agent.", controls: skillButton),
                    row("Claude Desktop and ChatGPT", info: "AI apps without a shell connect to GIFt over MCP.", controls: mcpButton)
                ])
            ])),
            Pane(title: "Permissions", symbol: "lock.shield", view: paneView([
                setupTitle, setupIntro,
                // Every permission the app can use is listed with what it buys, so nobody has to
                // guess why GIFt wants to watch keystrokes or reach into another app's windows.
                section("Permissions", permissionRows.map(makePermissionRow))
            ]))
        ]

        sidebar.style = .sourceList
        sidebar.headerView = nil
        sidebar.rowHeight = 28
        sidebar.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("pane")))
        sidebar.dataSource = self
        sidebar.delegate = self
        let sidebarScroll = NSScrollView()
        sidebarScroll.documentView = sidebar
        sidebarScroll.drawsBackground = false
        sidebarScroll.automaticallyAdjustsContentInsets = false
        let wordmark = NSStackView(views: [NSImageView(image: NSApp.applicationIconImage), NSTextField(labelWithString: "GIFt")])
        (wordmark.views[1] as? NSTextField)?.font = .boldSystemFont(ofSize: 17)
        wordmark.spacing = 6
        let sidebarView = NSView()
        for view in [wordmark, sidebarScroll] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            sidebarView.addSubview(view)
        }

        let split = NSSplitViewController()
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: Self.controller(sidebarView))
        sidebarItem.canCollapse = false
        sidebarItem.minimumThickness = Self.sidebarWidth
        sidebarItem.maximumThickness = Self.sidebarWidth
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(NSSplitViewItem(viewController: Self.controller(paneHolder)))

        // The footer runs the full width under both columns, like the review window's control bar.
        let footer = NSVisualEffectView()
        footer.material = .windowBackground
        let separator = NSBox()
        separator.boxType = .separator
        updateLabel.textColor = .secondaryLabelColor
        updateButton.isBordered = false
        updateButton.contentTintColor = .linkColor
        updateButton.target = self
        updateButton.action = #selector(updateAction)
        updateRow.setViews([updateLabel, updateButton], in: .leading)
        updateRow.spacing = 6
        laterButton.target = self
        laterButton.action = #selector(later)
        doneButton.target = self
        doneButton.action = #selector(done)
        doneButton.keyEquivalent = "\r"
        footerStack.spacing = 8
        for view in [separator, footerStack] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            footer.addSubview(view)
        }

        let root = NSView()
        let rootController = Self.controller(root)
        rootController.addChild(split)
        for view in [split.view, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }

        // Never taller than the screen; the panes scroll when the window is shorter than they are.
        let visibleHeight = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame.height
        let height = min(Self.size.height, visibleHeight)
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: Self.size.width),
            root.heightAnchor.constraint(equalToConstant: height),
            split.view.topAnchor.constraint(equalTo: root.topAnchor),
            split.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.topAnchor.constraint(equalTo: split.view.bottomAnchor),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            separator.topAnchor.constraint(equalTo: footer.topAnchor),
            separator.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            footerStack.topAnchor.constraint(equalTo: footer.topAnchor, constant: 8),
            footerStack.bottomAnchor.constraint(equalTo: footer.bottomAnchor, constant: -8),
            footerStack.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 16),
            footerStack.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -16),
            footerStack.heightAnchor.constraint(greaterThanOrEqualToConstant: 22),

            wordmark.topAnchor.constraint(equalTo: sidebarView.safeAreaLayoutGuide.topAnchor, constant: 4),
            wordmark.leadingAnchor.constraint(equalTo: sidebarView.leadingAnchor, constant: 18),
            wordmark.views[0].widthAnchor.constraint(equalToConstant: 28),
            wordmark.views[0].heightAnchor.constraint(equalToConstant: 28),
            sidebarScroll.topAnchor.constraint(equalTo: wordmark.bottomAnchor, constant: 14),
            sidebarScroll.leadingAnchor.constraint(equalTo: sidebarView.leadingAnchor),
            sidebarScroll.trailingAnchor.constraint(equalTo: sidebarView.trailingAnchor),
            sidebarScroll.bottomAnchor.constraint(equalTo: sidebarView.bottomAnchor),

            pathField.widthAnchor.constraint(equalToConstant: 200),
            opacitySlider.widthAnchor.constraint(equalToConstant: 160),
            borderWidthSlider.widthAnchor.constraint(equalToConstant: 160),
            opacityValueLabel.widthAnchor.constraint(equalToConstant: 40),
            borderWidthValueLabel.widthAnchor.constraint(equalToConstant: 40)
        ])
        window.contentViewController = rootController
        select(paneTitled: "General")
        updateMode()
    }

    private static func controller(_ view: NSView) -> NSViewController {
        let controller = NSViewController()
        controller.view = view
        return controller
    }

    // MARK: Sidebar

    func numberOfRows(in tableView: NSTableView) -> Int {
        panes.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let label = NSTextField(labelWithString: panes[row].title)
        let icon = NSImageView(image: NSImage(systemSymbolName: panes[row].symbol, accessibilityDescription: nil)!)
        let cell = NSTableCellView()
        cell.textField = label
        cell.imageView = icon
        let stack = NSStackView(views: [icon, label])
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18)
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard panes.indices.contains(sidebar.selectedRow) else { return }
        let view = panes[sidebar.selectedRow].view
        paneHolder.subviews.forEach { $0.removeFromSuperview() }
        view.translatesAutoresizingMaskIntoConstraints = false
        paneHolder.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: paneHolder.topAnchor),
            view.bottomAnchor.constraint(equalTo: paneHolder.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: paneHolder.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: paneHolder.trailingAnchor)
        ])
    }

    private func select(paneTitled title: String) {
        guard let index = panes.firstIndex(where: { $0.title == title }) else { return }
        sidebar.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
    }

    // MARK: Pane building

    /// A scrolling column, so a pane taller than the window stays reachable.
    private func paneView(_ views: [NSView]) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 20
        stack.edgeInsets = NSEdgeInsets(top: 12, left: Self.inset, bottom: Self.inset, right: Self.inset)
        stack.translatesAutoresizingMaskIntoConstraints = false
        views.forEach { $0.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * Self.inset).isActive = true }

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = document
        NSLayoutConstraint.activate([
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor)
        ])
        return scroll
    }

    /// A small uppercase heading over a rounded group of rows split by separators.
    private func section(_ title: String, _ rows: [NSView]) -> NSView {
        let heading = NSTextField(labelWithString: title.uppercased())
        heading.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        heading.textColor = .secondaryLabelColor

        let column = NSStackView()
        column.orientation = .vertical
        column.spacing = 6
        column.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        for (index, row) in rows.enumerated() {
            if index > 0 {
                let separator = NSBox()
                separator.boxType = .separator
                column.addArrangedSubview(separator)
                separator.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -24).isActive = true
            }
            column.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -24).isActive = true
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

        let stack = NSStackView(views: [heading, group])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setHuggingPriority(.defaultHigh, for: .vertical)
        group.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    /// A label, an optional ⓘ whose tooltip explains the setting, and controls on the trailing edge.
    private func row(_ title: String, info: String? = nil, controls: NSView...) -> NSStackView {
        let row = NSStackView()
        row.spacing = 8
        row.addView(NSTextField(labelWithString: title), in: .leading)
        if let info {
            row.addView(infoIcon(info), in: .leading)
            row.setCustomSpacing(4, after: row.views[0])
        }
        controls.forEach { row.addView($0, in: .trailing) }
        // Rows with a switch, a popup, or plain text all get the same height.
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 24).isActive = true
        return row
    }

    private func infoIcon(_ text: String) -> NSImageView {
        let icon = NSImageView(image: NSImage(systemSymbolName: "info.circle", accessibilityDescription: text)!)
        icon.contentTintColor = .tertiaryLabelColor
        icon.toolTip = text
        return icon
    }

    private func sliderRow(_ label: String, slider: NSSlider, valueLabel: NSTextField, range: ClosedRange<CGFloat>) -> NSStackView {
        slider.minValue = Double(range.lowerBound)
        slider.maxValue = Double(range.upperBound)
        valueLabel.alignment = .right
        valueLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        valueLabel.textColor = .secondaryLabelColor
        return row(label, controls: slider, valueLabel)
    }

    /// Status icon, name, and ⓘ on the leading edge; "Granted" or the ways to grant it on the trailing.
    private func makePermissionRow(_ row: PermissionRow) -> NSView {
        let line = self.row(row.permission.title, info: row.permission.explanation, controls: row.statusLabel, row.actions)
        line.insertView(row.statusIcon, at: 0, in: .leading)
        line.setCustomSpacing(6, after: row.statusIcon)
        row.statusLabel.textColor = .secondaryLabelColor
        row.actions.spacing = 6
        row.actions.setHuggingPriority(.defaultHigh, for: .horizontal)
        for button in [row.grantButton, row.settingsButton] {
            button.controlSize = .small
            button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            row.actions.addArrangedSubview(button)
        }
        return line
    }

    // MARK: State

    private func updateUpdateStatus() {
        let version = updateChecker.currentVersion?.description ?? "unknown version"
        let text: String
        let action: String?
        switch updateChecker.state {
        case .idle:
            text = "GIFt \(version)"
            action = "Check for Updates"
        case .checking:
            text = "Checking for updates…"
            action = nil
        case .upToDate:
            text = "Up to date  ·  \(version)"
            action = nil
        case .available(let release):
            text = "GIFt \(release.version) is available"
            action = "Download"
        case .failed(let reason):
            text = reason
            action = "Try Again"
        }
        updateLabel.stringValue = text
        updateButton.title = action ?? ""
        updateButton.isHidden = action == nil
    }

    @objc private func updateAction() {
        if case .available(let release) = updateChecker.state {
            NSWorkspace.shared.open(release.pageURL)
        } else {
            updateChecker.check()
        }
    }

    /// Setup mode heads the Permissions pane with what to do, and its footer offers a way to finish;
    /// otherwise the footer holds only the update status, at the trailing edge.
    private func updateMode() {
        window?.title = isInitialSetup ? "GIFt Setup" : "GIFt Settings"
        setupTitle.isHidden = !isInitialSetup
        setupIntro.isHidden = !isInitialSetup
        // Both areas are emptied first: setting one area's views does not reliably take a view
        // out of the other, and a stale entry there removes it again.
        footerStack.setViews([], in: .leading)
        footerStack.setViews([], in: .trailing)
        footerStack.setViews(isInitialSetup ? [updateRow] : [], in: .leading)
        footerStack.setViews(isInitialSetup ? [laterButton, doneButton] : [updateRow], in: .trailing)
    }

    private func apply(settings: Settings) {
        pathField.stringValue = settings.outputDirectory.path
        autoStartSwitch.state = settings.autoStartAfterSelection ? .on : .off
        bringWindowToFrontSwitch.state = settings.bringWindowToFront ? .on : .off
        reviewSwitch.state = settings.reviewBeforeSaving ? .on : .off
        highlightClicksSwitch.state = settings.highlightClicks ? .on : .off
        agentSwitch.state = settings.agentControlEnabled ? .on : .off
        updateCommandStatus()
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

    @objc private func controlChanged(_ sender: NSControl) {
        let on = (sender as? NSSwitch)?.state == .on
        switch sender {
        case autoStartSwitch: change { $0.autoStartAfterSelection = on }
        case bringWindowToFrontSwitch: change { $0.bringWindowToFront = on }
        case reviewSwitch: change { $0.reviewBeforeSaving = on }
        case highlightClicksSwitch: change { $0.highlightClicks = on }
        case agentSwitch: change { $0.agentControlEnabled = on }
        case fpsPopup:
            let fps = Settings.allowedFrameRates[fpsPopup.indexOfSelectedItem]
            change { $0.defaultFPS = fps }
        case formatPopup:
            let format = ExportFormat.allCases[formatPopup.indexOfSelectedItem]
            change { $0.exportFormat = format }
        default:
            updateIndicatorLabels()
            let style = IndicatorStyle(
                color: indicatorColorWell.color,
                fillOpacity: CGFloat(opacitySlider.doubleValue),
                borderWidth: CGFloat(borderWidthSlider.doubleValue.rounded())
            )
            change { $0.indicatorStyle = style }
        }
    }

    private func updatePermissionRows() {
        for row in permissionRows {
            let granted = row.permission.isGranted
            row.statusLabel.stringValue = granted ? "Granted" : "Not granted"
            row.statusLabel.isHidden = !granted
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
        if Permission.screenRecording.isGranted {
            finishPermissionGranted()
            return
        }

        // Granting finishes setup, so the relaunched app does not open in setup mode again.
        if isInitialSetup {
            change { $0.hasCompletedInitialSetup = true }
        }
        let relaunchScheduled = startRelaunchWatcher()
        if Permission.screenRecording.request() {
            if relaunchScheduled {
                screenRecordingRow?.statusLabel.stringValue = "Restarting GIFt…"
                screenRecordingRow?.statusLabel.isHidden = false
                screenRecordingRow?.actions.isHidden = true
                NSApp.terminate(nil)
            } else {
                finishPermissionGranted()
            }
        } else {
            cancelRelaunchWatcher()
            if isInitialSetup {
                change { $0.hasCompletedInitialSetup = false }
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

    private func updateCommandStatus() {
        let installed = AgentSetup.isCommandInstalled
        commandStatus.stringValue = installed ? "Installed" : "Not installed"
        installCommandButton.title = installed ? "Reinstall…" : "Install…"
    }

    @objc private func installCommand() {
        do {
            try AgentSetup.installCommand()
        } catch {
            commandStatus.stringValue = error.localizedDescription
            return
        }
        updateCommandStatus()
    }

    @objc private func openAgentGuide() {
        NSWorkspace.shared.open(AgentSetup.guideURL)
    }

    @objc private func openMCPGuide() {
        NSWorkspace.shared.open(AgentSetup.mcpGuideURL)
    }

    @objc private func browse() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = settings.outputDirectory
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.settings.outputDirectory = url
            self.pathField.stringValue = url.path
            self.change { $0.outputDirectory = url }
        }
    }

    /// Finishes setup. Everything else was already applied as it changed.
    @objc private func done() {
        change { $0.hasCompletedInitialSetup = true }
        isInitialSetup = false
        window?.performClose(nil)
    }

    /// Leaves setup unfinished, so the next time Settings opens it is in setup mode again.
    @objc private func later() {
        window?.performClose(nil)
    }

    @objc private func applyLaunchAtLogin() {
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
            launchAtLoginSwitch.state = service.status == .enabled ? .on : .off
            return
        }
        // Registered, but the user has switched GIFt off in Login Items before; only they can
        // switch it back on.
        if wanted, service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    @objc private func resetShortcut() {
        shortcutRecorder.shortcut = .default
        change { $0.stopShortcut = .default }
    }

    private func updateIndicatorLabels() {
        opacityValueLabel.stringValue = "\(Int((opacitySlider.doubleValue * 100).rounded()))%"
        borderWidthValueLabel.stringValue = "\(Int(borderWidthSlider.doubleValue.rounded())) pt"
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

/// Lays a scroll view's content out from the top, as a list reads.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
