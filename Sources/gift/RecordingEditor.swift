import AppKit
import CoreMedia
import GiftCore

/// Shown after a recording stops, before anything is written: trim either end and pick an output
/// size and format. The frames are still in memory, so trimming never re-encodes anything.
@MainActor
final class RecordingEditorController: NSWindowController {
    private static let scales: [Double] = [1, 0.75, 0.5, 0.25]
    private static let maximumPreviewSize = NSSize(width: 720, height: 450)

    private let recording: Recording
    private let onFinish: (RecordingEditorController, (edit: FrameEdit, format: ExportFormat)?) -> Void
    private let imageView = NSImageView()
    private let trimSlider: TrimSlider
    private let rangeLabel = NSTextField(labelWithString: "")
    private let scalePopup = NSPopUpButton()
    private let formatPopup = NSPopUpButton()
    private let sizeLabel = NSTextField(labelWithString: "")
    private var estimateTask: Task<Void, Never>?

    /// - Parameter onFinish: Called once, with what to save or `nil` when the user discards.
    init(recording: Recording, format: ExportFormat, onFinish: @escaping (RecordingEditorController, (edit: FrameEdit, format: ExportFormat)?) -> Void) {
        precondition(!recording.frames.isEmpty, "the recorder never hands over an empty recording")
        self.recording = recording
        self.onFinish = onFinish
        trimSlider = TrimSlider(count: recording.frames.count)
        // No close button: closing would have to mean either save or discard, and guessing wrong
        // loses a recording.
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Review Recording"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        setupUI()
        formatPopup.selectItem(at: ExportFormat.allCases.firstIndex(of: format) ?? 0)
        show(frame: 0)
        updateRangeLabel()
        refreshEstimate()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func show() {
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private var edit: FrameEdit {
        FrameEdit(range: trimSlider.range, scale: Self.scales[scalePopup.indexOfSelectedItem])
    }

    private var format: ExportFormat {
        ExportFormat.allCases[formatPopup.indexOfSelectedItem]
    }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }
        let first = recording.frames[0].image

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        let previewSize = Self.previewSize(width: first.width, height: first.height)

        trimSlider.onChange = { [weak self] index in
            self?.show(frame: index)
            self?.updateRangeLabel()
            self?.refreshEstimate()
        }

        for scale in Self.scales {
            let size = FrameEdit(range: 0...0, scale: scale).outputSize(width: first.width, height: first.height)
            scalePopup.addItem(withTitle: "\(Int(scale * 100))%  (\(size.width) × \(size.height))")
        }
        scalePopup.target = self
        scalePopup.action = #selector(outputChanged)

        formatPopup.addItems(withTitles: ExportFormat.allCases.map(\.displayName))
        formatPopup.target = self
        formatPopup.action = #selector(outputChanged)

        let sizeRow = NSStackView(views: [
            NSTextField(labelWithString: "Format:"), formatPopup,
            NSTextField(labelWithString: "Size:"), scalePopup, sizeLabel
        ])
        sizeRow.spacing = 8
        sizeRow.setCustomSpacing(16, after: formatPopup)

        let discardButton = NSButton(title: "Discard", target: self, action: #selector(discard))
        discardButton.keyEquivalent = "\u{1b}"
        let saveButton = NSButton(title: "Save", target: self, action: #selector(save))
        saveButton.keyEquivalent = "\r"
        let buttonRow = NSStackView(views: [discardButton, saveButton])
        buttonRow.spacing = 8

        let stack = NSStackView(views: [imageView, trimSlider, rangeLabel, sizeRow, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(4, after: trimSlider)
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
            imageView.widthAnchor.constraint(equalToConstant: previewSize.width),
            imageView.heightAnchor.constraint(equalToConstant: previewSize.height),
            trimSlider.widthAnchor.constraint(equalTo: imageView.widthAnchor),
            // Room for the widest size label, so the window does not jump as estimates arrive.
            sizeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 100)
        ])
    }

    private static func previewSize(width: Int, height: Int) -> NSSize {
        // Never narrower than the controls beneath it, and never larger than the recording.
        let factor = min(1, maximumPreviewSize.width / CGFloat(width), maximumPreviewSize.height / CGFloat(height))
        return NSSize(width: max(CGFloat(width) * factor, 360), height: CGFloat(height) * factor)
    }

    private func show(frame index: Int) {
        imageView.image = NSImage(cgImage: recording.frames[index].image, size: .zero)
    }

    private func updateRangeLabel() {
        let range = trimSlider.range
        rangeLabel.stringValue = String(
            format: "%.2f s – %.2f s  ·  %d of %d frames",
            seconds(at: range.lowerBound),
            seconds(at: range.upperBound),
            range.count,
            recording.frames.count
        )
    }

    private func seconds(at index: Int) -> Double {
        CMTimeGetSeconds(recording.frames[index].timestamp - recording.frames[0].timestamp)
    }

    /// Debounced, because dragging a handle changes the range many times a second and each
    /// estimate encodes several frames.
    private func refreshEstimate() {
        estimateTask?.cancel()
        sizeLabel.stringValue = "Estimating…"
        let edit = self.edit
        let format = self.format
        let frames = recording.frames
        let fps = recording.fps

        estimateTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let bytes = await Task.detached(priority: .utility) {
                try? await edit.estimatedByteCount(of: frames, fps: fps, format: format)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.sizeLabel.stringValue = bytes.map {
                "about \(ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file))"
            } ?? "size unknown"
        }
    }

    @objc private func outputChanged() {
        refreshEstimate()
    }

    @objc private func save() {
        finish(with: (edit, format))
    }

    @objc private func discard() {
        finish(with: nil)
    }

    private func finish(with choice: (edit: FrameEdit, format: ExportFormat)?) {
        estimateTask?.cancel()
        window?.close()
        onFinish(self, choice)
    }
}

/// A track with two handles that pick the first and last frame to keep.
@MainActor
final class TrimSlider: NSView {
    private enum Handle { case lower, upper }

