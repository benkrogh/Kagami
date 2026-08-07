import AppKit
import SwiftUI

@MainActor
final class AnnotationEditorWindowManager {
    static let shared = AnnotationEditorWindowManager()
    private init() {}

    private var windows: [UUID: NSWindow] = [:]
    private var delegates: [UUID: DocumentWindowDelegate] = [:]

    var hasOpenWindows: Bool { !windows.isEmpty }

    func openEditor(for image: NSImage, captureItem: CaptureItem? = nil) {
        orderAllBack()

        let id = UUID()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 680),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Kagami — Annotate"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.styleMask.insert(.fullSizeContentView)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.toolbarStyle = .unifiedCompact
        window.minSize = NSSize(width: 600, height: 400)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenPrimary]

        let delegate = DocumentWindowDelegate { [weak self] in
            self?.removeWindow(id: id)
        }
        window.delegate = delegate
        delegates[id] = delegate

        let view = AnnotationEditorView(originalImage: image) { [weak self] _ in
            self?.close(id: id)
        } onDismiss: { [weak self] in
            self?.close(id: id)
        }

        let chromeView = AnnotationEditorChromeView(frame: window.contentView?.bounds ?? .zero)
        let hostingView = NSHostingView(rootView: view)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        chromeView.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: chromeView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: chromeView.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: chromeView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: chromeView.bottomAnchor),
        ])
        window.contentView = chromeView
        window.center()
        windows[id] = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        AppWindowActivation.updateActivationPolicy()
    }

    func orderAllBack() {
        for window in windows.values where window.isVisible {
            window.orderBack(nil)
        }
    }

    private func close(id: UUID) {
        guard let window = windows[id] else { return }
        window.delegate = nil
        delegates.removeValue(forKey: id)
        windows.removeValue(forKey: id)
        window.close()
        AppWindowActivation.updateActivationPolicy()
    }

    private func removeWindow(id: UUID) {
        windows.removeValue(forKey: id)
        delegates.removeValue(forKey: id)
        AppWindowActivation.updateActivationPolicy()
    }
}

// Full-bleed frosted chrome that extends under the title bar traffic lights.
private final class AnnotationEditorChromeView: NSVisualEffectView {
    static let cornerRadius: CGFloat = 18

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .behindWindow
        appearance = NSAppearance(named: .darkAqua)
        state = .active
        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        layer?.cornerRadius = Self.cornerRadius
    }
}
