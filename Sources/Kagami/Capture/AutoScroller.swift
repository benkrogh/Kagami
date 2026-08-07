import AppKit

// MARK: - Auto Scroller
//
// Drives Scrolling Capture by itself: synthesizes downward scroll input
// instead of requiring the user to scroll by hand. Events are posted at the
// HID level (`CGEvent.post(tap: .cghidEventTap)`) with an explicit `location`
// inside the capture region, so the target app's normal hit-testing routes
// them to whatever is under the region without moving the user's real cursor
// (beyond the one-time warp in `start()` — see below).
//
// `.pixel` units make this a continuous, trackpad-style scroll (smoother and
// more broadly compatible with JS-driven scroll containers than discrete
// mouse-wheel `.line` clicks). Because we post directly at the CGEvent layer
// — below the driver-level translation that applies the user's "natural
// scrolling" preference to real trackpad hardware — the sign of `stepPixels`
// is a fixed, app-independent convention here, not something that flips with
// that system setting.
//
// A real trackpad delivers on the order of 60-120 small deltas per second,
// which is what makes hardware scrolling look and feel continuous — and,
// just as importantly for `ScrollStitcher`, is what keeps each frame-to-frame
// shift small and steady. Posting a few large jumps per second instead (the
// original approach here) looks visibly jerky, and on pages with their own
// `scroll-behavior: smooth`/JS-driven easing, each jump can retrigger or
// collide with the previous jump's still-settling animation — producing
// erratic per-frame shifts that `ScrollStitcher`'s registration mis-reads as
// skips or overshoots, corrupting the stitched output. So we tick at a fast,
// fixed cadence with a small step instead of a slow cadence with a big one.
@MainActor
final class AutoScroller {
    /// Point every synthetic scroll event targets, in the same top-left
    /// global point space as `captureRect` elsewhere in the scrolling-capture
    /// pipeline — that space matches `CGEvent.location` directly, so no
    /// conversion is needed.
    private let targetPoint: CGPoint
    private let stepPixels: Int32
    private let tickInterval: TimeInterval

    private var timer: Timer?
    private(set) var isRunning = false

    /// Fires on the main thread right after every tick's scroll event is
    /// posted. The capture manager uses this to notice — on its own, much
    /// slower cadence — when ticks stop making any progress (i.e. the
    /// content has reached its bottom); see `tickInterval`'s doc for why that
    /// can't just be "N consecutive ticks" at this tick rate.
    var onTick: (() -> Void)?

    /// - Parameters:
    ///   - stepPixels: Pixels of downward scroll posted per tick. Kept small
    ///     (real trackpad hardware often reports single-digit deltas) so the
    ///     motion reads as continuous rather than stepped — the tick rate,
    ///     not this value, is what should stay small for smoothness. At the
    ///     default 60Hz this is ~540pt/sec overall, which still lands each
    ///     30fps captured frame well under `ScrollStitcher`'s 45%-of-height
    ///     trust ceiling for any capture region of normal size, leaving
    ///     plenty of headroom before registration quality would suffer.
    ///   - tickInterval: Seconds between ticks. ~60Hz matches real trackpad
    ///     hardware and stays comfortably above display refresh perception,
    ///     so consecutive small steps blend into one smooth motion instead of
    ///     visible stutter.
    init(targetPoint: CGPoint, stepPixels: Int32 = 9, tickInterval: TimeInterval = 1.0 / 60.0) {
        self.targetPoint = targetPoint
        self.stepPixels = stepPixels
        self.tickInterval = tickInterval
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true

        // Scroll-wheel HID events carry no position payload of their own —
        // unlike mouseMoved/click events, setting `.location` on the event
        // object does NOT redirect where it lands. The window server always
        // routes them to whatever is under the REAL pointer, so we have to
        // actually move the pointer there first (once per start/resume, not
        // per tick, so the user can still move the mouse to hit Pause/Stop
        // without fighting us).
        CGWarpMouseCursorPosition(targetPoint)

        let t = Timer(timeInterval: tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        // Don't wait a full interval before the first step.
        tick()
    }

    func pause() {
        isRunning = false
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard isRunning else { return }
        postScroll(deltaY: -stepPixels)
        onTick?()
    }

    /// Posts one synthetic scroll-wheel event. Negative `deltaY` scrolls the
    /// page down (reveals content below — what a scrolling capture wants);
    /// positive would scroll back up.
    private func postScroll(deltaY: Int32) {
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 1,
            wheel1: deltaY,
            wheel2: 0,
            wheel3: 0
        ) else { return }
        event.location = targetPoint
        event.post(tap: .cghidEventTap)
    }
}
