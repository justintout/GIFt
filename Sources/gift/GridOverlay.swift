import AppKit
import GiftCore

/// A click-through measurement grid over every display, labeled in global top-left points. It is
/// meant to appear in screenshots, so an agent can read coordinates off an image and pass them
/// back as an area to record. GIFt excludes its own windows from recordings, so the grid never
/// appears in a GIF.
@MainActor
final class GridOverlay {
    private var windows: [NSWindow] = []
    private(set) var spacing: Int?

    var isVisible: Bool { spacing != nil }

    func show(spacing: Int) {
        hide()
        self.spacing = spacing
        windows = NSScreen.screens.map { screen in
            let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.level = .statusBar
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.contentView = GridView(screen: screen, spacing: spacing)
            window.setFrame(screen.frame, display: true)
            window.orderFrontRegardless()
            return window
        }
    }

    func hide() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        spacing = nil
    }
}

private final class GridView: NSView {
    /// The display's frame in global top-left points, the coordinates the labels show.
    private let globalFrame: CGRect
    private let displayID: CGDirectDisplayID
    private let scale: CGFloat
    private let spacing: Int

    init(screen: NSScreen, spacing: Int) {
        globalFrame = screen.globalFrame
        displayID = screen.displayID
        scale = screen.backingScaleFactor
        self.spacing = spacing
        super.init(frame: NSRect(origin: .zero, size: screen.frame.size))
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let xs = ScreenGrid.lines(from: globalFrame.minX, to: globalFrame.maxX, spacing: spacing)
        let ys = ScreenGrid.lines(from: globalFrame.minY, to: globalFrame.maxY, spacing: spacing)

        // A dark line under a light one stays visible on any background.
        for (color, width) in [(NSColor.black.withAlphaComponent(0.45), 3.0), (NSColor.systemPink.withAlphaComponent(0.85), 1.0)] {
            color.setStroke()
            for x in xs {
                stroke(from: CGPoint(x: local(x: x), y: 0), to: CGPoint(x: local(x: x), y: bounds.maxY), width: width, major: ScreenGrid.isMajor(x, spacing: spacing))
            }
            for y in ys {
                stroke(from: CGPoint(x: 0, y: local(y: y)), to: CGPoint(x: bounds.maxX, y: local(y: y)), width: width, major: ScreenGrid.isMajor(y, spacing: spacing))
            }
        }

        for x in xs where ScreenGrid.isLabeled(x, spacing: spacing) {
            for y in ys where ScreenGrid.isLabeled(y, spacing: spacing) {
                drawLabel("\(x),\(y)", at: CGPoint(x: local(x: x) + 3, y: local(y: y) + 3))
            }
        }

        let summary = String(
            format: "display %u  origin %d,%d  size %dx%d pt  scale %gx",
            displayID, Int(globalFrame.minX), Int(globalFrame.minY), Int(globalFrame.width), Int(globalFrame.height), scale
        )
        // Below the menu bar, which covers the top of the main display.
        drawLabel(summary, at: CGPoint(x: bounds.midX - 160, y: 40), size: 13)
    }

    private func local(x: Int) -> CGFloat { CGFloat(x) - globalFrame.minX }
    private func local(y: Int) -> CGFloat { CGFloat(y) - globalFrame.minY }

    private func stroke(from start: CGPoint, to end: CGPoint, width: CGFloat, major: Bool) {
        let path = NSBezierPath()
        path.move(to: start)
        path.line(to: end)
        path.lineWidth = major ? width + 1 : width
        path.stroke()
    }

    private func drawLabel(_ text: String, at origin: CGPoint, size: CGFloat = 10) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let textSize = string.size()
        let background = CGRect(origin: origin, size: textSize).insetBy(dx: -2, dy: -1)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: background, xRadius: 3, yRadius: 3).fill()
        string.draw(at: origin)
    }
}

extension NSScreen {
    /// This screen's frame in global top-left points: the coordinates CoreGraphics window bounds,
    /// `screencapture -R`, and the measurement grid use.
    var globalFrame: CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
    }
}
