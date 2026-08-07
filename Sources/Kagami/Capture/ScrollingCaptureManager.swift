import AppKit
import SwiftUI

// MARK: - Scrolling Capture Manager
//
// Scrolling capture. The user selects a region, then scrolls the content
// manually while a small live preview off to the side stitches every
// newly-revealed sliver in real time. On "Done" we compile the final tall PNG.
//
// This type is just the UI + lifecycle layer: a high-frame-rate SCStream
// (`RegionStreamCapturer`) feeds frames to a background `ScrollStitcher` that does
// all the image work off the main thread. The manager only receives finished
// strip images (for the live preview) and the final composed result.

@MainActor
final class ScrollingCaptureManager: ObservableObject {
    static let shared = ScrollingCaptureManager()
    private init() {}

    @Published private(set) var isCapturing = false
    @Published private(set) var frameCount  = 0

    /// Whether auto-scroll is currently driving the content (vs. the user
    /// scrolling by hand). Toggling this never stops/restarts the capture
    /// stream or stitcher — it only starts/pauses the synthetic scroll ticks.
    @Published private(set) var isAutoScrolling = false

    /// Live preview segments (base frame + each appended strip), top-to-bottom.
    @Published private(set) var segments: [ScrollSegment] = []

    /// Total stitched height so far, in points (preview footer readout).
    @Published private(set) var capturedHeightPts: CGFloat = 0

    struct ScrollSegment: Identifiable {
        let id: Int
        let image: NSImage
    }

    // captureRect is in global display POINTS, origin at the TOP-LEFT of the
    // primary display (the space produced by AreaSelectorWindow).
    private var captureRect: CGRect = .zero

    private let capturer = RegionStreamCapturer()
    private var stitcher: ScrollStitcher?
    private var escMonitor: EscapeKeyMonitor?
    private var autoScroller: AutoScroller?

    private var controlsWindow: NSWindow?  = nil
    private var indicatorWindow: NSWindow? = nil
    private var previewWindow: NSWindow?   = nil

    // Frame rate of the capture stream. 30fps keeps each scroll step small (good for
    // accurate matching) while limiting how often we run Vision registration.
    private let streamFPS = 30

    // MARK: - Auto-scroll stall tracking
    //
    // ScreenCaptureKit only delivers a frame when the region's pixels actually
    // change (see RegionStreamCapturer), so once auto-scroll truly runs out of
    // content to reveal, frames simply stop arriving altogether rather than
    // arriving-but-flat. That means "stalled" can't be detected by counting
    // consecutive no-movement *frames* — instead we compare stitched height
    // across checks: if a run of checks in a row produces no new stitched
    // height, the content has reached its bottom.
    //
    // `AutoScroller` ticks at ~60Hz (see its doc) so the capture reads as a
    // smooth continuous scroll — but that's far faster than frames can
    // actually arrive and get registered (stream capture + Vision
    // registration + a main-thread hop). So progress is only sampled on its
    // own slower wall-clock cadence here, independent of the tick rate.
    private var autoScrollHeightAtLastCheck: CGFloat = 0
    private var autoScrollStallChecks = 0
    private var autoScrollLastCheckTime: CFAbsoluteTime = 0
    // How often (seconds) we sample progress, and how many consecutive
    // no-growth samples in a row we tolerate — together giving ~1.2s of
    // grace so a slow frame (Vision registration lag, a lazy-loading
    // spinner, a rubber-band bounce) doesn't end the capture early.
    private let autoScrollCheckInterval: CFAbsoluteTime = 0.3
    private let autoScrollStallThreshold = 4

    // MARK: - Entry point

    func start() {
        guard ScreenCaptureManager.shared.ensureScreenRecordingPermission() else { return }
        AreaSelectorWindowManager.shared.startCapture { [weak self] rect in
            Task { @MainActor in self?.beginCapture(in: rect) }
        }
    }

