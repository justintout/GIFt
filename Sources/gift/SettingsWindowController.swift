import AppKit

final class SettingsWindowController: NSWindowController {
    private let pathField = NSTextField()
    private let autoStartCheckbox = NSButton(checkboxWithTitle: "Start recording immediately after selecting an area", target: nil, action: nil)
    private let fpsPopup = NSPopUpButton()
    private let indicatorColorWell = NSColorWell()
    private let opacitySlider = NSSlider()
    private let opacityValueLabel = NSTextField(labelWithString: "")
    private let borderWidthSlider = NSSlider()
    private let borderWidthValueLabel = NSTextField(labelWithString: "")
    private var settings: Settings
    private let onSave: (Settings) -> Void

    init(settings: Settings, onSave: @escaping (Settings) -> Void) {
        self.settings = settings
        self.onSave = onSave
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 320),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        window.title = "GIFt Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        setupUI()
        apply(settings: settings)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }
        contentView.wantsLayer = true
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        let pathRow = NSStackView()
        pathRow.orientation = .horizontal
        pathRow.alignment = .firstBaseline
        pathRow.spacing = 8

        let pathLabel = NSTextField(labelWithString: "Output folder:")
        pathRow.addArrangedSubview(pathLabel)

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

        let fpsRow = NSStackView()
        fpsRow.orientation = .horizontal
        fpsRow.alignment = .centerY
        fpsRow.spacing = 8
        let fpsLabel = NSTextField(labelWithString: "Default frame rate:")
        fpsRow.addArrangedSubview(fpsLabel)
        fpsPopup.addItems(withTitles: ["10", "15", "24", "30"])
        fpsPopup.autoenablesItems = false
        fpsRow.addArrangedSubview(fpsPopup)
        stack.addArrangedSubview(fpsRow)

        let indicatorLabel = NSTextField(labelWithString: "Selection overlay:")
        indicatorLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        stack.addArrangedSubview(indicatorLabel)

        let colorRow = NSStackView()
        colorRow.orientation = .horizontal
        colorRow.alignment = .centerY
        colorRow.spacing = 8
        colorRow.addArrangedSubview(NSTextField(labelWithString: "Color:"))
        colorRow.addArrangedSubview(indicatorColorWell)
        stack.addArrangedSubview(colorRow)

        let opacityRow = sliderRow(
            label: "Fill opacity:",
            slider: opacitySlider,
            valueLabel: opacityValueLabel,
            minValue: 0,
            maxValue: 0.4,
            action: #selector(updateIndicatorLabels)
        )
        stack.addArrangedSubview(opacityRow)

        let borderRow = sliderRow(
            label: "Border width:",
            slider: borderWidthSlider,
            valueLabel: borderWidthValueLabel,
            minValue: 1,
            maxValue: 8,
            action: #selector(updateIndicatorLabels)
        )
        stack.addArrangedSubview(borderRow)

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.distribution = .fillProportionally
        buttonRow.spacing = 8

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        let saveButton = NSButton(title: "Save", target: self, action: #selector(save))
        saveButton.keyEquivalent = "\r"
        buttonRow.addArrangedSubview(cancelButton)
        buttonRow.addArrangedSubview(saveButton)
        stack.addArrangedSubview(buttonRow)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
            pathField.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),
            opacityValueLabel.widthAnchor.constraint(equalToConstant: 48),
            borderWidthValueLabel.widthAnchor.constraint(equalToConstant: 48)
        ])
    }

    private func sliderRow(label: String, slider: NSSlider, valueLabel: NSTextField, minValue: Double, maxValue: Double, action: Selector) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.addArrangedSubview(NSTextField(labelWithString: label))
        slider.minValue = minValue
        slider.maxValue = maxValue
        slider.target = self
        slider.action = action
        slider.numberOfTickMarks = 0
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(slider)
        valueLabel.alignment = .right
        row.addArrangedSubview(valueLabel)
        return row
    }

    private func apply(settings: Settings) {
        pathField.stringValue = settings.outputDirectory.path
        autoStartCheckbox.state = settings.autoStartAfterSelection ? .on : .off
        if let index = fpsPopup.itemTitles.firstIndex(of: "\(settings.defaultFPS)") {
            fpsPopup.selectItem(at: index)
        }
        indicatorColorWell.color = settings.indicatorStyle.color
        opacitySlider.doubleValue = Double(settings.indicatorStyle.fillOpacity)
        borderWidthSlider.doubleValue = Double(settings.indicatorStyle.borderWidth)
        updateIndicatorLabels()
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
        settings.autoStartAfterSelection = (autoStartCheckbox.state == .on)
        if let title = fpsPopup.selectedItem?.title, let fps = Int(title) {
            settings.defaultFPS = fps
        }
        settings.indicatorStyle = IndicatorStyle(
            color: indicatorColorWell.color,
            fillOpacity: CGFloat(opacitySlider.doubleValue),
            borderWidth: CGFloat(borderWidthSlider.doubleValue.rounded())
        )
        onSave(settings)
        window?.performClose(nil)
    }

    @objc private func updateIndicatorLabels() {
        opacityValueLabel.stringValue = "\(Int((opacitySlider.doubleValue * 100).rounded()))%"
        borderWidthValueLabel.stringValue = "\(Int(borderWidthSlider.doubleValue.rounded())) pt"
    }

    @objc private func cancel() {
        apply(settings: settings)
        window?.performClose(nil)
    }
}
