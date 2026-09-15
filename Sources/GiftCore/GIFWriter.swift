import CoreGraphics
import CoreMedia
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct GIFFrame {
    public var image: CGImage
    public var timestamp: CMTime

    public init(image: CGImage, timestamp: CMTime) {
        self.image = image
        self.timestamp = timestamp
    }
}

public enum GIFWritingError: LocalizedError, Equatable {
    case noFrames
    case destinationCreationFailed
    case finalizeFailed

    public var errorDescription: String? {
        switch self {
        case .noFrames: return "No frames were captured."
        case .destinationCreationFailed: return "Unable to create the GIF destination."
        case .finalizeFailed: return "Unable to finish writing the GIF."
        }
    }
}

public enum GIFWriter {
    /// GIF stores frame delays in hundredths of a second, so any delay is rounded to this unit.
    private static let delayQuantum = 0.01
    /// Viewers substitute 0.1s for shorter delays, so never emit one.
    private static let minimumDelay = 0.02

    public static func write(
        frames: [GIFFrame],
        fps: Int,
        outputDirectory: URL,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) throws -> URL {
        guard !frames.isEmpty else { throw GIFWritingError.noFrames }
        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let url = nextOutputURL(outputDirectory: outputDirectory, now: now, fileManager: fileManager)

        // Encode beside the destination, then move it into place, so a failed encode
        // cannot leave a truncated GIF in the user's output folder.
        let temporaryURL = outputDirectory.appendingPathComponent(".gift-\(UUID().uuidString).gif")
        do {
            try encode(frames: frames, fps: fps, to: temporaryURL)
            try fileManager.moveItem(at: temporaryURL, to: url)
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
        return url
    }

    private static func encode(frames: [GIFFrame], fps: Int, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else {
            throw GIFWritingError.destinationCreationFailed
        }

        let gifProps: CFDictionary = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ] as CFDictionary
        CGImageDestinationSetProperties(destination, gifProps)

        let delays = frameDelays(for: frames, fps: fps)
        for index in frames.indices {
            let delay = delays[index]
            let frameProps: CFDictionary = [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: delay,
                    kCGImagePropertyGIFUnclampedDelayTime: delay
                ]
            ] as CFDictionary
            CGImageDestinationAddImage(destination, frames[index].image, frameProps)
        }

        guard CGImageDestinationFinalize(destination) else {
            throw GIFWritingError.finalizeFailed
        }
    }

    /// Per-frame delays in seconds, each rounded to the hundredth of a second the GIF format
    /// can represent. The rounding error is carried into the next frame so the total duration
    /// matches the requested rate instead of drifting short.
    static func frameDelays(for frames: [GIFFrame], fps: Int) -> [Double] {
        let fallbackDelay = 1.0 / Double(max(fps, 1))
        var delays: [Double] = []
        delays.reserveCapacity(frames.count)
        var carriedError = 0.0

        for index in frames.indices {
            let desired = desiredDelay(at: index, in: frames, fallback: fallbackDelay)
            let quantized = quantizedDelay(desired + carriedError)
            carriedError = desired + carriedError - quantized
            delays.append(quantized)
        }

        return delays
    }

    /// The wall-clock gap this frame should be shown for, taken from the recording's own
    /// timestamps. The final frame reuses the gap before it, since it has no successor.
    private static func desiredDelay(at index: Int, in frames: [GIFFrame], fallback: Double) -> Double {
        let desired: Double
        if frames.indices.contains(index + 1) {
            desired = CMTimeGetSeconds(frames[index + 1].timestamp - frames[index].timestamp)
        } else if index > frames.startIndex {
            desired = CMTimeGetSeconds(frames[index].timestamp - frames[index - 1].timestamp)
        } else {
            return fallback
        }

        guard desired.isFinite, desired > 0 else { return fallback }
        return desired
    }

    private static func quantizedDelay(_ seconds: Double) -> Double {
        let hundredths = (seconds / delayQuantum).rounded()
        return max(hundredths * delayQuantum, minimumDelay)
    }

    private static func nextOutputURL(outputDirectory: URL, now: Date, fileManager: FileManager) -> URL {
        let milliseconds = Int((now.timeIntervalSince1970 * 1000).rounded())
        var url = outputDirectory.appendingPathComponent("gift-\(milliseconds).gif")
        var suffix = 1
        while fileManager.fileExists(atPath: url.path) {
            url = outputDirectory.appendingPathComponent("gift-\(milliseconds)-\(suffix).gif")
            suffix += 1
        }
        return url
    }
}
