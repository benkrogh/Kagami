import AppKit
import SwiftUI

// MARK: - Click highlight overlay
//
// Draws a translucent ripple wherever the user clicks while recording. Like
// the webcam bubble, this window deliberately keeps the default sharing
// behaviour (no `sharingType = .none`) so ScreenCaptureKit bakes the ripple
// directly into the captured frames instead of it being compositor-only UI.
// The window is click-through and covers exactly the area being recorded —
// the full display for a normal recording, or the selected region for an
// area recording — so clicks outside the capture never draw a ripple.

@MainActor
final class ClickHighlightOverlayWindowManager {
    static let shared = ClickHighlightOverlayWindowManager()
    private init() {}

    private var window: NSWindow?
    private var model = ClickHighlightModel()
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var windowFrame: CGRect = .zero

    var isVisible: Bool { window != nil }

    /// `anchorRect`, when provided, is a top-left-origin global rect (the same
    /// space `AreaSelectorWindow`/`RegionIndicatorWindow` use) describing the
    /// region actually being recorded.
    func show(anchorRect: CGRect? = nil) {
        guard window == nil else { return }

        let frame = Self.resolveFrame(anchorRect: anchorRect)
        windowFrame = frame

        let win = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        win.level = .floating
        win.backgroundColor = .clear
        win.isOpaque = false
        win.hasShadow = false
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let newModel = ClickHighlightModel()
        model = newModel
        let host = NSHostingView(rootView: ClickHighlightCanvas(model: newModel))
        host.frame = NSRect(origin: .zero, size: frame.size)
        win.contentView = host
        win.orderFront(nil)
        window = win

        startMonitoring()
    }

    func hide() {
        stopMonitoring()
        window?.orderOut(nil)
        window = nil
    }

    // MARK: - Monitoring

    private func startMonitoring() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
    }

    private func stopMonitoring() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
    }

    private func handle(_ event: NSEvent) {
        // NSEvent.mouseLocation is in bottom-left-origin screen coordinates,
        // the same space `windowFrame` lives in.
        let global = NSEvent.mouseLocation
        guard windowFrame.contains(global) else { return }

        let local = CGPoint(
            x: global.x - windowFrame.minX,
            y: windowFrame.height - (global.y - windowFrame.minY)
        )
        let color = Color(hex: AppSettings.shared.clickHighlightColor)
        model.addRipple(at: local, color: color, isSecondary: event.type == .rightMouseDown)
    }

    // MARK: - Frame resolution

    private static func resolveFrame(anchorRect: CGRect?) -> CGRect {
        if let anchorRect {
            let primaryH = NSScreen.screens.first?.frame.height ?? 0
            return CGRect(
                x: anchorRect.minX,
                y: primaryH - (anchorRect.minY + anchorRect.height),
                width: anchorRect.width,
                height: anchorRect.height
            )
        }
        let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == CGMainDisplayID()
        }) ?? NSScreen.main ?? NSScreen.screens.first
        return screen?.frame ?? .zero
    }
}

// MARK: - Model

private struct ClickRipple: Identifiable {
    let id = UUID()
    let position: CGPoint
    let color: Color
    let isSecondary: Bool
}

@MainActor
private final class ClickHighlightModel: ObservableObject {
    @Published var ripples: [ClickRipple] = []

    func addRipple(at point: CGPoint, color: Color, isSecondary: Bool = false) {
        ripples.append(ClickRipple(position: point, color: color, isSecondary: isSecondary))
    }

    func remove(_ id: UUID) {
        ripples.removeAll { $0.id == id }
    }
}

// MARK: - Canvas

private struct ClickHighlightCanvas: View {
    @ObservedObject var model: ClickHighlightModel

    var body: some View {
        ZStack {
            ForEach(model.ripples) { ripple in
                RippleView(ripple: ripple) { model.remove(ripple.id) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct RippleView: View {
    let ripple: ClickRipple
    var onFinished: () -> Void

    @State private var animate = false

    private let duration: Double = 0.5
    private let baseSize: CGFloat = 44

    var body: some View {
        ZStack {
            Circle()
                .fill(ripple.color.opacity(animate ? 0 : 0.32))
                .overlay(
                    Circle()
                        .strokeBorder(ripple.color.opacity(animate ? 0 : 0.9), lineWidth: 2.5)
                )
                .frame(width: baseSize, height: baseSize)
                .scaleEffect(animate ? 1.9 : 0.35)

            // Right/secondary clicks get a second, slightly delayed ring so
            // they read as distinct from a plain left click at a glance.
            if ripple.isSecondary {
                Circle()
                    .strokeBorder(ripple.color.opacity(animate ? 0 : 0.6), lineWidth: 2)
                    .frame(width: baseSize, height: baseSize)
                    .scaleEffect(animate ? 2.6 : 0.35)
            }
        }
        .position(ripple.position)
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.easeOut(duration: duration)) {
                animate = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
                onFinished()
            }
        }
    }
}

// MARK: - Hex color helper

extension Color {
    init(hex: String) {
        var sanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        sanitized = sanitized.replacingOccurrences(of: "#", with: "")

        var value: UInt64 = 0
        Scanner(string: sanitized).scanHexInt64(&value)

        let r = Double((value & 0xFF0000) >> 16) / 255
        let g = Double((value & 0x00FF00) >> 8) / 255
        let b = Double(value & 0x0000FF) / 255
        self = Color(red: r, green: g, blue: b)
    }

    /// Round-trips back to the `"#RRGGBB"` form `AppSettings.clickHighlightColor` stores.
    var hexString: String {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
        let r = Int((c.redComponent * 255).rounded())
        let g = Int((c.greenComponent * 255).rounded())
        let b = Int((c.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
