import AppKit

// MARK: - Webcam session coordinator
//
// Bridges the webcam capture session + bubble window into the recording
// lifecycle. Webcam failures (denied permission, no camera attached) are
// treated as non-fatal — the screen recording still proceeds without the
// bubble rather than blocking the whole recording.

@MainActor
final class WebcamRecordingController: ObservableObject {
    static let shared = WebcamRecordingController()
    private init() {}

    /// Whether the webcam bubble was requested for the recording currently in progress.
    @Published private(set) var isEnabledForSession = false
    /// Whether the bubble is currently on-screen (can be toggled mid-recording).
    @Published private(set) var isVisible = false

    /// The capture region the current recording session is anchored to (nil
    /// for fullscreen/window recordings). Remembered so toggling the bubble
    /// back on mid-recording re-anchors to the same region instead of
    /// falling back to the primary screen's corner.
    private var sessionAnchorRect: CGRect?

    @discardableResult
    func begin(enabled: Bool, anchorRect: CGRect? = nil) async -> Bool {
        guard enabled else { return true }

        guard await ScreenCaptureManager.shared.ensureCameraPermission() else {
            return false
        }

        do {
            try WebcamCaptureManager.shared.start()
        } catch {
            print("Webcam start error: \(error)")
            return false
        }

        sessionAnchorRect = anchorRect
        WebcamOverlayWindowManager.shared.show(anchorRect: anchorRect)
        isEnabledForSession = true
        isVisible = true
        return true
    }

    func toggleVisibility() {
        guard isEnabledForSession else { return }
        if isVisible {
            WebcamOverlayWindowManager.shared.hide()
            isVisible = false
        } else {
            // The capture session keeps running while the bubble is hidden,
            // but if it was ever interrupted (e.g. another app grabbed the
            // camera, or the system paused it) re-assert it here so turning
            // the bubble back on reliably shows a live feed again.
            if !WebcamCaptureManager.shared.isRunning {
                do {
                    try WebcamCaptureManager.shared.start()
                } catch {
                    print("Webcam restart error: \(error)")
                }
            }
            WebcamOverlayWindowManager.shared.show(anchorRect: sessionAnchorRect)
            isVisible = true
        }
    }

    func stop() {
        guard isEnabledForSession else { return }
        WebcamOverlayWindowManager.shared.hide()
        WebcamCaptureManager.shared.stop()
        isEnabledForSession = false
        isVisible = false
        sessionAnchorRect = nil
    }
}
