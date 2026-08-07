import AppKit
import SwiftUI

// MARK: - Keystroke overlay
//
// A single dynamic "keycap" pill, bottom-centre of the recorded area, that
// shows what's being typed. Plain characters (and space) coalesce into one
// growing bubble like a live transcript; shortcuts and non-character keys
// (⌘C, Return, arrows, …) flash as their own combo label. Only one thing is
// ever on screen at a time — deliberately simple, like Screen Studio's
// keystroke effect, rather than a stacked history log.
//
// Same sharing trick as the webcam bubble and click-highlight overlay: the
// window keeps its default sharingType so ScreenCaptureKit bakes the pill
// into the recording instead of it being local-only UI chrome.

@MainActor
final class KeystrokeOverlayWindowManager {
    static let shared = KeystrokeOverlayWindowManager()
    private init() {}

    /// Max pill width; height fits one line of monospaced body text + padding.
    private static let contentSize = CGSize(width: 460, height: 50)
    /// Room for the SwiftUI `.shadow()` to diffuse inside the window frame
    /// (same trick as the webcam bubble — AppKit clips at the window edge).
    private static let shadowInset: CGFloat = 24
    private static let margin: CGFloat = 28

    private static var panelSize: CGSize {
        CGSize(
            width: contentSize.width + shadowInset * 2,
            height: contentSize.height + shadowInset * 2
        )
    }

    private var window: NSWindow?
    private var model = KeystrokeHUDModel()
    private var localMonitor: Any?
    private var globalMonitor: Any?

    var isVisible: Bool { window != nil }

    /// `anchorRect`, when provided, is a top-left-origin global rect (the same
    /// space `AreaSelectorWindow`/`RegionIndicatorWindow` use) describing the
    /// region actually being recorded.
    func show(anchorRect: CGRect? = nil) {
        guard window == nil else { return }

        let frame = Self.resolveFrame(anchorRect: anchorRect)

        let win = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        win.level = .floating
        win.backgroundColor = .clear
        win.isOpaque = false
        win.hasShadow = false
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let newModel = KeystrokeHUDModel()
        model = newModel
        let host = NSHostingView(rootView: KeystrokeHUDView(model: newModel, shadowInset: Self.shadowInset))
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
        model.reset()
    }

    // MARK: - Monitoring

    private func startMonitoring() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.model.handle(event)
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.model.handle(event) }
        }
    }

    private func stopMonitoring() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
    }

    // MARK: - Frame resolution

    private static func resolveFrame(anchorRect: CGRect?) -> CGRect {
        let size = panelSize
        if let anchorRect {
            let primaryH = NSScreen.screens.first?.frame.height ?? 0
            let bottomLeftRect = CGRect(
                x: anchorRect.minX,
                y: primaryH - (anchorRect.minY + anchorRect.height),
                width: anchorRect.width,
                height: anchorRect.height
            )
            var originX = bottomLeftRect.midX - size.width / 2
            originX = max(bottomLeftRect.minX, min(originX, bottomLeftRect.maxX - size.width))
            let originY = bottomLeftRect.minY + margin - shadowInset
            return CGRect(origin: CGPoint(x: originX, y: originY), size: size)
        }
        let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == CGMainDisplayID()
        }) ?? NSScreen.main ?? NSScreen.screens.first
        let vf = screen?.visibleFrame ?? .zero
        let originX = vf.midX - size.width / 2
        let originY = vf.minY + margin - shadowInset
        return CGRect(origin: CGPoint(x: originX, y: originY), size: size)
    }
}

// MARK: - Model

@MainActor
private final class KeystrokeHUDModel: ObservableObject {
    @Published private(set) var text: String = ""
    @Published private(set) var isVisible: Bool = false

    private var isTypingBuffer = false
    private var dismissWorkItem: DispatchWorkItem?

    private static let maxBufferLength = 26
    private static let dismissDelay: TimeInterval = 1.3

