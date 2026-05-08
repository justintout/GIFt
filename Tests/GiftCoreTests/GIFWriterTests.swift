import CoreGraphics
import CoreMedia
import ImageIO
@testable import GiftCore
import XCTest

final class GIFWriterTests: XCTestCase {
    func testWriterCreatesDirectoryAndGIFWithExpectedFrameMetadata() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gift-tests-\(UUID().uuidString)")
            .appendingPathComponent("nested")
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

        let frames = [
            GIFFrame(image: makeImage(width: 3, height: 2, red: 1, green: 0, blue: 0), timestamp: CMTime(seconds: 0, preferredTimescale: 600)),
            GIFFrame(image: makeImage(width: 3, height: 2, red: 0, green: 0, blue: 1), timestamp: CMTime(seconds: 0.25, preferredTimescale: 600))
        ]

        let url = try GIFWriter.write(
            frames: frames,
            fps: 30,
            outputDirectory: directory,
            now: Date(timeIntervalSince1970: 123.456)
        )

        XCTAssertEqual(url.lastPathComponent, "gift-123456.gif")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 2)

        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as NSDictionary?)
        XCTAssertEqual((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, 3)
        XCTAssertEqual((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, 2)

        let gifProperties = try XCTUnwrap(properties[kCGImagePropertyGIFDictionary] as? NSDictionary)
        let delay = try XCTUnwrap((gifProperties[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber)?.doubleValue)
        XCTAssertEqual(delay, 0.25, accuracy: 0.001)
    }

    func testWriterAvoidsOverwritingExistingFileForSameTimestamp() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gift-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let frame = GIFFrame(
            image: makeImage(width: 1, height: 1, red: 0, green: 1, blue: 0),
            timestamp: CMTime(seconds: 0, preferredTimescale: 600)
        )
        let now = Date(timeIntervalSince1970: 99)

        let firstURL = try GIFWriter.write(frames: [frame], fps: 20, outputDirectory: directory, now: now)
        let secondURL = try GIFWriter.write(frames: [frame], fps: 20, outputDirectory: directory, now: now)

        XCTAssertEqual(firstURL.lastPathComponent, "gift-99000.gif")
        XCTAssertEqual(secondURL.lastPathComponent, "gift-99000-1.gif")
    }

    func testFrameDelayFallsBackForSingleFrame() {
        let frame = GIFFrame(
            image: makeImage(width: 1, height: 1, red: 1, green: 1, blue: 1),
            timestamp: CMTime(seconds: 0, preferredTimescale: 600)
        )

        XCTAssertEqual(GIFWriter.frameDelay(at: 0, in: [frame], fps: 20), 0.05)
    }

    private func makeImage(width: Int, height: Int, red: CGFloat, green: CGFloat, blue: CGFloat) -> CGImage {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }
}
