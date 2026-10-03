import CoreGraphics
import Foundation

public enum FrameRenderingError: LocalizedError, Equatable {
    case contextCreationFailed
    case imageCreationFailed

    public var errorDescription: String? {
        switch self {
        case .contextCreationFailed: return "Unable to allocate a frame for drawing."
        case .imageCreationFailed: return "Unable to render a frame."
        }
    }
}

/// An sRGB context in the same pixel layout ScreenCaptureKit delivers, so drawing a captured frame
/// into it needs no conversion.
func makeBitmapContext(width: Int, height: Int) throws -> CGContext {
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
              data: nil,
              width: width,
              height: height,
              bitsPerComponent: 8,
              bytesPerRow: 0,
              space: colorSpace,
              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
          ) else {
        throw FrameRenderingError.contextCreationFailed
    }
    return context
}

extension CGContext {
    func renderedImage() throws -> CGImage {
        guard let image = makeImage() else { throw FrameRenderingError.imageCreationFailed }
        return image
    }
}
