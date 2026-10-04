import AppKit
import CoreMedia
import GiftCore

/// What the user chose in the review window.
struct ReviewDecision {
    enum Action {
        /// Write to the output folder, then copy.
        case save
        /// Copy only; the file is written to a temporary folder for the clipboard to point at.
        case copy
    }

    let action: Action
    let format: ExportFormat
    let edit: FrameEdit
}

/// Shown after a recording stops, before anything is written: trim either end, pick an output
/// size, then save or copy in either format. The frames are still in memory, so trimming never
/// re-encodes anything.
@MainActor
final class RecordingEditorController: NSWindowController {
    private static let scales: [Double] = [1, 0.75, 0.5, 0.25]
    private static let maximumPreviewSize = NSSize(width: 720, height: 450)
    /// In display order. The last is the default button.
    private static let choices: [(title: String, action: ReviewDecision.Action, format: ExportFormat)] = [
        ("Copy as MP4", .copy, .mp4),
        ("Copy as GIF", .copy, .gif),
        ("Save as MP4", .save, .mp4),
        ("Save as GIF", .save, .gif)
    ]

    private let recording: Recording
    private let onFinish: (RecordingEditorController, ReviewDecision?) -> Void
    private let imageView = NSImageView()
    private let trimSlider: TrimSlider
    private let rangeLabel = NSTextField(labelWithString: "")
    private let playButton = NSButton()
    private var playbackTimer: Timer?
    private let scalePopup = NSPopUpButton()
    private let sizeLabel = NSTextField(labelWithString: "")
    private var estimateTask: Task<Void, Never>?

