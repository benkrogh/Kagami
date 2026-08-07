import AppKit
import SwiftUI

// MARK: - Pre-recording countdown
//
// Shown between "Start Recording" and the capture actually beginning. This
// buys warm-up time for anything that can't start instantaneously — most
// notably the webcam session and microphone capture — so the very first
// frames of the recording don't show a blank camera bubble or clip audio.

@MainActor
final class RecordingCountdownWindowManager {
    static let shared = RecordingCountdownWindowManager()
    private init() {}

    private var panel: NSPanel?
    private var pendingWorkItem: DispatchWorkItem?

    var isRunning: Bool { panel != nil }

    /// Runs a `seconds` → 1 countdown (ticking once per second) centered over
    /// `anchorRect` (top-left global coordinates, or the main screen when
    /// `nil`), then calls `onComplete`. When `seconds <= 0` the countdown is
    /// skipped and `onComplete` fires immediately.
    func run(seconds: Int, anchorRect: CGRect? = nil, onComplete: @escaping () -> Void) {
        guard seconds > 0 else {
            onComplete()
            return
        }

        cancel()

        let state = CountdownState(count: seconds)
        let panel = makeFloatingPanel(width: 88, height: 88, cornerRadius: 22) {
            CountdownOverlayView(state: state)
        }
        panel.ignoresMouseEvents = true
        panel.isMovableByWindowBackground = false
        elevateForCaptureControls(panel)

        positionCentered(panel, anchorRect: anchorRect)
        panel.orderFront(nil)
        self.panel = panel

        tick(remaining: seconds, state: state, onComplete: onComplete)
    }

    /// Aborts an in-progress countdown without firing `onComplete`.
    func cancel() {
        pendingWorkItem?.cancel()
        pendingWorkItem = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private func tick(remaining: Int, state: CountdownState, onComplete: @escaping () -> Void) {
        state.count = remaining
        RecordingSounds.playCountdownTick()

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if remaining > 1 {
                self.tick(remaining: remaining - 1, state: state, onComplete: onComplete)
            } else {
                self.panel?.orderOut(nil)
                self.panel = nil
                self.pendingWorkItem = nil
                onComplete()
            }
        }
        pendingWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func positionCentered(_ panel: NSPanel, anchorRect: CGRect?) {
        if let anchorRect {
            let primaryH = NSScreen.screens.first?.frame.height ?? 0
            let bottomLeftRect = CGRect(
                x: anchorRect.minX,
                y: primaryH - (anchorRect.minY + anchorRect.height),
                width: anchorRect.width,
                height: anchorRect.height
            )
            panel.setFrameOrigin(NSPoint(x: bottomLeftRect.midX - panel.frame.width / 2, y: bottomLeftRect.midY - panel.frame.height / 2))
        } else if let screen = NSScreen.main {
            let vf = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: vf.midX - panel.frame.width / 2, y: vf.midY - panel.frame.height / 2))
        }
    }
}

@MainActor
private final class CountdownState: ObservableObject {
    @Published var count: Int
    init(count: Int) { self.count = count }
}

private struct CountdownOverlayView: View {
    @ObservedObject var state: CountdownState

    var body: some View {
        Text("\(state.count)")
            .font(.system(size: 42, weight: .semibold))
            .foregroundColor(.white)
            .frame(width: 88, height: 88)
            .id(state.count)
            .transition(.scale(scale: 1.3).combined(with: .opacity))
            .animation(.easeOut(duration: 0.25), value: state.count)
    }
}
