import AVFoundation
import CoreGraphics
import CoreMedia
@testable import GiftCore
import XCTest

final class MP4WriterTests: XCTestCase {
    func testWritesEvenSizedVideoThatHoldsTheLastFrame() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gift-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let frames = try (0..<3).map { index in
            GIFFrame(image: try solidImage(width: 161, height: 101, blue: CGFloat(index) / 2),
                     timestamp: CMTime(seconds: 5 + Double(index) * 0.1, preferredTimescale: 600))
        }

        let url = try await MP4Writer.write(frames: frames, fps: 10, outputDirectory: directory, now: Date(timeIntervalSince1970: 7))

        XCTAssertEqual(url.lastPathComponent, "gift-7000.mp4")
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 160, height: 100))
        // Three frames 0.1 s apart, the last held for the same gap.
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, 0.3, accuracy: 0.02)
    }

    private func solidImage(width: Int, height: Int, blue: CGFloat) throws -> CGImage {
        let context = try makeBitmapContext(width: width, height: height)
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try context.renderedImage()
    }
}
