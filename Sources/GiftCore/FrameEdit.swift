import CoreGraphics
import Foundation

/// What the user changes about a recording before it is written: which frames to keep, and how
/// far to scale them down.
public struct FrameEdit: Equatable, Sendable {
    /// Indices of the first and last frame to keep, inclusive.
    public var range: ClosedRange<Int>
    /// Fraction of the captured size, at most 1.
    public var scale: Double

    public init(range: ClosedRange<Int>, scale: Double = 1) {
        self.range = range
        self.scale = min(scale, 1)
    }

    /// Keeps every frame at its captured size.
    public static func unchanged(frameCount: Int) -> FrameEdit {
        FrameEdit(range: 0...max(frameCount - 1, 0))
    }

    public func outputSize(width: Int, height: Int) -> (width: Int, height: Int) {
        guard scale < 1 else { return (width, height) }
        return (
            max(1, Int((Double(width) * scale).rounded())),
            max(1, Int((Double(height) * scale).rounded()))
        )
    }

    public func apply(to frames: [GIFFrame]) throws -> [GIFFrame] {
        try frames[keptIndices(count: frames.count)].map(scaled)
    }

    /// Encodes a few evenly spaced frames from the kept range and extrapolates. The encoder
    /// compresses each frame independently, so the average of a sample scales to the whole range.
    public func estimatedByteCount(of frames: [GIFFrame], fps: Int, sampleLimit: Int = 6) throws -> Int {
        let kept = keptIndices(count: frames.count)
        guard !kept.isEmpty, sampleLimit > 0 else { return 0 }

        let sampleCount = min(sampleLimit, kept.count)
        let step = Double(kept.count) / Double(sampleCount)
        let samples = try (0..<sampleCount).map { sample in
            try scaled(frames[kept.lowerBound + Int(Double(sample) * step)])
        }
        let bytes = try GIFWriter.encodedByteCount(frames: samples, fps: fps)
        return bytes * kept.count / sampleCount
    }

    private func keptIndices(count: Int) -> Range<Int> {
        let lower = max(range.lowerBound, 0)
        let upper = min(range.upperBound, count - 1)
        return lower <= upper ? lower..<(upper + 1) : 0..<0
    }

    private func scaled(_ frame: GIFFrame) throws -> GIFFrame {
        let size = outputSize(width: frame.image.width, height: frame.image.height)
        guard size != (frame.image.width, frame.image.height) else { return frame }

        let context = try makeBitmapContext(width: size.width, height: size.height)
        context.interpolationQuality = .high
        context.draw(frame.image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        return GIFFrame(image: try context.renderedImage(), timestamp: frame.timestamp)
    }
}
