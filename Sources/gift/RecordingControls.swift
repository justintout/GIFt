import AppKit

/// A capsule beside the recording outline with the elapsed time and pause and stop buttons.
/// GIFt's windows are left out of every capture, so the panel never appears in the GIF.
@MainActor
final class RecordingControlsPanel: NSPanel {
    private static let gap: CGFloat = 8

    private let dot = NSView()
    private let timeLabel = NSTextField(labelWithString: "0:00")
    private let pauseButton = FirstClickButton()
    private let stopButton = FirstClickButton()
    private var clock: Timer?
    private var runningSince: Date?
    /// Time recorded before the current run, so pauses do not count.
    private var recordedBefore: TimeInterval = 0
    var onTogglePause: (() -> Void)?
    var onStop: (() -> Void)?

    init() {
        // Non-activating, so clicking a button leaves the recorded app in front.
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .statusBar
        hidesOnDeactivate = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5
        timeLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)

        for (button, action) in [(pauseButton, #selector(togglePause)), (stopButton, #selector(stop))] {
            button.bezelStyle = .circular
            button.controlSize = .small
            button.imagePosition = .imageOnly
            button.target = self
            button.action = action
        }
        // A palette color rather than a tint, which the circular bezel draws over.
        stopButton.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: "Stop")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.systemRed]))

        let stack = NSStackView(views: [dot, timeLabel, pauseButton, stopButton])
        stack.spacing = 6
        stack.setCustomSpacing(10, after: timeLabel)
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 12, bottom: 4, right: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // A blurred backing so the panel stays legible over whatever is being recorded.
        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.state = .active
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor)
        ])
        // Wide enough for ten minutes, so the capsule does not grow as the clock runs.
        timeLabel.stringValue = "00:00"
        timeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: timeLabel.intrinsicContentSize.width).isActive = true
        contentView = background
        setPaused(false)
        setContentSize(stack.fittingSize)
        // A visual effect view ignores its layer's corner radius; a mask is how it takes a shape.
        background.maskImage = Self.capsuleMask(height: stack.fittingSize.height)
        invalidateShadow()
    }

    private static func capsuleMask(height: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: height, height: height), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
        let radius = height / 2
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    override var canBecomeKey: Bool { false }

    /// Below the outline when there is room, above it when there is not, and inside its bottom
    /// edge as a last resort. Starts the clock from zero.
    func show(beside target: CGRect) {
        recordedBefore = 0
        runningSince = Date()
        clock?.invalidate()
        clock = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateTime() }
        }
        setPaused(false)

        let size = frame.size
        var origin = CGPoint(x: target.midX - size.width / 2, y: target.minY - Self.gap - size.height)
        if let visible = NSScreen.screens.first(where: { $0.frame.intersects(target) })?.visibleFrame {
            if origin.y < visible.minY {
                origin.y = target.maxY + Self.gap
            }
            if origin.y + size.height > visible.maxY {
                origin.y = target.minY + Self.gap
            }
            origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        }
        setFrameOrigin(origin)
        orderFrontRegardless()
    }

    func setPaused(_ paused: Bool) {
        if paused, let runningSince {
            recordedBefore += Date().timeIntervalSince(runningSince)
            self.runningSince = nil
        } else if !paused, runningSince == nil, clock != nil {
            runningSince = Date()
        }
        pauseButton.image = NSImage(systemSymbolName: paused ? "play.fill" : "pause.fill", accessibilityDescription: paused ? "Resume" : "Pause")
        dot.layer?.backgroundColor = (paused ? NSColor.secondaryLabelColor : NSColor.systemRed).cgColor
        updateTime()
    }

    func hide() {
        clock?.invalidate()
        clock = nil
        runningSince = nil
        orderOut(nil)
    }

    private func updateTime() {
        let elapsed = Int(recordedBefore + (runningSince.map { Date().timeIntervalSince($0) } ?? 0))
        timeLabel.stringValue = String(format: "%d:%02d", elapsed / 60, elapsed % 60)
    }

    @objc private func togglePause() {
        onTogglePause?()
    }

    @objc private func stop() {
        onStop?()
    }
}

/// The panel never becomes key, so without this the first click would only focus it.
private final class FirstClickButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