    func handle(_ event: NSEvent) {
        guard let description = Self.describe(event) else { return }

        switch description {
        case .character(let char):
            if isTypingBuffer, isVisible {
                text += char
                if text.count > Self.maxBufferLength {
                    text.removeFirst(text.count - Self.maxBufferLength)
                }
            } else {
                text = char
                isTypingBuffer = true
            }

        case .backspace:
            if isTypingBuffer, isVisible, !text.isEmpty {
                text.removeLast()
                if text.isEmpty { isTypingBuffer = false }
            } else {
                text = "⌫"
                isTypingBuffer = false
            }

        case .combo(let label):
            // A repeated key-repeat of the same combo just refreshes the
            // dismiss timer below instead of stacking duplicate labels.
            if !(isVisible && !isTypingBuffer && text == label) {
                text = label
                isTypingBuffer = false
            }
        }

        isVisible = !text.isEmpty
        scheduleDismiss()
    }

    func reset() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        isVisible = false
        isTypingBuffer = false
        text = ""
    }

    private func scheduleDismiss() {
        dismissWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.isVisible = false
            self?.isTypingBuffer = false
        }
        dismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.dismissDelay, execute: work)
    }

    // MARK: - Key description

    private enum KeyDescription {
        case character(String)
        case backspace
        case combo(String)
    }

    /// Non-character keys with fixed, layout-independent key codes. Any of
    /// these always renders as its own combo chip rather than merging into
    /// the typing buffer.
    private static let specialGlyphs: [UInt16: String] = [
        36: "↩", 76: "⌤",              // Return, Keypad Enter
        48: "⇥",                       // Tab
        53: "⎋",                       // Escape
        123: "←", 124: "→", 125: "↓", 126: "↑",
        116: "⇞", 121: "⇟",            // Page Up / Down
        115: "↖", 119: "↘",            // Home / End
        117: "⌦",                      // Forward Delete
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"
    ]

    private static func describe(_ event: NSEvent) -> KeyDescription? {
        if event.keyCode == 51 { return .backspace }

        let combiningModifiers: NSEvent.ModifierFlags = [.command, .control, .option]
        let hasCombiningModifier = !event.modifierFlags.intersection(combiningModifiers).isEmpty
        let special = specialGlyphs[event.keyCode]

        if special == nil, !hasCombiningModifier {
            guard let chars = event.characters, !chars.isEmpty,
                  chars.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F })
            else { return nil }
            return .character(chars)
        }

        var prefix = ""
        if event.modifierFlags.contains(.control) { prefix += "⌃" }
        if event.modifierFlags.contains(.option)  { prefix += "⌥" }
        if event.modifierFlags.contains(.shift)   { prefix += "⇧" }
        if event.modifierFlags.contains(.command) { prefix += "⌘" }

        let base: String
        if let special {
            base = special
        } else if let chars = event.charactersIgnoringModifiers, !chars.isEmpty {
            base = chars.uppercased()
        } else {
            return nil
        }
        return .combo(prefix + base)
    }
}

// MARK: - View

private struct KeystrokeHUDView: View {
    @ObservedObject var model: KeystrokeHUDModel
    var shadowInset: CGFloat

    var body: some View {
        ZStack(alignment: .bottom) {
            if model.isVisible {
                Text(model.text)
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(KeystrokeBlurBackground())
                    .clipShape(Capsule())
                    .shadow(color: .black.opacity(0.35), radius: 14, y: 5)
                    .fixedSize()
                    .transition(.scale(scale: 0.85, anchor: .bottom).combined(with: .opacity))
            }
        }
        .padding(shadowInset)
        .animation(.easeOut(duration: 0.18), value: model.text)
        .animation(.easeOut(duration: 0.22), value: model.isVisible)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }
}

/// NSVisualEffectView wrapper — same dark ultra-thin material as the recording toolbar.
private struct KeystrokeBlurBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.appearance = NSAppearance(named: .darkAqua)
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}
