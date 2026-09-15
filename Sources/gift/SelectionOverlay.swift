import AppKit

struct SelectionResult {
    let rect: CGRect
    let screen: NSScreen
}

/// One borderless overlay per screen, so each window's backing scale and coordinates match its display.
@MainActor
final class SelectionOverlay: NSWindow {
    var selectionView: SelectionView
    private var completion: (SelectionResult?) -> Void
    private var targetScreen: NSScreen
    private static var activeOverlays: [SelectionOverlay] = []

    // Designated initializer required by NSWindow subclasses.
    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        self.selectionView = SelectionView(frame: contentRect)
        self.completion = { _ in }
        self.targetScreen = NSScreen.main ?? NSScreen.screens[0]
        super.init(contentRect: contentRect, styleMask: styleMask, backing: backingStoreType, defer: flag)
        configure()
    }

    convenience init(screen: NSScreen, completion: @escaping (SelectionResult?) -> Void) {
        self.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        self.targetScreen = screen
        self.completion = completion
        self.selectionView.onComplete = { [weak self] rect in
            guard let self else { return }
            if let rect {
                // Convert window-local rect to global coordinates on the owning screen.
                self.completion(SelectionResult(rect: self.convertToScreen(rect), screen: self.targetScreen))
            } else {
                self.completion(nil)
            }
            self.orderOut(nil)
        }
    }

    required init?(coder: NSCoder) {
        nil
    }

    private func configure() {
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        ignoresMouseEvents = false
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = selectionView
        makeKeyAndOrderFront(nil)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    static func present(completion: @escaping (SelectionResult?) -> Void) {
        // Clean up any overlays still lingering from a previous selection.
        activeOverlays.forEach { $0.orderOut(nil) }
        activeOverlays.removeAll()
        EscTap.shared.disable()

        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            completion(nil)
            return
        }

        var overlays: [SelectionOverlay] = []
        var didComplete = false

        func finish(_ result: SelectionResult?) {
            guard !didComplete else { return }
            didComplete = true
            overlays.forEach { $0.orderOut(nil) }
            overlays.removeAll()
            activeOverlays.removeAll()
            EscTap.shared.disable()
            // If ESC canceled while recording, stop without saving.
            if result == nil {
                NSApp.sendAction(#selector(GiftApp.cancelRecording), to: nil, from: nil)
            }
            completion(result)
        }

        NSApp.activate(ignoringOtherApps: true)

        overlays = screens.map { screen in
            let overlay = SelectionOverlay(screen: screen, completion: finish)
            overlay.setFrame(screen.frame, display: false)
            overlay.selectionView.frame = NSRect(origin: .zero, size: screen.frame.size)
            overlay.isReleasedWhenClosed = false
            overlay.orderFrontRegardless()
            overlay.makeKeyAndOrderFront(nil)
            overlay.makeFirstResponder(overlay.selectionView)
            return overlay
        }
        activeOverlays = overlays
        EscTap.shared.enable { finish(nil) }
    }
}

/// Passive overlay that visualizes the saved selection, and flashes red while recording.
final class SelectionIndicatorWindow: NSWindow {
    private let indicatorView = SelectionIndicatorView()
    private var lastRect: CGRect?

    var style: IndicatorStyle = .default {
        didSet {
            indicatorView.style = style
            indicatorView.needsDisplay = true
        }
    }

    var windowID: CGWindowID { CGWindowID(windowNumber) }

    init() {
        super.init(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        ignoresMouseEvents = true
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = indicatorView
    }

    func show(rect: CGRect, recording: Bool) {
        let frame = rect.integral
        lastRect = frame
        setFrame(frame, display: true)
        indicatorView.frame = NSRect(origin: .zero, size: frame.size)
        indicatorView.isRecording = recording
        orderFrontRegardless()
        indicatorView.needsDisplay = true
    }

    func setRecording(_ recording: Bool) {
        indicatorView.isRecording = recording
        indicatorView.needsDisplay = true
        if recording, let rect = lastRect {
            show(rect: rect, recording: true)
        } else if !recording {
            hide()
        }
    }

    func hide() {
        orderOut(nil)
    }
}

final class SelectionIndicatorView: NSView {
    var isRecording = false
    var style: IndicatorStyle = .default

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill()

        let path = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
        path.lineWidth = style.borderWidth + (isRecording ? 1 : 0)
        let color = style.color
        color.setStroke()
        if style.fillOpacity > 0 {
            color.withAlphaComponent(style.fillOpacity).setFill()
            path.fill()
        }
        path.stroke()
    }
}

@MainActor
final class SelectionView: NSView {
    var onComplete: ((CGRect?) -> Void)?
    private var startPoint: CGPoint?
    private var currentRect: CGRect = .zero

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        startPoint = event.locationInWindow
        currentRect = .zero
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = startPoint else { return }
        let current = event.locationInWindow
        currentRect = CGRect(x: min(start.x, current.x),
                             y: min(start.y, current.y),
                             width: abs(start.x - current.x),
                             height: abs(start.y - current.y))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard startPoint != nil else { return }
        onComplete?(currentRect.isEmpty ? nil : currentRect)
        startPoint = nil
        currentRect = .zero
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == escapeKeyCode {
            onComplete?(nil)
        } else {
            super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.black.withAlphaComponent(0.35).setFill()
        dirtyRect.fill()

        if !currentRect.isEmpty {
            NSColor.clear.setFill()
            currentRect.fill(using: .sourceOut)
            NSColor.systemBlue.setStroke()
            let path = NSBezierPath(rect: currentRect)
            path.lineWidth = 2
            path.stroke()
        }
    }
}
