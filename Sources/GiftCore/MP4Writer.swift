import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

public enum MP4WritingError: LocalizedError, Equatable {
    case noFrames
    case writerFailed(String)
    case pixelBufferUnavailable

    public var errorDescription: String? {
        switch self {
        case .noFrames: return "No frames were captured."
        case .writerFailed(let reason): return "Unable to write the video: \(reason)"
        case .pixelBufferUnavailable: return "Unable to allocate a video frame."
        }
    }
}

/// Writes frames as an H.264 MP4 with AVFoundation, which uses the hardware encoder and needs no
/// third-party code.
public enum MP4Writer {
    /// Encoder quality from 0 to 1.
    public static let defaultQuality = 0.6

    public static func write(
        frames: [GIFFrame],
        fps: Int,
        quality: Double = defaultQuality,
        outputDirectory: URL,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) async throws -> URL {
        guard !frames.isEmpty else { throw MP4WritingError.noFrames }
        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let url = GIFWriter.nextOutputURL(outputDirectory: outputDirectory, pathExtension: "mp4", now: now, fileManager: fileManager)

        // Same reasoning as GIFWriter: never leave a half-written file under the final name.
        let temporaryURL = outputDirectory.appendingPathComponent(".gift-\(UUID().uuidString).mp4")
        do {
            try await encode(frames: frames, fps: fps, quality: quality, to: temporaryURL)
            try fileManager.moveItem(at: temporaryURL, to: url)
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
        return url
    }

    /// The size the frames would occupy as an MP4. Encodes all of them: the hardware encoder is
    /// fast, and sampling would misjudge a format whose frames depend on each other.
    public static func encodedByteCount(frames: [GIFFrame], fps: Int, quality: Double = defaultQuality) async throws -> Int {
        guard !frames.isEmpty else { throw MP4WritingError.noFrames }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gift-estimate-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        try await encode(frames: frames, fps: fps, quality: quality, to: url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.intValue ?? 0
    }

    static func encode(frames: [GIFFrame], fps: Int, quality: Double, to url: URL) async throws {
        // 4:2:0 chroma needs even dimensions; dropping the odd last row or column is invisible.
        let width = max(2, frames[0].image.width & ~1)
        let height = max(2, frames[0].image.height & ~1)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            // Captured frames are sRGB, which shares BT.709's primaries.
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoQualityKey: quality,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ])
        writer.add(input)
        guard writer.startWriting() else { throw failure(of: writer) }
        writer.startSession(atSourceTime: .zero)

        let start = frames[0].timestamp
        for frame in frames {
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing else { throw failure(of: writer) }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            let buffer = try pixelBuffer(for: frame.image, width: width, height: height, pool: adaptor.pixelBufferPool)
            guard adaptor.append(buffer, withPresentationTime: frame.timestamp - start) else { throw failure(of: writer) }
        }
        input.markAsFinished()
        // Without an explicit end the last frame gets no duration and players cut it.
        writer.endSession(atSourceTime: endTime(of: frames, fps: fps) - start)
        await writer.finishWriting()
        guard writer.status == .completed else { throw failure(of: writer) }
    }

    /// The last frame is held for as long as the gap before it, matching how the GIF times it.
    private static func endTime(of frames: [GIFFrame], fps: Int) -> CMTime {
        let last = frames[frames.count - 1].timestamp
        guard frames.count > 1 else { return last + CMTime(value: 1, timescale: CMTimeScale(max(fps, 1))) }
        let gap = last - frames[frames.count - 2].timestamp
        return last + (gap > .zero ? gap : CMTime(value: 1, timescale: CMTimeScale(max(fps, 1))))
    }

    private static func pixelBuffer(for image: CGImage, width: Int, height: Int, pool: CVPixelBufferPool?) throws -> CVPixelBuffer {
        var created: CVPixelBuffer?
        guard let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &created) == kCVReturnSuccess, let buffer = created else {
            throw MP4WritingError.pixelBufferUnavailable
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            throw MP4WritingError.pixelBufferUnavailable
        }
        // Anchored top-left, so an odd row or column is trimmed from the bottom or right edge.
        context.draw(image, in: CGRect(x: 0, y: height - image.height, width: image.width, height: image.height))
        return buffer
    }

    private static func failure(of writer: AVAssetWriter) -> MP4WritingError {
        .writerFailed(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")
    }
}
