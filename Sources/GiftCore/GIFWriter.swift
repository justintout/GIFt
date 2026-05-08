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
        fileManager: FileManager = .default,
        maximumFrameRate: Int = 15,
        maximumPixelDimension: Int = 1280
    ) throws -> URL {
        guard !frames.isEmpty else { throw GIFWritingError.noFrames }
        let frames = framesForWriting(
            frames,
            maximumFrameRate: maximumFrameRate,
            maximumPixelDimension: maximumPixelDimension
        )
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

    static func framesForWriting(
        _ frames: [GIFFrame],
        maximumFrameRate: Int,
        maximumPixelDimension: Int
    ) -> [GIFFrame] {
        sampledFrames(frames, maximumFrameRate: maximumFrameRate).map { frame in
            GIFFrame(
                image: image(frame.image, scaledToMaximumPixelDimension: maximumPixelDimension),
                timestamp: frame.timestamp
            )
        }
    }

    static func sampledFrames(_ frames: [GIFFrame], maximumFrameRate: Int) -> [GIFFrame] {
        guard frames.count > 2, maximumFrameRate > 0 else { return frames }

        let minimumInterval = 1.0 / Double(maximumFrameRate)
        var sampled = [frames[0]]
        var lastIncludedTimestamp = frames[0].timestamp

        for frame in frames.dropFirst() {
            let elapsed = CMTimeGetSeconds(frame.timestamp - lastIncludedTimestamp)
            guard elapsed.isFinite else { continue }
            if elapsed >= minimumInterval {
                sampled.append(frame)
                lastIncludedTimestamp = frame.timestamp
            }
        }

        if let last = frames.last,
           let sampledLast = sampled.last,
           CMTimeCompare(sampledLast.timestamp, last.timestamp) != 0 {
            sampled.append(last)
        }

        return sampled
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

    private static func image(_ image: CGImage, scaledToMaximumPixelDimension maximumPixelDimension: Int) -> CGImage {
        guard maximumPixelDimension > 0 else { return image }
        let currentMaximum = max(image.width, image.height)
        guard currentMaximum > maximumPixelDimension else { return image }

        let scale = CGFloat(maximumPixelDimension) / CGFloat(currentMaximum)
        let scaledWidth = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let scaledHeight = max(1, Int((CGFloat(image.height) * scale).rounded()))

        guard let context = CGContext(
            data: nil,
            width: scaledWidth,
            height: scaledHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return image
        }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: scaledWidth, height: scaledHeight))
        return context.makeImage() ?? image
    }
}