    /// - Parameter onFinish: Called once, with the user's choice or `nil` when they discard.
    init(recording: Recording, onFinish: @escaping (RecordingEditorController, ReviewDecision?) -> Void) {
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

    private func setupUI() {
        guard let contentView = window?.contentView else { return }
        let first = recording.frames[0].image

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        let previewSize = Self.previewSize(width: first.width, height: first.height)

        trimSlider.onTrim = { [weak self] index in
            self?.pause()
            self?.show(frame: index)
            self?.updateRangeLabel()
            self?.refreshEstimate()
        }
        trimSlider.onScrub = { [weak self] index in
            self?.pause()
            self?.show(frame: index)
        }

        playButton.isBordered = false
        playButton.target = self
        playButton.action = #selector(togglePlayback)
        // A key equivalent rather than a key handler, so Space works whatever has focus.
        playButton.keyEquivalent = " "
        setPlayButton(playing: false)
        let rangeRow = NSStackView(views: [playButton, rangeLabel])
        rangeRow.alignment = .centerY
        rangeRow.spacing = 6

        for scale in Self.scales {
            let size = FrameEdit(range: 0...0, scale: scale).outputSize(width: first.width, height: first.height)
            scalePopup.addItem(withTitle: "\(Int(scale * 100))%  (\(size.width) × \(size.height))")
        }
        scalePopup.target = self
        scalePopup.action = #selector(outputChanged)

        for label in [rangeLabel, sizeLabel] {
            label.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            label.textColor = .secondaryLabelColor
        }
        sizeLabel.lineBreakMode = .byTruncatingTail

        let discardButton = NSButton(title: "Discard", target: self, action: #selector(discard))
        discardButton.keyEquivalent = "\u{1b}"
        let choiceButtons = Self.choices.enumerated().map { index, choice in
            let button = NSButton(title: choice.title, target: self, action: #selector(choose(_:)))
            button.tag = index
            return button
        }
        choiceButtons.last?.keyEquivalent = "\r"
        let copies = Array(choiceButtons[..<2])
        let saves = Array(choiceButtons[2...])

        // The preview sets the window's width, and the controls fit inside it. A narrow recording
        // gets the buttons on two lines, and anything narrower than that is letterboxed.
        let oneLineWidth = Self.width(of: [discardButton]) + Self.discardGap + Self.width(of: copies) + Self.pairGap + Self.width(of: saves)
        let twoLineWidth = Self.width(of: [discardButton]) + Self.discardGap + max(Self.width(of: copies), Self.width(of: saves))
        let width = max(previewSize.width, twoLineWidth)

        let buttonRows: [NSStackView]
        if width >= oneLineWidth {
            let row = Self.buttonRow(leading: discardButton, trailing: choiceButtons)
            row.setCustomSpacing(Self.pairGap, after: copies[1])
            buttonRows = [row]
        } else {
            buttonRows = [Self.buttonRow(leading: nil, trailing: copies), Self.buttonRow(leading: discardButton, trailing: saves)]
        }

        let sizeRow = NSStackView(views: [NSTextField(labelWithString: "Size:"), scalePopup])
        sizeRow.alignment = .firstBaseline
        sizeRow.spacing = 8
        // The estimates sit beside the popup when the longest likely pair fits there.
        let widestEstimate = NSTextField(labelWithString: "GIF about 999.9 MB  ·  MP4 about 999.9 MB")
        widestEstimate.font = sizeLabel.font
        let estimatesFitBeside = sizeRow.fittingSize.width + 8 + widestEstimate.fittingSize.width <= width
        if estimatesFitBeside {
            sizeRow.addArrangedSubview(sizeLabel)
        }

        let stack = NSStackView(views: [imageView, trimSlider, rangeRow, sizeRow] + (estimatesFitBeside ? [] : [sizeLabel]) + buttonRows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(4, after: trimSlider)
        stack.setCustomSpacing(4, after: sizeRow)
        stack.setCustomSpacing(20, after: estimatesFitBeside ? sizeRow : sizeLabel)
        stack.setCustomSpacing(8, after: buttonRows[0])
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
            stack.widthAnchor.constraint(equalToConstant: width),
            imageView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            imageView.heightAnchor.constraint(equalToConstant: previewSize.height),
            trimSlider.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ] + buttonRows.map { $0.widthAnchor.constraint(equalTo: stack.widthAnchor) })

        // Arrow keys step the playhead from the moment the window opens.
        window?.initialFirstResponder = trimSlider

        if buttonRows.count > 1 {
            // Matching widths line the two pairs up in columns.
            NSLayoutConstraint.activate(zip(copies, saves).map { $0.widthAnchor.constraint(equalTo: $1.widthAnchor) })
        }
    }

    private static let discardGap: CGFloat = 32
    private static let pairGap: CGFloat = 20

    /// Buttons side by side, 8 points apart.
    private static func width(of buttons: [NSButton]) -> CGFloat {
        buttons.map(\.fittingSize.width).reduce(0, +) + CGFloat(buttons.count - 1) * 8
    }

    /// Discard pinned to the leading edge, the rest to the trailing edge.
    private static func buttonRow(leading: NSButton?, trailing: [NSButton]) -> NSStackView {
        let row = NSStackView()
        row.spacing = 8
        trailing.forEach { row.addView($0, in: .trailing) }
        if let leading {
            row.addView(leading, in: .leading)
            trailing[0].leadingAnchor.constraint(greaterThanOrEqualTo: leading.trailingAnchor, constant: discardGap).isActive = true
        }
        return row
    }

    private static func previewSize(width: Int, height: Int) -> NSSize {
        // Never larger than the recording.
        let factor = min(1, maximumPreviewSize.width / CGFloat(width), maximumPreviewSize.height / CGFloat(height))
        return NSSize(width: CGFloat(width) * factor, height: CGFloat(height) * factor)
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
        let frames = recording.frames
        let fps = recording.fps

        estimateTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let estimates = await Task.detached(priority: .utility) {
                var estimates: [String] = []
                for format in [ExportFormat.gif, .mp4] {
                    let bytes = try? await edit.estimatedByteCount(of: frames, fps: fps, format: format)
                    let size = bytes.map { "about \(ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file))" } ?? "size unknown"
                    estimates.append("\(format.displayName) \(size)")
                }
                return estimates
            }.value
            guard !Task.isCancelled, let self else { return }
            self.sizeLabel.stringValue = estimates.joined(separator: "  ·  ")
        }
    }

    // MARK: Playback

    @objc private func togglePlayback() {
        if playbackTimer == nil { play() } else { pause() }
    }

    private func play() {
        let range = trimSlider.range
        if trimSlider.playhead >= range.upperBound {
            trimSlider.setPlayhead(range.lowerBound)
            show(frame: range.lowerBound)
        }
        setPlayButton(playing: true)
        scheduleNextFrame()
    }

    private func pause() {
        playbackTimer?.invalidate()
        playbackTimer = nil
        setPlayButton(playing: false)
    }

    private func setPlayButton(playing: Bool) {
        let name = playing ? "pause.fill" : "play.fill"
        playButton.image = NSImage(systemSymbolName: name, accessibilityDescription: playing ? "Pause" : "Play")
    }

    /// Loops the kept range. Each frame stays up for its own recorded duration, so playback runs
    /// at the timing the saved file will have.
    private func scheduleNextFrame() {
        playbackTimer = Timer.scheduledTimer(withTimeInterval: frameDuration(at: trimSlider.playhead), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.advance() }
        }
    }

