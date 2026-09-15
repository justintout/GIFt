import AppKit

enum StatusIconState {
    case idle
    case recording
    case processing
}

enum StatusIcon {
    private static let size = NSSize(width: 18, height: 18)

    /// Drawn with the drawing-handler initializer so the ring resolves `labelColor` against the
    /// menu bar's current appearance. A hardcoded white ring disappears against a light menu bar.
    /// The image stays non-template so the recording dot keeps its red.
    static func image(for state: StatusIconState) -> NSImage {
        NSImage(size: size, flipped: false) { _ in
            let outerRect = NSRect(x: 2, y: 2, width: size.width - 4, height: size.height - 4)
            let outerPath = NSBezierPath(ovalIn: outerRect)
            NSColor.labelColor.setStroke()
            outerPath.lineWidth = 2
            outerPath.stroke()

            let innerSize: CGFloat = 8
            let innerRect = NSRect(
                x: (size.width - innerSize) / 2,
                y: (size.height - innerSize) / 2,
                width: innerSize,
                height: innerSize
            )
            let innerPath = NSBezierPath(ovalIn: innerRect)
            (state == .recording ? NSColor.systemRed : NSColor.clear).setFill()
            innerPath.fill()
            NSColor.labelColor.setStroke()
            innerPath.lineWidth = 1
            innerPath.stroke()
            return true
        }
    }

    static func makeProcessingIndicator() -> NSProgressIndicator {
        let indicator = NSProgressIndicator()
        indicator.style = .spinning
        indicator.controlSize = .small
        indicator.isIndeterminate = true
        indicator.translatesAutoresizingMaskIntoConstraints = false
        return indicator
    }
}
