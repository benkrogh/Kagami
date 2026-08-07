import AppKit
import SwiftUI

// MARK: - Shared toolbar window

/// Creates the minimal pill-shaped floating toolbar used for recordings and scrolling capture.
/// Transparent margin kept around the pill so the SwiftUI drop-shadow can render
/// inside the window instead of relying on the AppKit window shadow (which macOS
/// draws as a rectangular ghost outline on borderless transparent panels).
/// Sized generously (shadow radius 20 + y-offset 6 needs ~40pt of falloff room)
/// so the shadow fades out naturally instead of getting hard-clipped at the
/// invisible window edge.
let toolbarShadowInset: CGFloat = 44

/// Capture control panels (record/stop toolbar) must sit above the region
/// border overlay, which uses the screen-saver window level.
let captureControlsWindowLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)) + 1)

@MainActor
func elevateForCaptureControls(_ panel: NSPanel) {
    panel.level = captureControlsWindowLevel
}

@MainActor
func makeToolbarPanel<Content: View>(width: CGFloat = 340, height: CGFloat = 52, @ViewBuilder content: () -> Content) -> NSPanel {
    makeFloatingPanel(width: width, height: height, cornerRadius: nil, content: content)
}

/// Rounded floating panel — same blur/shadow treatment as the toolbar pill, for setup sheets.
@MainActor
func makeFloatingPanel<Content: View>(
    width: CGFloat,
    height: CGFloat,
    cornerRadius: CGFloat? = 20,
    @ViewBuilder content: () -> Content
) -> NSPanel {
    let frameWidth  = width  + toolbarShadowInset * 2
    let frameHeight = height + toolbarShadowInset * 2

    let panel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: frameWidth, height: frameHeight),
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
    )
    panel.level          = .floating
    panel.isOpaque       = false
    panel.backgroundColor = .clear
    panel.hasShadow      = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.isMovableByWindowBackground = true
    panel.sharingType    = .none

    let host = NSHostingView(rootView: KagamiToolbarShell(inset: toolbarShadowInset, cornerRadius: cornerRadius, content: content()))
    host.frame = NSRect(x: 0, y: 0, width: frameWidth, height: frameHeight)
    panel.contentView = host
    return panel
}

/// Positions a panel at the bottom-centre of the primary screen (above Dock).
@MainActor
func positionToolbarPanelCentered(_ panel: NSPanel, yOffset: CGFloat = 32) {
    guard let screen = NSScreen.main else { return }
    positionToolbarPanelCentered(panel, on: screen, yOffset: yOffset)
}

@MainActor
func positionToolbarPanelCentered(_ panel: NSPanel, on screen: NSScreen, yOffset: CGFloat = 32) {
    let sv = screen.visibleFrame
    let x  = sv.midX - panel.frame.width / 2
    let y  = sv.minY + yOffset - toolbarShadowInset
    panel.setFrameOrigin(NSPoint(x: x, y: y))
}

/// Positions a capture toolbar on the screen that contains `captureRect`, keeping
/// it outside the selected region when the default bottom-centre spot would overlap.
/// `captureRect` uses top-left global coordinates (AreaSelector space).
@MainActor
func positionToolbarPanelForCapture(_ panel: NSPanel, captureRect: CGRect, yOffset: CGFloat = 32) {
    let primaryH = NSScreen.screens.first?.frame.height ?? 0
    let rectBottomLeft = CGRect(
        x: captureRect.minX,
        y: primaryH - (captureRect.minY + captureRect.height),
        width: captureRect.width,
        height: captureRect.height
    )

    let screen = NSScreen.screens.first { $0.frame.intersects(rectBottomLeft) } ?? NSScreen.main
    guard let screen else { return }

    let vf = screen.visibleFrame
    var x = vf.midX - panel.frame.width / 2
    var y = vf.minY + yOffset - toolbarShadowInset

    let toolbarFrame = { CGRect(x: x, y: y, width: panel.frame.width, height: panel.frame.height) }

    if toolbarFrame().intersects(rectBottomLeft) {
        let aboveY = rectBottomLeft.maxY + 12
        if aboveY + panel.frame.height <= vf.maxY {
            y = aboveY
        } else {
            let belowY = rectBottomLeft.minY - panel.frame.height - 12
            y = max(vf.minY, belowY)
        }
        x = min(max(x, vf.minX), vf.maxX - panel.frame.width)
    }

    panel.setFrameOrigin(NSPoint(x: x, y: y))
}

// MARK: - Shell with blur + pill shape

struct KagamiToolbarShell<Content: View>: View {
    var inset: CGFloat = 0
    /// `nil` → capsule pill; a value → rounded rectangle (setup panels).
    var cornerRadius: CGFloat? = nil
    let content: Content

    var body: some View {
        Group {
            if let r = cornerRadius {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(ToolbarBlurBackground())
                    .clipShape(RoundedRectangle(cornerRadius: r, style: .continuous))
            } else {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(ToolbarBlurBackground())
                    .clipShape(Capsule())
            }
        }
        .shadow(color: .black.opacity(0.4), radius: 20, y: 6)
        .padding(inset)
    }
}

/// NSVisualEffectView wrapper — dark ultra-thin material
struct ToolbarBlurBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material    = .hudWindow
        v.blendingMode = .behindWindow
        v.appearance  = NSAppearance(named: .darkAqua)
        v.state       = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