    private func advance() {
        let range = trimSlider.range
        let next = trimSlider.playhead < range.upperBound ? trimSlider.playhead + 1 : range.lowerBound
        trimSlider.setPlayhead(next)
        show(frame: next)
        scheduleNextFrame()
    }

    /// Mirrors GIFWriter: a frame lasts until the next one, and the last kept frame repeats the gap
    /// before it.
    private func frameDuration(at index: Int) -> Double {
        let range = trimSlider.range
        let fallback = 1.0 / Double(max(recording.fps, 1))
        let gap: Double
        if index < range.upperBound {
            gap = seconds(at: index + 1) - seconds(at: index)
        } else if index > range.lowerBound {
            gap = seconds(at: index) - seconds(at: index - 1)
        } else {
            return fallback
        }
        return gap > 0 ? gap : fallback
    }

    @objc private func outputChanged() {
        refreshEstimate()
    }

    @objc private func choose(_ sender: NSButton) {
        let choice = Self.choices[sender.tag]
        finish(with: ReviewDecision(action: choice.action, format: choice.format, edit: edit))
    }

    @objc private func discard() {
        finish(with: nil)
    }

    private func finish(with decision: ReviewDecision?) {
        pause()
        estimateTask?.cancel()
        window?.close()
        onFinish(self, decision)
    }
}

/// A track with two handles that pick the first and last frame to keep, and a playhead inside
/// them that marks the frame on screen. Grabbing a handle trims; clicking anywhere else scrubs.
@MainActor
final class TrimSlider: NSView {
    private enum Drag { case lower, upper, playhead }

    private static let handleWidth: CGFloat = 8
    /// How far beyond a handle's edge a click still grabs it.
    private static let handleSlop: CGFloat = 4

    private let count: Int
    private(set) var range: ClosedRange<Int>
    private(set) var playhead = 0
    /// Called while a handle moves, with the frame under that handle.
    var onTrim: ((Int) -> Void)?
    /// Called when the user scrubs or steps the playhead, with its new frame.
    var onScrub: ((Int) -> Void)?
    private var dragging: Drag?

    init(count: Int) {
        self.count = count
        range = 0...max(count - 1, 0)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        focusRingType = .none
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 24)
    }

    /// Kept inside the trimmed range.
    func setPlayhead(_ index: Int) {
        playhead = min(max(index, range.lowerBound), range.upperBound)
        needsDisplay = true
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
        NSRect(x: x(for: playhead) - 1, y: bounds.minY, width: 2, height: bounds.height).fill()

        for handleX in [lowerX, upperX] {
            let handle = NSRect(x: handleX - Self.handleWidth / 2, y: bounds.minY + 2, width: Self.handleWidth, height: bounds.height - 4)
            NSBezierPath(roundedRect: handle, xRadius: 2, yRadius: 2).fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let pointX = convert(event.locationInWindow, from: nil).x
        let lowerX = x(for: range.lowerBound)
        let upperX = x(for: range.upperBound)
        let reach = Self.handleWidth / 2 + Self.handleSlop
        let nearLower = abs(pointX - lowerX) <= reach
        let nearUpper = abs(pointX - upperX) <= reach

        switch (nearLower, nearUpper) {
        case (true, true):
            // Handles close together: the side of the click decides, so both stay reachable.
            dragging = pointX < (lowerX + upperX) / 2 ? .lower : .upper
        case (true, false):
            dragging = .lower
        case (false, true):
            dragging = .upper
        case (false, false):
            dragging = .playhead
        }
        move(to: pointX)
    }

    override func mouseDragged(with event: NSEvent) {
        move(to: convert(event.locationInWindow, from: nil).x)
    }

    override func mouseUp(with event: NSEvent) {
        dragging = nil
    }

    override func keyDown(with event: NSEvent) {
        let step: Int
        switch event.keyCode {
        case 123: step = -1  // left arrow
        case 124: step = 1   // right arrow
        default:
            super.keyDown(with: event)
            return
        }
        setPlayhead(playhead + step)
        onScrub?(playhead)
    }

    private func move(to pointX: CGFloat) {
        guard let dragging else { return }
        let index = self.index(for: pointX)
        switch dragging {
        case .lower:
            range = min(index, range.upperBound)...range.upperBound
            playhead = range.lowerBound
            onTrim?(playhead)
        case .upper:
            range = range.lowerBound...max(index, range.lowerBound)
            playhead = range.upperBound
            onTrim?(playhead)
        case .playhead:
            setPlayhead(index)
            onScrub?(playhead)
        }
        needsDisplay = true
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
