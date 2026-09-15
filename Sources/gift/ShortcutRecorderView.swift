import AppKit

/// Click to arm, then press a combination. Reports it through `onCapture`.
final class ShortcutRecorderView: NSView {
    var onCapture: ((KeyboardShortcut) -> Void)?

    var shortcut: KeyboardShortcut = .default {
        didSet { needsDisplay = true }
    }

    private var isArmed = false {
        didSet { needsDisplay = true }
    }

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 150, height: 24) }

    override func mouseDown(with event: NSEvent) {
        isArmed = true
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        guard isArmed else {
            super.keyDown(with: event)
            return
        }

        // Escape backs out of recording a shortcut rather than being recorded as one.
        if event.keyCode == escapeKeyCode {
            stopArming()
            return
        }

        let captured = KeyboardShortcut(event: event)
        // A bare key would be claimed system-wide, which is almost never what someone means.
        guard captured.isValid else {
            NSSound.beep()
            return
        }

        shortcut = captured
        onCapture?(captured)
        stopArming()
    }

    override func resignFirstResponder() -> Bool {
        isArmed = false
        return super.resignFirstResponder()
    }

    private func stopArming() {
        isArmed = false
        window?.makeFirstResponder(nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        let frame = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: frame, xRadius: 5, yRadius: 5)

        (isArmed ? NSColor.controlAccentColor.withAlphaComponent(0.15) : NSColor.controlBackgroundColor).setFill()
        path.fill()
        (isArmed ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = 1
        path.stroke()

        let text = isArmed ? "Press keys…" : shortcut.displayString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: isArmed ? NSColor.secondaryLabelColor : NSColor.labelColor
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2),
            withAttributes: attributes
        )
    }
}
