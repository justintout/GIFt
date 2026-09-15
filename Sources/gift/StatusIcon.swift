import AppKit

enum StatusIconState {
    case idle
    case recording
    case processing
}

enum StatusIcon {
    private static let size = NSSize(width: 18, height: 18)

    /// Draws the ring with `labelColor` so it reads against either menu bar, and keeps the image
    /// non-template so the recording dot stays red. NSImage caches the result of a drawing handler,
    /// so this must be called again when the system appearance changes; `labelColor` is resolved
    /// once, at the moment the image is built.
    static func image(for state: StatusIconState) -> NSImage {
        let image = NSImage(size: size, flipped: false) { _ in
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
        // Explicit: a template image would be tinted by the system and the recording dot would lose its red.
        image.isTemplate = false
        return image
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
