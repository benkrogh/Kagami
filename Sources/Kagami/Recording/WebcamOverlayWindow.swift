import AppKit
import SwiftUI

// MARK: - Webcam bubble window
//
// A real floating panel that shows the live camera feed on top of everything
// else. Unlike the recording toolbars (which set `sharingType = .none` so
// they never appear in captures), this panel deliberately keeps the default
// sharing behaviour — that's what lets ScreenCaptureKit "bake" the bubble
// into the screen recording, instead of compositing pixels manually.

@MainActor
final class WebcamOverlayWindowManager {
    static let shared = WebcamOverlayWindowManager()
    private init() {}

    /// The SwiftUI `.shadow()` on the bubble blurs *outside* its own bounds.
    /// AppKit clips window content to the window's frame, so without this
    /// margin the blur got cut off in a hard square around the circular
    /// bubble. Sizing the window `bubbleSize + inset*2` and padding the
    /// content by `inset` gives the blur room to actually diffuse.
    private static let shadowInset: CGFloat = 24

    private var panel: NSPanel?
    private var dragStartSize: CGFloat = 0

    var isVisible: Bool { panel != nil }

    /// `anchorRect`, when provided, is a top-left-origin global rect (the same
    /// space `AreaSelectorWindow`/`RegionIndicatorWindow` use) describing the
    /// region actually being recorded. When set, the bubble is anchored inside
    /// that region so it's never cropped out of an area recording.
    func show(anchorRect: CGRect? = nil) {
        guard panel == nil else { return }

        let bubbleSize = AppSettings.shared.webcamBubbleSize
        let frameSize = bubbleSize + Self.shadowInset * 2

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: frameSize, height: frameSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false // shadow is drawn in SwiftUI so it stays circular, see KagamiToolbarShell precedent
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.ignoresMouseEvents = false

        let host = NSHostingView(rootView: WebcamBubbleView(
            onBeginResize: { [weak self] in
                self?.dragStartSize = AppSettings.shared.webcamBubbleSize
            },
            onResize: { [weak self] delta in
                self?.applyResize(delta: delta)
            },
            onResizeEnded: {
                AppSettings.shared.saveAll()
            }
        )
        .padding(Self.shadowInset))
        host.frame = NSRect(origin: .zero, size: CGSize(width: frameSize, height: frameSize))
        panel.contentView = host

        positionPanel(panel, bubbleSize: bubbleSize, anchorRect: anchorRect)
        panel.orderFront(nil)
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }

    // MARK: - Positioning

    private func positionPanel(_ panel: NSPanel, bubbleSize: CGFloat, anchorRect: CGRect?) {
        let margin: CGFloat = 24
        let inset = Self.shadowInset

        if let anchorRect {
            let primaryH = NSScreen.screens.first?.frame.height ?? 0
            let bottomLeftRect = CGRect(
                x: anchorRect.minX,
                y: primaryH - (anchorRect.minY + anchorRect.height),
                width: anchorRect.width,
                height: anchorRect.height
            )
            let clampedSize = min(bubbleSize, min(bottomLeftRect.width, bottomLeftRect.height) - margin * 2)
            let bubbleX = bottomLeftRect.maxX - max(clampedSize, 80) - margin
            let bubbleY = bottomLeftRect.minY + margin
            panel.setFrameOrigin(NSPoint(x: bubbleX - inset, y: bubbleY - inset))
        } else {
            guard let screen = NSScreen.main else { return }
            let vf = screen.visibleFrame
            let bubbleX = vf.maxX - bubbleSize - margin
            let bubbleY = vf.minY + margin
            panel.setFrameOrigin(NSPoint(x: bubbleX - inset, y: bubbleY - inset))
        }
    }

    // MARK: - Resizing

    private func applyResize(delta: CGFloat) {
        guard let panel else { return }
        let newBubbleSize = min(max(dragStartSize + delta, 120), 360)
        let newFrameSize = newBubbleSize + Self.shadowInset * 2

        let oldFrame = panel.frame
        let center = CGPoint(x: oldFrame.midX, y: oldFrame.midY)
        let newFrame = CGRect(
            x: center.x - newFrameSize / 2,
            y: center.y - newFrameSize / 2,
            width: newFrameSize,
            height: newFrameSize
        )
        panel.setFrame(newFrame, display: true)
        AppSettings.shared.webcamBubbleSize = newBubbleSize
    }
}

// MARK: - Bubble content

struct WebcamBubbleView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var webcam = WebcamCaptureManager.shared

    var onBeginResize: () -> Void
    var onResize: (CGFloat) -> Void
    var onResizeEnded: () -> Void

    @State private var isHovering = false
    @State private var isResizing = false

    var body: some View {
        ZStack {
            WebcamPreviewView(session: webcam.session, mirrored: settings.webcamMirrored)
                .clipShape(clipShape)

            clipShape
                .stroke(Color.white.opacity(0.85), lineWidth: 3)
        }
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
        .contentShape(clipShape)
        .overlay(alignment: .bottomTrailing) {
            if isHovering {
                resizeHandle
                    .padding(8)
            }
        }
        .onHover { isHovering = $0 }
        .contextMenu {
            Toggle("Mirror Video", isOn: $settings.webcamMirrored)
            Picker("Shape", selection: $settings.webcamShape) {
                ForEach(AppSettings.WebcamShape.allCases, id: \.self) { shape in
                    Text(shape.displayName).tag(shape)
                }
            }
            if webcam.availableDevices.count > 1 {
                Menu("Camera") {
                    ForEach(webcam.availableDevices, id: \.uniqueID) { device in
                        Button {
                            webcam.switchDevice(to: device.uniqueID)
                        } label: {
                            if device.uniqueID == webcam.selectedDeviceID {
                                Label(device.localizedName, systemImage: "checkmark")
                            } else {
                                Text(device.localizedName)
                            }
                        }
                    }
                }
            }
        }
        .onChange(of: settings.webcamMirrored) { _, _ in settings.saveAll() }
        .onChange(of: settings.webcamShape) { _, _ in settings.saveAll() }
        .frame(width: settings.webcamBubbleSize, height: settings.webcamBubbleSize)
    }

    private var clipShape: AnyShape {
        switch settings.webcamShape {
        case .circle:        return AnyShape(Circle())
        case .roundedSquare: return AnyShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
    }

    private var resizeHandle: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(.white)
            .frame(width: 22, height: 22)
            .background(Color.black.opacity(0.55))
            .clipShape(Circle())
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { value in
                        if !isResizing {
                            isResizing = true
                            onBeginResize()
                        }
                        let delta = max(value.translation.width, value.translation.height)
                        onResize(delta)
                    }
                    .onEnded { _ in
                        isResizing = false
                        onResizeEnded()
                    }
            )
    }
}
