import CoreGraphics
import Foundation

public struct DisplayGeometry: Equatable, Sendable {
    public var frame: CGRect
    public var pointPixelScale: CGFloat

    public init(frame: CGRect, pointPixelScale: CGFloat) {
        self.frame = frame.standardized
        self.pointPixelScale = pointPixelScale
    }
}

public struct CaptureGeometry: Equatable, Sendable {
    public var selectionRect: CGRect
    public var sourceRect: CGRect
    public var outputWidth: Int
    public var outputHeight: Int

    public init(selectionRect: CGRect, sourceRect: CGRect, outputWidth: Int, outputHeight: Int) {
        self.selectionRect = selectionRect
        self.sourceRect = sourceRect
        self.outputWidth = outputWidth
        self.outputHeight = outputHeight
    }
}

public enum CaptureGeometryError: LocalizedError, Equatable {
    case emptySelection
    case invalidScale

    public var errorDescription: String? {
        switch self {
        case .emptySelection: return "Select an area within a display."
        case .invalidScale: return "Unable to determine the display scale."
        }
    }
}

public enum CaptureGeometryCalculator {
    /// - Parameter maximumPixelDimension: Cap on the longer side of the captured output, so the
    ///   capture delivers GIF-sized frames instead of full-resolution ones. Pass `nil` to keep the
    ///   selection's native resolution. Only ever scales down; a small selection keeps its size.
    public static func geometry(
        for selectionRect: CGRect,
        on display: DisplayGeometry,
        maximumPixelDimension: Int? = nil
    ) throws -> CaptureGeometry {
        guard display.pointPixelScale > 0, display.pointPixelScale.isFinite else {
            throw CaptureGeometryError.invalidScale
        }

        let clippedSelection = selectionRect.standardized.clamped(to: display.frame)
        guard !clippedSelection.isEmpty else {
            throw CaptureGeometryError.emptySelection
        }

        let localBottomLeft = CGRect(
            x: clippedSelection.minX - display.frame.minX,
            y: clippedSelection.minY - display.frame.minY,
            width: clippedSelection.width,
            height: clippedSelection.height
        )
        let localTopLeft = CGRect(
            x: localBottomLeft.minX,
            y: display.frame.height - localBottomLeft.maxY,
            width: localBottomLeft.width,
            height: localBottomLeft.height
        )

        let pixelRect = localTopLeft.scaled(by: display.pointPixelScale).integral
        guard pixelRect.width > 0, pixelRect.height > 0 else {
            throw CaptureGeometryError.emptySelection
        }

        let outputSize = pixelRect.scaledDown(toFitWithin: maximumPixelDimension)
        return CaptureGeometry(
            selectionRect: clippedSelection,
            sourceRect: pixelRect.scaled(by: 1 / display.pointPixelScale),
            outputWidth: outputSize.width,
            outputHeight: outputSize.height
        )
    }

    /// Output pixel dimensions for capturing `frame` whole, capped on its longer side the same way
    /// a region is. A whole-window capture has no source rect to compute: ScreenCaptureKit gives
    /// the window's full content and scales it to this size.
    public static func outputSize(
        forFrame frame: CGRect,
        pointPixelScale: CGFloat,
        maximumPixelDimension: Int? = nil
    ) throws -> (width: Int, height: Int) {
        guard pointPixelScale > 0, pointPixelScale.isFinite else {
            throw CaptureGeometryError.invalidScale
        }

        let pixelRect = frame.standardized.scaled(by: pointPixelScale).integral
        guard pixelRect.width > 0, pixelRect.height > 0 else {
            throw CaptureGeometryError.emptySelection
        }

        return pixelRect.scaledDown(toFitWithin: maximumPixelDimension)
    }
}

private extension CGRect {
    func clamped(to bounds: CGRect) -> CGRect {
        let standardizedBounds = bounds.standardized
        let x1 = max(minX, standardizedBounds.minX)
        let y1 = max(minY, standardizedBounds.minY)
        let x2 = min(maxX, standardizedBounds.maxX)
        let y2 = min(maxY, standardizedBounds.maxY)
        if x2 <= x1 || y2 <= y1 { return .zero }
        return CGRect(x: x1, y: y1, width: x2 - x1, height: y2 - y1)
    }

    func scaled(by scale: CGFloat) -> CGRect {
        CGRect(
            x: origin.x * scale,
            y: origin.y * scale,
            width: size.width * scale,
            height: size.height * scale
        )
    }

    /// Returns this rect's dimensions in whole pixels, reduced by a single shared factor so the
    /// longer side is at most `limit`. Never enlarges.
    func scaledDown(toFitWithin limit: Int?) -> (width: Int, height: Int) {
        let width = Int(self.width)
        let height = Int(self.height)
        guard let limit, limit > 0 else { return (width, height) }

        let longest = max(width, height)
        guard longest > limit else { return (width, height) }

        let factor = CGFloat(limit) / CGFloat(longest)
        return (
            max(1, Int((CGFloat(width) * factor).rounded())),
            max(1, Int((CGFloat(height) * factor).rounded()))
        )
    }
}
