import AppKit
import SwiftUI

@MainActor
final class CaptureHistoryWindowManager {
    static let shared = CaptureHistoryWindowManager()
    private init() {}

    private var window: NSWindow?
    private var delegate: DocumentWindowDelegate?

    func open() {
        if let win = window, win.isVisible {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 560),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Kagami — Capture History"
        win.isReleasedWhenClosed = false
        win.collectionBehavior = [.moveToActiveSpace, .fullScreenPrimary]

        let windowDelegate = DocumentWindowDelegate { [weak self] in
            self?.window = nil
            self?.delegate = nil
            AppWindowActivation.updateActivationPolicy()
        }
        win.delegate = windowDelegate
        delegate = windowDelegate

        win.contentView = NSHostingView(rootView: CaptureHistoryView())
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win
        AppWindowActivation.updateActivationPolicy()
    }
}
