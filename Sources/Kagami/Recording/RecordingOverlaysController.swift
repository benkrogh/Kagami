import AppKit

// MARK: - Click highlight / keystroke overlay coordinator
//
// Bridges the click-highlight and keystroke-visualization overlay windows
// into the recording lifecycle, mirroring `WebcamRecordingController`. Both
// overlays are independent per-session opt-ins (the icon toggles in
// `RecordingControlsView`), so each is only started/stopped if it was
// actually requested for the recording in progress.

@MainActor
final class RecordingOverlaysController {
    static let shared = RecordingOverlaysController()
    private init() {}

    private(set) var clicksEnabled = false
    private(set) var keystrokesEnabled = false

    func begin(showClicks: Bool, showKeystrokes: Bool, anchorRect: CGRect? = nil) {
        clicksEnabled = showClicks
        if showClicks {
            ClickHighlightOverlayWindowManager.shared.show(anchorRect: anchorRect)
        }

        // Keystroke capture needs Accessibility trust — a soft dependency,
        // same as the webcam bubble needing Camera access: missing it just
        // means this one overlay doesn't appear, not that the whole
        // recording is blocked.
        keystrokesEnabled = showKeystrokes && ScreenCaptureManager.shared.ensureAccessibilityPermission()
        if keystrokesEnabled {
            KeystrokeOverlayWindowManager.shared.show(anchorRect: anchorRect)
        }
    }

    func stop() {
        if clicksEnabled {
            ClickHighlightOverlayWindowManager.shared.hide()
        }
        if keystrokesEnabled {
            KeystrokeOverlayWindowManager.shared.hide()
        }
        clicksEnabled = false
        keystrokesEnabled = false
    }
}
