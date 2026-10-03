import CoreGraphics
import CoreMedia

/// A mouse click inside the recorded area.
public struct Click: Sendable {
    /// Position as a fraction of the frame, measured from its bottom-left corner, so it maps onto
    /// frames of any output size.
    public var location: CGPoint
    public var time: CMTime

    public init(location: CGPoint, time: CMTime) {
        self.location = location
        self.time = time
    }
}

public enum ClickHighlighter {
    /// How long a click stays visible, in seconds.
    public static let duration = 0.4

    /// Returns `image` with every click younger than `duration` drawn as a fading ring, or
    /// `image` itself when none are.
    public static func draw(_ clicks: [Click], at time: CMTime, on image: CGImage) throws -> CGImage {
        let visible = clicks.compactMap { click -> (location: CGPoint, progress: Double)? in
            let age = CMTimeGetSeconds(time - click.time)
            guard age >= 0, age < duration else { return nil }
            return (click.location, age / duration)
        }
        guard !visible.isEmpty else { return image }

        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let context = try makeBitmapContext(width: image.width, height: image.height)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Sized to the frame so the ring reads the same in a small GIF as in a large one.
        let baseRadius = max(10, max(width, height) * 0.02)
        context.setLineWidth(max(2, baseRadius * 0.12))
        for click in visible {
            let radius = baseRadius * (0.6 + 0.4 * click.progress)
            let opacity = 1 - click.progress
            let ring = CGRect(
                x: click.location.x * width - radius,
                y: click.location.y * height - radius,
                width: radius * 2,
                height: radius * 2
            )
            context.setFillColor(CGColor(srgbRed: 1, green: 0.8, blue: 0, alpha: 0.45 * opacity))
            context.fillEllipse(in: ring)
            context.setStrokeColor(CGColor(srgbRed: 1, green: 0.8, blue: 0, alpha: 0.9 * opacity))
            context.strokeEllipse(in: ring)
        }
        return try context.renderedImage()
    }
}