// MARK: - Area selection hint

/// Small pill shown above the dimmed selection overlay to explain what
/// dragging out a region will do (currently used for text recognition).
struct AreaSelectionHintView: View {
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "text.viewfinder")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white.opacity(0.85))
            Text(text)
                .font(.system(.callout, weight: .medium))
                .foregroundColor(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 18)
        .frame(maxHeight: .infinity)
    }
}

// MARK: - Area recording ready toolbar

struct AreaRecordingReadyView: View {
    var onRecord: () -> Void
    var onCancel: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Button(action: onRecord) {
                HStack(spacing: 6) {
                    Image(systemName: "record.circle")
                        .font(.system(size: 12, weight: .bold))
                    Text("Click to Record")
                        .font(.system(.callout, weight: .semibold))
                }
                .foregroundColor(.black)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Color.white)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return)

            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color.white.opacity(0.55))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape)
            .help("Cancel")
        }
        .padding(.horizontal, 18)
        .frame(maxHeight: .infinity)
    }
}

// MARK: - Recording toolbar content

struct RecordingToolbarView: View {
    @ObservedObject var recorder = ScreenRecordingManager.shared
    @ObservedObject var webcam = WebcamRecordingController.shared
    var onStop: () -> Void
    var onDiscard: () -> Void

    @State private var isPaused = false

    // Pulse animation via a timer-driven state
    @State private var pulseOpacity: Double = 1.0

    var body: some View {
        HStack(spacing: 10) {
            // Red dot + timer (or purple dot + countdown, for GIF recordings)
            HStack(spacing: 6) {
                Circle()
                    .fill(isPaused ? Color.orange : (recorder.recordingKind == .gif ? Color.purple : Color.red))
                    .frame(width: 8, height: 8)
                    .opacity(isPaused ? 1 : pulseOpacity)
                    .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulseOpacity)

                if recorder.recordingKind == .gif {
                    Text("GIF")
                        .font(.system(.caption2, weight: .bold))
                        .foregroundColor(.white.opacity(0.6))
                    Text(recorder.formattedGifRemaining)
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                        .foregroundColor(.white)
                        .frame(minWidth: 32, alignment: .leading)
                        .help("Time left before this GIF auto-stops")
                } else {
                    Text(recorder.formattedElapsed)
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                        .foregroundColor(.white)
                        .frame(minWidth: 40, alignment: .leading)
                }
            }

            // Grouped icon-button pill — same rounded-rect language as the
            // record-setup panel's option row, with Stop styled as the
            // "active" (white) state to read as the primary action.
            optionGroup {
                toolbarButton(icon: isPaused ? "play.fill" : "pause.fill", help: isPaused ? "Resume" : "Pause") {
                    isPaused.toggle()
                }

                if webcam.isEnabledForSession {
                    toolbarButton(
                        icon: webcam.isVisible ? "video.fill" : "video.slash.fill",
                        help: webcam.isVisible ? "Hide Webcam" : "Show Webcam"
                    ) {
                        webcam.toggleVisibility()
                    }
                }

                toolbarButton(icon: "stop.fill", help: "Stop & Save", isPrimary: true, action: onStop)
            }

            Button(action: onDiscard) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color.white.opacity(0.55))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("Discard Recording")
        }
        .padding(.horizontal, 14)
        .frame(maxHeight: .infinity)
    }

    /// Rounded-rect grouping for related icon toggles — same language as the record-setup panel.
    private func optionGroup<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 4) {
            content()
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func toolbarButton(icon: String, help: String, isPrimary: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isPrimary ? Color.black : Color.white.opacity(0.85))
                .frame(width: 34, height: 34)
                .background(isPrimary ? Color.white : Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .frame(width: 40, height: 40)
        .contentShape(Rectangle())
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Scrolling capture toolbar content

struct ScrollingToolbarView: View {
    @ObservedObject var manager = ScrollingCaptureManager.shared
    var onStop: () -> Void
    var onCancel: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            // Auto/manual toggle + scroll hint + captured-frame count
            HStack(spacing: 8) {
                Button(action: { manager.toggleAutoScroll() }) {
                    Image(systemName: manager.isAutoScrolling ? "pause.fill" : "play.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white.opacity(0.85))
                        .frame(width: 22, height: 22)
                        .background(Color.white.opacity(0.1))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help(manager.isAutoScrolling ? "Pause Auto-scroll" : "Start Auto-scroll")

                Text(manager.isAutoScrolling ? "Auto-scrolling" : "Scroll to capture")
                    .font(.system(.callout, weight: .medium))
                    .foregroundColor(.white)
                Text("· \(manager.frameCount)")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundColor(.white.opacity(0.55))
                    .frame(minWidth: 24, alignment: .leading)
            }

            Divider().frame(height: 22).background(Color.white.opacity(0.2))

            // Stop & Save
            Button(action: onStop) {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                    Text("Stop & Save")
                        .font(.system(.callout, weight: .semibold))
                }
                .foregroundColor(.black)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.white)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return)

            // Cancel
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color.white.opacity(0.55))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape)
            .help("Cancel")
        }
        .padding(.horizontal, 18)
        .frame(maxHeight: .infinity)
    }
}
