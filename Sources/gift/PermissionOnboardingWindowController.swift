import AppKit

@MainActor
final class PermissionOnboardingWindowController: NSWindowController {
    private let statusLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let requestButton = NSButton(title: "Grant Access", target: nil, action: nil)
    private let settingsButton = NSButton(title: "System Settings", target: nil, action: nil)
    private let checkButton = NSButton(title: "Check Again", target: nil, action: nil)
    private let doneButton = NSButton(title: "Done", target: nil, action: nil)
    private var onPermissionGranted: (() -> Void)?

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 260),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        window.title = "GIFt Setup"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        setupUI()
        refresh()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func show(onPermissionGranted: (() -> Void)? = nil) {
        self.onPermissionGranted = onPermissionGranted
        refresh()
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        let titleLabel = NSTextField(labelWithString: "Finish setting up GIFt")
        titleLabel.font = .boldSystemFont(ofSize: 18)
        stack.addArrangedSubview(titleLabel)

        detailLabel.maximumNumberOfLines = 0
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(detailLabel)

        statusLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        stack.addArrangedSubview(statusLabel)

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 8

        requestButton.target = self
        requestButton.action = #selector(requestAccess)
        settingsButton.target = self
        settingsButton.action = #selector(openScreenRecordingSettings)
        checkButton.target = self
        checkButton.action = #selector(checkAgain)
        doneButton.target = self
        doneButton.action = #selector(done)

        buttonRow.addArrangedSubview(requestButton)
        buttonRow.addArrangedSubview(settingsButton)
        buttonRow.addArrangedSubview(checkButton)
        buttonRow.addArrangedSubview(doneButton)
        stack.addArrangedSubview(buttonRow)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -18)
        ])
    }

    private func refresh() {
        let hasAccess = CGPreflightScreenCaptureAccess()
        detailLabel.stringValue = "GIFt needs Screen Recording access before it can capture selected areas and save GIFs. Grant access now so recording works when you press Start. If macOS sends you to System Settings, allow GIFt there and then check again."
        statusLabel.stringValue = hasAccess ? "Screen Recording access is enabled." : "Screen Recording access is not enabled yet."
        requestButton.isHidden = hasAccess
        settingsButton.isHidden = hasAccess
        checkButton.isHidden = hasAccess
        doneButton.isHidden = !hasAccess
        doneButton.keyEquivalent = hasAccess ? "\r" : ""
        requestButton.keyEquivalent = hasAccess ? "" : "\r"
    }

    @objc private func requestAccess() {
        if CGRequestScreenCaptureAccess() {
            finishGranted()
        } else {
            refresh()
        }
    }

    @objc private func openScreenRecordingSettings() {
        let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        if !NSWorkspace.shared.open(settingsURL) {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
        }
    }

    @objc private func checkAgain() {
        if CGPreflightScreenCaptureAccess() {
            finishGranted()
        } else {
            refresh()
        }
    }

    @objc private func done() {
        finishGranted()
    }

    private func finishGranted() {
        refresh()
        window?.performClose(nil)
        let callback = onPermissionGranted
        onPermissionGranted = nil
        callback?()
    }
}
