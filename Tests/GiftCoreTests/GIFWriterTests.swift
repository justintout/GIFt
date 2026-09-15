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

        let delays = try readDelays(from: url)
        XCTAssertEqual(delays[0], 0.25, accuracy: 0.001)
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

    func testWriterLeavesNoTemporaryFileBehind() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gift-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let frames = [
            GIFFrame(image: makeImage(width: 2, height: 2, red: 1, green: 1, blue: 1), timestamp: CMTime(seconds: 0, preferredTimescale: 600)),
            GIFFrame(image: makeImage(width: 2, height: 2, red: 0, green: 0, blue: 0), timestamp: CMTime(seconds: 0.1, preferredTimescale: 600))
        ]
        _ = try GIFWriter.write(frames: frames, fps: 10, outputDirectory: directory)

        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(contents.filter { $0.hasSuffix(".gif") }.count, 1)
        XCTAssertFalse(contents.contains { $0.hasPrefix(".gift-") })
    }

    func testFrameDelaysFallBackForSingleFrame() {
        let frame = GIFFrame(
            image: makeImage(width: 1, height: 1, red: 1, green: 1, blue: 1),
            timestamp: CMTime(seconds: 0, preferredTimescale: 600)
        )

        XCTAssertEqual(GIFWriter.frameDelays(for: [frame], fps: 20), [0.05])
    }

    func testFrameDelaysCarryRoundingErrorSoTotalDurationMatchesRequest() {
        for fps in [8, 10, 12, 15, 24, 30] {
            let frameCount = fps * 2
            let frames = (0..<frameCount).map { index in
                GIFFrame(
                    image: makeImage(width: 1, height: 1, red: 1, green: 0, blue: 0),
                    timestamp: CMTime(seconds: Double(index) / Double(fps), preferredTimescale: 60000)
                )
            }

            let total = GIFWriter.frameDelays(for: frames, fps: fps).reduce(0, +)
            let expected = Double(frameCount) / Double(fps)
            XCTAssertEqual(total, expected, accuracy: expected * 0.01, "\(fps) fps should not drift")
        }
    }

    /// The end-to-end version of the test above: ImageIO applies its own rounding on the way
    /// into the file, so read the delays back out the way a viewer would.
    func testWrittenGIFPlaysBackAtTheRequestedRate() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gift-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        for fps in [8, 10, 12, 15, 24, 30] {
            let frameCount = fps * 2
            let frames = (0..<frameCount).map { index in
                GIFFrame(
                    image: makeImage(width: 4, height: 4, red: 1, green: 0, blue: 0),
                    timestamp: CMTime(seconds: Double(index) / Double(fps), preferredTimescale: 60000)
                )
            }

            let url = try GIFWriter.write(frames: frames, fps: fps, outputDirectory: directory)
            let delays = try readDelays(from: url)
            XCTAssertEqual(delays.count, frameCount)

            let total = delays.reduce(0, +)
            let expected = Double(frameCount) / Double(fps)
            XCTAssertEqual(total, expected, accuracy: expected * 0.01, "\(fps) fps GIF should last \(expected)s")
        }
    }

    func testEncodePerformance() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gift-tests-bench-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        // Built outside the measured block: these are the encoder's input, not the work under test.
        let frames = (0..<120).map { index in
            GIFFrame(
                image: makeVariedImage(width: 640, height: 360, index: index),
                timestamp: CMTime(seconds: Double(index) / 12.0, preferredTimescale: 60000)
            )
        }

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            _ = try? GIFWriter.write(frames: frames, fps: 12, outputDirectory: directory)
        }
    }

    private func readDelays(from url: URL) throws -> [Double] {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try (0..<CGImageSourceGetCount(source)).map { index in
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, index, nil) as NSDictionary?)
            let gifProperties = try XCTUnwrap(properties[kCGImagePropertyGIFDictionary] as? NSDictionary)
            return try XCTUnwrap((gifProperties[kCGImagePropertyGIFDelayTime] as? NSNumber)?.doubleValue)
        }
    }

    private func makeImage(width: Int, height: Int, red: CGFloat, green: CGFloat, blue: CGFloat) -> CGImage {
        let context = makeContext(width: width, height: height)
        context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// Screen content differs every frame. Uniform frames would make the palette reduction and
    /// LZW pass trivially cheap and report an encode time far better than reality.
    private func makeVariedImage(width: Int, height: Int, index: Int) -> CGImage {
        let context = makeContext(width: width, height: height)
        let bandHeight = CGFloat(height) / 12
        let phase = CGFloat(index) / 60

        for band in 0..<12 {
            let t = (CGFloat(band) / 12 + phase).truncatingRemainder(dividingBy: 1)
            context.setFillColor(CGColor(red: t, green: 1 - t, blue: 0.5, alpha: 1))
            context.fill(CGRect(x: 0, y: CGFloat(band) * bandHeight, width: CGFloat(width), height: bandHeight + 1))
        }

        let blockSize = 16
        for x in stride(from: 0, to: width, by: blockSize) {
            for y in stride(from: 0, to: height, by: blockSize) {
                let v = CGFloat((x * 31 + y * 17 + index * 13) % 256) / 255
                context.setFillColor(CGColor(red: v, green: v, blue: v, alpha: 1))
                context.fill(CGRect(x: x, y: y, width: blockSize, height: blockSize))
            }
        }

        return context.makeImage()!
    }

    private func makeContext(width: Int, height: Int) -> CGContext {
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
    }
}