    private static let handleWidth: CGFloat = 8

    private let count: Int
    private(set) var range: ClosedRange<Int>
    /// Called while a handle moves, with the frame under that handle.
    var onChange: ((Int) -> Void)?
    private var dragging: Handle?

    init(count: Int) {
        self.count = count
        range = 0...max(count - 1, 0)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 24)
    }

    override func draw(_ dirtyRect: NSRect) {
        let track = trackRect
        let groove = NSRect(x: track.minX, y: bounds.midY - 2, width: track.width, height: 4)
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: groove, xRadius: 2, yRadius: 2).fill()

        let lowerX = x(for: range.lowerBound)
        let upperX = x(for: range.upperBound)
        NSColor.controlAccentColor.setFill()
        NSRect(x: lowerX, y: groove.minY, width: upperX - lowerX, height: groove.height).fill()

        NSColor.labelColor.setFill()
        for handleX in [lowerX, upperX] {
            let handle = NSRect(x: handleX - Self.handleWidth / 2, y: bounds.minY + 2, width: Self.handleWidth, height: bounds.height - 4)
            NSBezierPath(roundedRect: handle, xRadius: 2, yRadius: 2).fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let pointX = convert(event.locationInWindow, from: nil).x
        // Whichever handle is closer moves, so a click anywhere on the track does something.
        let lowerDistance = abs(pointX - x(for: range.lowerBound))
        let upperDistance = abs(pointX - x(for: range.upperBound))
        if lowerDistance == upperDistance {
            dragging = pointX < x(for: range.lowerBound) ? .lower : .upper
        } else {
            dragging = lowerDistance < upperDistance ? .lower : .upper
        }
        move(to: pointX)
    }

    override func mouseDragged(with event: NSEvent) {
        move(to: convert(event.locationInWindow, from: nil).x)
    }

    override func mouseUp(with event: NSEvent) {
        dragging = nil
    }

    private func move(to pointX: CGFloat) {
        guard let dragging else { return }
        let index = self.index(for: pointX)
        let moved: Int
        switch dragging {
        case .lower:
            moved = min(index, range.upperBound)
            range = moved...range.upperBound
        case .upper:
            moved = max(index, range.lowerBound)
            range = range.lowerBound...moved
        }
        needsDisplay = true
        onChange?(moved)
    }

    private var trackRect: NSRect {
        bounds.insetBy(dx: Self.handleWidth / 2, dy: 0)
    }

    private func x(for index: Int) -> CGFloat {
        guard count > 1 else { return trackRect.minX }
        return trackRect.minX + trackRect.width * CGFloat(index) / CGFloat(count - 1)
    }

    private func index(for pointX: CGFloat) -> Int {
        guard count > 1, trackRect.width > 0 else { return 0 }
        let fraction = (pointX - trackRect.minX) / trackRect.width
        return min(max(Int((fraction * CGFloat(count - 1)).rounded()), 0), count - 1)
    }
}