    private func beginCapture(in rect: CGRect) {
        guard rect.width > 10, rect.height > 10 else { return }
        captureRect = rect
        segments = []
        capturedHeightPts = 0
        frameCount = 0
        isCapturing = true
        isAutoScrolling = false
        autoScroller = nil

        // Overlay windows first, so we have their window numbers to exclude from
        // the capture stream (otherwise the live preview would feed back into it).
        showRegionIndicator()
        showPreview()
        showControls()

        // Esc abandons the in-progress scrolling capture.
        let monitor = EscapeKeyMonitor { [weak self] in self?.cancelCapture() }
        monitor.start()
        escMonitor = monitor

        var exclude: [CGWindowID] = []
        if let c = controlsWindow  { exclude.append(CGWindowID(c.windowNumber)) }
        if let i = indicatorWindow { exclude.append(CGWindowID(i.windowNumber)) }
        if let p = previewWindow   { exclude.append(CGWindowID(p.windowNumber)) }

        let stitcher = ScrollStitcher(regionSize: rect.size) { [weak self] id, image, totalPts, frameCount in
            // Delivered on the main thread by the stitcher.
            guard let self, self.isCapturing else { return }
            self.segments.append(ScrollSegment(id: id, image: image))
            self.capturedHeightPts = totalPts
            self.frameCount = frameCount
        }
        self.stitcher = stitcher

        capturer.onFrame = { cg in stitcher.enqueue(cg) }

        Task {
            let ok = await capturer.start(globalTopLeftRect: captureRect, excludingWindowIDs: exclude, fps: streamFPS)
            if !ok { await MainActor.run { self.cancelCapture() } }
        }
    }

    // MARK: - Stop / Cancel

    func stopCapture() {
        guard isCapturing else { return }
        isCapturing = false
        stopAutoScroll()
        capturer.onFrame = nil
        let stitcher = self.stitcher
        Task { await capturer.stop() }
        teardown()

        stitcher?.finish { [weak self] result, _ in
            self?.stitcher = nil
            guard let result else { return }
            if let item = CaptureStore.shared.saveScreenshot(result) {
                QuickAccessWindowManager.shared.show(for: item)
            }
        }
        resetState()
    }

    func cancelCapture() {
        isCapturing = false
        stopAutoScroll()
        capturer.onFrame = nil
        stitcher?.cancel()
        stitcher = nil
        Task { await capturer.stop() }
        teardown()
        resetState()
    }

    private func resetState() {
        segments = []
        capturedHeightPts = 0
        frameCount = 0
    }

    // MARK: - Auto-scroll

    /// Flips between auto-scroll driving the content and the user scrolling
    /// by hand. Safe to call at any point during a capture; switching back to
    /// manual just pauses the synthetic ticks without touching the stream or
    /// stitcher, so nothing already captured is affected.
    func toggleAutoScroll() {
        if isAutoScrolling {
            pauseAutoScroll()
        } else {
            startAutoScroll()
        }
    }

    private func startAutoScroll() {
        guard isCapturing, !isAutoScrolling else { return }

        // Synthetic input events posted via CGEvent are silently dropped by
        // the window server unless Kagami is trusted for Accessibility —
        // without this check auto-scroll looks like it does nothing at all.
        guard ScreenCaptureManager.shared.ensureAccessibilityPermission(
            reason: "drive Auto-scroll during Scrolling Capture"
        ) else { return }

        let target = autoScroller ?? AutoScroller(targetPoint: CGPoint(x: captureRect.midX, y: captureRect.midY))
        target.onTick = { [weak self] in self?.checkAutoScrollProgress() }
        autoScroller = target

        autoScrollHeightAtLastCheck = capturedHeightPts
        autoScrollStallChecks = 0
        autoScrollLastCheckTime = CFAbsoluteTimeGetCurrent()
        target.start()
        isAutoScrolling = true
    }

    private func pauseAutoScroll() {
        autoScroller?.pause()
        isAutoScrolling = false
    }

    private func stopAutoScroll() {
        autoScroller?.pause()
        autoScroller = nil
        isAutoScrolling = false
        autoScrollStallChecks = 0
    }

    /// Called after every auto-scroll tick (~60Hz — see `AutoScroller`), but
    /// only actually samples progress every `autoScrollCheckInterval`. If
    /// several samples in a row show no growth in the stitched image, the
    /// content has reached its bottom — finish the capture automatically,
    /// same as clicking "Stop & Save".
    private func checkAutoScrollProgress() {
        guard isCapturing, isAutoScrolling else { return }

        let now = CFAbsoluteTimeGetCurrent()
        guard now - autoScrollLastCheckTime >= autoScrollCheckInterval else { return }
        autoScrollLastCheckTime = now

        if capturedHeightPts > autoScrollHeightAtLastCheck {
            autoScrollHeightAtLastCheck = capturedHeightPts
            autoScrollStallChecks = 0
            return
        }

        autoScrollStallChecks += 1
        if autoScrollStallChecks >= autoScrollStallThreshold {
            stopCapture()
        }
    }

