import AppKit

// main.swift entry point runs on the main thread — use assumeIsolated to create
// the @MainActor-isolated AppDelegate safely without requiring async context.
nonisolated(unsafe) let _appDelegate: AppDelegate = MainActor.assumeIsolated {
    NSApplication.shared.setActivationPolicy(.accessory)
    return AppDelegate()
}

NSApplication.shared.delegate = _appDelegate
NSApplication.shared.run()
