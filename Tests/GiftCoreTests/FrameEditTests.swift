import CoreGraphics
import CoreMedia
@testable import GiftCore
import XCTest

final class FrameEditTests: XCTestCase {
    func testApplyKeepsTheRangeAtTheRequestedScaleWithOriginalTimestamps() throws {
        let frames = (0..<10).map { index in
            GIFFrame(image: try! solidImage(width: 200, height: 100), timestamp: CMTime(seconds: Double(index) / 10, preferredTimescale: 600))
        }

        let edited = try FrameEdit(range: 2...6, scale: 0.5).apply(to: frames)

        XCTAssertEqual(edited.count, 5)
        XCTAssertEqual(edited.map(\.image.width), Array(repeating: 100, count: 5))
        XCTAssertEqual(edited.map(\.image.height), Array(repeating: 50, count: 5))
        XCTAssertEqual(edited.map(\.timestamp), frames[2...6].map(\.timestamp))
    }

    func testEstimateGrowsWithTheKeptRangeAndShrinksWithScale() throws {
        let frames = (0..<20).map { index in
            GIFFrame(image: try! solidImage(width: 200, height: 100), timestamp: CMTime(seconds: Double(index) / 10, preferredTimescale: 600))
        }

        let whole = try FrameEdit.unchanged(frameCount: frames.count).estimatedByteCount(of: frames, fps: 10)
        let half = try FrameEdit(range: 0...9).estimatedByteCount(of: frames, fps: 10)
        let small = try FrameEdit(range: 0...19, scale: 0.25).estimatedByteCount(of: frames, fps: 10)

        XCTAssertGreaterThan(whole, half)
        XCTAssertGreaterThan(whole, small)
    }

    func testClickIsDrawnWhileFreshAndGoneOnceExpired() throws {
        let image = try solidImage(width: 100, height: 100)
        let click = Click(location: CGPoint(x: 0.5, y: 0.5), time: CMTime(seconds: 10, preferredTimescale: 600))

        let fresh = try ClickHighlighter.draw([click], at: CMTime(seconds: 10.05, preferredTimescale: 600), on: image)
        let expired = try ClickHighlighter.draw([click], at: CMTime(seconds: 11, preferredTimescale: 600), on: image)

        XCTAssertNotEqual(try centerPixel(of: fresh), try centerPixel(of: image))
        XCTAssertTrue(expired === image)
    }

    private func solidImage(width: Int, height: Int) throws -> CGImage {
        let context = try makeBitmapContext(width: width, height: height)
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try context.renderedImage()
    }

    private func centerPixel(of image: CGImage) throws -> [UInt8] {
        let context = try makeBitmapContext(width: 1, height: 1)
        context.draw(image, in: CGRect(x: -image.width / 2, y: -image.height / 2, width: image.width, height: image.height))
        let data = try XCTUnwrap(context.data)
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: 4))
    }
}
