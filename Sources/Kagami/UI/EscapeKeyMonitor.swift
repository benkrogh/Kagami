import AppKit

/// Watches for the Escape key while a capture/recording session is in flight and
/// invokes a cancel handler.
///
/// Capture overlays and toolbars are often *non-activating* (so they never steal
/// keyboard focus from the content being captured), which means SwiftUI's
/// `keyboardShortcut(.escape)` won't fire. This monitor closes that gap:
///   • a **local** monitor catches Escape while one of our own windows is focused
///   • a **global** monitor catches Escape while another app is focused
///
/// Global keyboard monitoring requires the app to be trusted for Input Monitoring /
/// Accessibility; if that permission isn't granted, Escape still works whenever one
/// of our windows has focus via the local monitor.
@MainActor
final class EscapeKeyMonitor {
    private static let escapeKeyCode: UInt16 = 53

    private var localMonitor: Any?
    private var globalMonitor: Any?
    private let onEscape: () -> Void

    init(onEscape: @escaping () -> Void) {
        self.onEscape = onEscape
    }

    func start() {
        stop()

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == Self.escapeKeyCode else { return event }
            self.onEscape()
            return nil   // swallow so it doesn't beep
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == Self.escapeKeyCode else { return }
            MainActor.assumeIsolated { self?.onEscape() }
        }
    }

    func stop() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
    }

    deinit {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
    }
}