    // MARK: - Toolbar + region indicator + live preview

    private func showControls() {
        let panel = makeToolbarPanel(width: 380, height: 52) {
            ScrollingToolbarView(manager: self, onStop: { self.stopCapture() }, onCancel: { self.cancelCapture() })
        }
        panel.sharingType = .none   // never let our own UI bleed into the capture
        elevateForCaptureControls(panel)   // sit above the region shroud, not under it
        positionToolbarPanelCentered(panel)
        panel.orderFront(nil)   // non-activating — don't steal focus from the page
        controlsWindow = panel
    }

    private func showPreview() {
        let width: CGFloat = 260
        let height: CGFloat = 420

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.sharingType = .none   // keep the live preview out of the capture
        elevateForCaptureControls(panel)   // sit above the region shroud, not under it

        let host = NSHostingView(rootView: ScrollingPreviewView(
            manager: self,
            onStop: { self.stopCapture() },
            onCancel: { self.cancelCapture() }
        ))
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        panel.contentView = host

        // Park it against the right edge of the screen the region lives on, away
        // from the capture region so it never overlaps the content being stitched.
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(globalRectInBottomLeft()) }) ?? NSScreen.main {
            let vf = screen.visibleFrame
            let x = vf.maxX - width - 24
            let y = vf.midY - height / 2
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
        panel.orderFront(nil)
        previewWindow = panel
    }

    /// captureRect converted back to a global bottom-left rect (for screen lookup).
    private func globalRectInBottomLeft() -> CGRect {
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        let yBottom = primaryH - (captureRect.minY + captureRect.height)
        return CGRect(x: captureRect.minX, y: yBottom, width: captureRect.width, height: captureRect.height)
    }

    private func showRegionIndicator() {
        let win = RegionIndicatorWindow.make(forTopLeftGlobalRect: captureRect)
        win.orderFront(nil)
        indicatorWindow = win
    }

    private func teardown() {
        escMonitor?.stop()
        escMonitor = nil
        controlsWindow?.orderOut(nil)
        controlsWindow = nil
        indicatorWindow?.orderOut(nil)
        indicatorWindow = nil
        previewWindow?.orderOut(nil)
        previewWindow = nil
    }
}

// MARK: - Live preview window content
//
// Side panel: shows the stitched composite growing in real time and
// auto-scrolls to the newest content so the user can see exactly what has
// been captured (and gauge a comfortable scroll speed).

struct ScrollingPreviewView: View {
    @ObservedObject var manager: ScrollingCaptureManager
    var onStop: () -> Void
    var onCancel: () -> Void

    private let contentWidth: CGFloat = 228

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.08))
            previewStack
            Divider().overlay(Color.white.opacity(0.08))
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ToolbarBlurBackground())
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 20, y: 6)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.3.layers.3d.down.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.85))
            Text("Scrolling Capture")
                .font(.system(.callout, weight: .semibold))
                .foregroundColor(.white)
            Spacer()
            Text("\(Int(manager.capturedHeightPts)) pt")
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.white.opacity(0.5))
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
    }

    private var previewStack: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    ForEach(manager.segments) { seg in
                        Image(nsImage: seg.image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: contentWidth)
                            .id(seg.id)
                    }
                    Color.clear.frame(height: 1).id(-1)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .onChange(of: manager.segments.count) { _ in
                withAnimation(.linear(duration: 0.1)) {
                    proxy.scrollTo(-1, anchor: .bottom)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button(action: { manager.toggleAutoScroll() }) {
                Image(systemName: manager.isAutoScrolling ? "pause.fill" : "play.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white.opacity(0.8))
                    .frame(width: 18, height: 18)
                    .background(Color.white.opacity(0.1))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help(manager.isAutoScrolling ? "Pause Auto-scroll" : "Start Auto-scroll")

            Text(manager.isAutoScrolling ? "Auto-scrolling" : "Scroll to stitch")
                .font(.system(.caption, weight: .medium))
                .foregroundColor(.white.opacity(0.6))

            Spacer()

            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.6))
                    .frame(width: 26, height: 26)
                    .background(Color.white.opacity(0.08))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Cancel")

            Button(action: onStop) {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                    Text("Done")
                        .font(.system(.caption, weight: .semibold))
                }
                .foregroundColor(.black)
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(Color.white)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Finish & Save")
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
    }
}
