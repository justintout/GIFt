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

        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else {
            throw GIFWritingError.destinationCreationFailed
        }

        let gifProps: CFDictionary = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ] as CFDictionary
        CGImageDestinationSetProperties(destination, gifProps)

        for index in frames.indices {
            let delay = frameDelay(at: index, in: frames, fps: fps)
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
        return url
    }

    static func frameDelay(at index: Int, in frames: [GIFFrame], fps: Int) -> Double {
        let fallbackDelay = 1.0 / Double(max(fps, 1))
        let delay: Double
        if frames.indices.contains(index + 1) {
            delay = CMTimeGetSeconds(frames[index + 1].timestamp - frames[index].timestamp)
        } else if index > frames.startIndex {
            delay = CMTimeGetSeconds(frames[index].timestamp - frames[index - 1].timestamp)
        } else {
            delay = fallbackDelay
        }

        guard delay.isFinite, delay > 0 else { return fallbackDelay }
        return max(delay, 0.02)
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
