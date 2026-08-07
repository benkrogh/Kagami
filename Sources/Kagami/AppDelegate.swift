import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private(set) var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        CaptureStore.shared.setup()
        menuBarController = MenuBarController()
        // NOTE: We intentionally do NOT request Screen Recording permission here.
        // Doing so re-fires the system prompt on every launch (the grant only
        // activates after a relaunch). Permission is requested lazily, once, the
        // first time the user actually starts a capture.
    }

    func applicationWillTerminate(_ notification: Notification) {
        GlobalHotkeyManager.shared.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
