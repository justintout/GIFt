import AppKit

/// Pause and stop buttons placed beside the recording outline. GIFt's windows are left out of
/// every capture, so the panel never appears in the GIF.
@MainActor
final class RecordingControlsPanel: NSPanel {
    private static let gap: CGFloat = 8

    private let pauseButton = FirstClickButton(title: "Pause", target: nil, action: nil)
    private let stopButton = FirstClickButton(title: "Stop", target: nil, action: nil)
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

        pauseButton.target = self
        pauseButton.action = #selector(togglePause)
        stopButton.target = self
        stopButton.action = #selector(stop)

        let stack = NSStackView(views: [pauseButton, stopButton])
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // A plain backing so the buttons stay legible over whatever is being recorded.
        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 8
        background.layer?.masksToBounds = true
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor)
        ])
        contentView = background
        setContentSize(stack.fittingSize)
    }

    override var canBecomeKey: Bool { false }

    /// Below the outline when there is room, above it when there is not, and inside its bottom
    /// edge as a last resort.
    func show(beside target: CGRect) {
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
        pauseButton.title = paused ? "Resume" : "Pause"
    }

    func hide() {
        orderOut(nil)
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
