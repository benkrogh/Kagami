import AppKit
import AVFoundation

enum CaptureMediaHelpers {
    /// First-frame thumbnail and display dimensions for a video file.
    static func videoMetadata(from url: URL) -> (thumbnail: NSImage?, dimensions: CGSize) {
        let asset = AVURLAsset(url: url)
        let dimensions = videoDimensions(in: asset)
        let thumbnail = videoThumbnail(from: asset)
        return (thumbnail, dimensions)
    }

    static func videoDimensions(in asset: AVURLAsset) -> CGSize {
        guard let track = asset.tracks(withMediaType: .video).first else { return .zero }
        let transformed = track.naturalSize.applying(track.preferredTransform)
        return CGSize(width: abs(transformed.width), height: abs(transformed.height))
    }

    static func videoThumbnail(from asset: AVURLAsset, maxEdge: CGFloat = 600) -> NSImage? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxEdge, height: maxEdge)

        let seconds = min(0.5, max(0, CMTimeGetSeconds(asset.duration) * 0.1))
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        guard let cg = try? generator.copyCGImage(at: time, actualTime: nil) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
