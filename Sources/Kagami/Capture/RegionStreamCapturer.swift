import AppKit
import ScreenCaptureKit
import CoreMedia
import CoreVideo

// MARK: - Region Stream Capturer
//
// A continuous ScreenCaptureKit stream scoped to a single screen region. Unlike
// one-shot SCScreenshotManager captures (which require an expensive
// SCShareableContent enumeration + fresh filter every call, capping us at a few
// fps), an SCStream is configured once and then pushes frames via a callback at a
// high, steady rate. That high frame rate is what makes scroll stitching reliable:
// consecutive frames overlap heavily, so each newly-revealed sliver is tiny and
// easy to match precisely.
//
// Only frames flagged `.complete` (i.e. the content actually changed) are
// delivered, so a static screen costs nothing.

final class RegionStreamCapturer: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let outputQueue = DispatchQueue(label: "com.kagami.scrollcapture.frames")
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    /// Called on the capturer's serial output queue (NOT the main thread) with each
    /// new full-resolution region frame. Keep the handler cheap or hand off to
    /// another queue — blocking here stalls capture.
    var onFrame: ((CGImage) -> Void)?

    func start(globalTopLeftRect rect: CGRect, excludingWindowIDs: [CGWindowID], fps: Int) async -> Bool {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

            let center = CGPoint(x: rect.midX, y: rect.midY)
            guard let display = content.displays.first(where: { CGDisplayBounds($0.displayID).contains(center) })
                    ?? content.displays.first(where: { CGDisplayBounds($0.displayID).intersects(rect) })
                    ?? content.displays.first
            else { return false }

            let bounds = CGDisplayBounds(display.displayID)
            let excluded: [SCWindow] = excludingWindowIDs.isEmpty
                ? []
                : content.windows.filter { excludingWindowIDs.contains($0.windowID) }

            let filter = SCContentFilter(display: display, excludingWindows: excluded)
            let scale  = CGFloat(filter.pointPixelScale)
            let local  = CGRect(x: rect.minX - bounds.minX,
                                y: rect.minY - bounds.minY,
                                width: rect.width, height: rect.height)

            let config = SCStreamConfiguration()
            config.sourceRect = local
            config.width  = max(1, Int((rect.width  * scale).rounded()))
            config.height = max(1, Int((rect.height * scale).rounded()))
            config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))
            config.showsCursor = false
            config.queueDepth = 6
            config.pixelFormat = kCVPixelFormatType_32BGRA

            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
            try await stream.startCapture()
            self.stream = stream
            return true
        } catch {
            print("RegionStreamCapturer.start error: \(error)")
            return false
        }
    }

    func stop() async {
        guard let s = stream else { return }
        stream = nil
        try? await s.stopCapture()
    }

    // MARK: SCStreamOutput

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        // Drain Core Image's per-frame autoreleased objects; on a long-lived queue
        // they otherwise accumulate until allocations start failing.
        autoreleasepool {
            // Only act on frames whose content actually changed.
            guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let attachments = attachmentsArray.first,
                  let statusRaw = attachments[SCStreamFrameInfo.status] as? Int,
                  let status = SCFrameStatus(rawValue: statusRaw),
                  status == .complete,
                  let pixelBuffer = sampleBuffer.imageBuffer
            else { return }

            let ci = CIImage(cvImageBuffer: pixelBuffer)
            guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { return }

            // Already on the serial output queue — deliver directly so the stitcher
            // can do its (background) work without bouncing through the main thread.
            onFrame?(cg)
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("RegionStreamCapturer stopped with error: \(error)")
    }
}
