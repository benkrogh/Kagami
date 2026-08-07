import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// Converts a finished screen recording into an animated GIF.
///
/// Recordings are always captured at full quality first (same pipeline as a
/// normal video); this runs afterwards to downsample + re-encode as a GIF,
/// which keeps the capture path simple and lets GIF output reuse everything
/// the video path already does (audio-free, so audio tracks are just ignored).
enum GifExporter {
    /// Frames per second in the exported GIF. Kept modest since GIF frames are
    /// stored uncompressed-ish (per-frame LZW), so higher fps balloons file size fast.
    static let frameRate: Double = 15
    /// Longest dimension is capped to keep file sizes reasonable for sharing.
    static let maxWidth: CGFloat = 1000

    enum ExportError: Error {
        case noVideoTrack
        case emptySource
        case destinationCreationFailed
        case finalizeFailed
    }

    static func export(from videoURL: URL, to outputURL: URL) async throws {
        let asset = AVURLAsset(url: videoURL)

        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ExportError.noVideoTrack
        }

        let durationSeconds = CMTimeGetSeconds(try await asset.load(.duration))
        guard durationSeconds > 0 else { throw ExportError.emptySource }

        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let displaySize = naturalSize.applying(transform)
        let width = abs(displaySize.width)
        let height = abs(displaySize.height)
        guard width > 0, height > 0 else { throw ExportError.noVideoTrack }

        let scale = min(1, maxWidth / width)
        let outputSize = CGSize(width: (width * scale).rounded(), height: (height * scale).rounded())

        let frameInterval = 1.0 / frameRate
        let frameCount = max(1, Int((durationSeconds / frameInterval).rounded(.down)))
        let times = (0..<frameCount).map { CMTime(seconds: Double($0) * frameInterval, preferredTimescale: 600) }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = outputSize
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let frames = try await generateFrames(generator: generator, times: times, frameInterval: frameInterval)

        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL, UTType.gif.identifier as CFString, times.count, nil
        ) else {
            throw ExportError.destinationCreationFailed
        }

        let containerProperties: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ]
        CGImageDestinationSetProperties(destination, containerProperties as CFDictionary)

        let frameProperties: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: frameInterval]
        ]

        for index in 0..<frameCount {
            guard let image = frames[index] else { continue }
            CGImageDestinationAddImage(destination, image, frameProperties as CFDictionary)
        }

        guard CGImageDestinationFinalize(destination) else {
            throw ExportError.finalizeFailed
        }
    }

    /// `generateCGImagesAsynchronously` can deliver frames out of order, so results
    /// are indexed back to their requested slot before being written to the GIF.
    private static func generateFrames(
        generator: AVAssetImageGenerator,
        times: [CMTime],
        frameInterval: Double
    ) async throws -> [Int: CGImage] {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[Int: CGImage], Error>) in
            var images: [Int: CGImage] = [:]
            var remaining = times.count
            var finished = false

            generator.generateCGImagesAsynchronously(forTimes: times.map { NSValue(time: $0) }) { requestedTime, image, _, result, error in
                guard !finished else { return }

                if result == .succeeded, let image {
                    let index = Int((CMTimeGetSeconds(requestedTime) / frameInterval).rounded())
                    images[index] = image
                }

                remaining -= 1
                if remaining == 0 {
                    finished = true
                    if images.isEmpty {
                        continuation.resume(throwing: error ?? ExportError.emptySource)
                    } else {
                        continuation.resume(returning: images)
                    }
                }
            }
        }
    }
}
