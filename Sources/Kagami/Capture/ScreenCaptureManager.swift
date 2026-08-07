import AppKit
import AVFoundation
import ApplicationServices
import ScreenCaptureKit

@MainActor
final class ScreenCaptureManager {
    static let shared = ScreenCaptureManager()
    private init() {}

    // NOTE: All image capture goes through ScreenCaptureKit (SCScreenshotManager).
    // The legacy CGWindowListCreateImage / CGDisplayCreateImage APIs are deprecated
    // and on recent macOS return only the desktop wallpaper (window content is
    // redacted), which is why every capture mode used to grab the background.

    // MARK: - Fullscreen

    func captureFullscreen(screen: NSScreen) async -> NSImage? {
        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return nil }
        return await captureDisplayImage(displayID: displayID)
    }

    // MARK: - Area

    /// `rect` is in global display points with the origin at the TOP-LEFT of the
    /// primary display (the space produced by `AreaSelectorWindow`).
    func captureArea(_ rect: CGRect) async -> NSImage? {
        await captureRegion(globalTopLeftRect: rect, excludingWindowIDs: [])
    }

    /// Same as `captureArea`, but excludes the given windows (e.g. our own toolbar
    /// and region border) from the capture so they never bleed into the frame.
    func captureRegion(globalTopLeftRect rect: CGRect, excludingWindowIDs: [CGWindowID] = []) async -> NSImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

            let center = CGPoint(x: rect.midX, y: rect.midY)
            guard let display = content.displays.first(where: { CGDisplayBounds($0.displayID).contains(center) })
                    ?? content.displays.first(where: { CGDisplayBounds($0.displayID).intersects(rect) })
                    ?? content.displays.first
            else { return nil }

            let bounds = CGDisplayBounds(display.displayID)

            let excluded: [SCWindow] = excludingWindowIDs.isEmpty
                ? []
                : content.windows.filter { excludingWindowIDs.contains($0.windowID) }

            let filter = SCContentFilter(display: display, excludingWindows: excluded)
            let scale  = CGFloat(filter.pointPixelScale)

            let config = SCStreamConfiguration()
            config.width      = max(1, Int(CGFloat(display.width)  * scale))
            config.height     = max(1, Int(CGFloat(display.height) * scale))
            config.showsCursor = false

            let full = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)

            // Crop the full-display image to the requested region (points → pixels).
            let crop = CGRect(
                x: (rect.minX - bounds.minX) * scale,
                y: (rect.minY - bounds.minY) * scale,
                width:  rect.width  * scale,
                height: rect.height * scale
            )
            guard let cropped = full.cropping(to: crop) else {
                return NSImage(cgImage: full, size: CGSize(width: full.width, height: full.height))
            }
            return NSImage(cgImage: cropped, size: rect.size)
        } catch {
            print("captureRegion error: \(error)")
            return nil
        }
    }

    /// Fast region capture for the scrolling-capture loop. Instead of grabbing the
    /// whole display and cropping (expensive, limits frame rate), this asks
    /// ScreenCaptureKit to render only the requested region via `sourceRect`, which
    /// keeps each sample cheap enough to sustain a high frame rate while the user
    /// scrolls. Returns a CGImage at native pixel resolution.
    func captureRegionFast(globalTopLeftRect rect: CGRect, excludingWindowIDs: [CGWindowID] = []) async -> CGImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

            let center = CGPoint(x: rect.midX, y: rect.midY)
            guard let display = content.displays.first(where: { CGDisplayBounds($0.displayID).contains(center) })
                    ?? content.displays.first(where: { CGDisplayBounds($0.displayID).intersects(rect) })
                    ?? content.displays.first
            else { return nil }

            let bounds = CGDisplayBounds(display.displayID)

            let excluded: [SCWindow] = excludingWindowIDs.isEmpty
                ? []
                : content.windows.filter { excludingWindowIDs.contains($0.windowID) }

            let filter = SCContentFilter(display: display, excludingWindows: excluded)
            let scale  = CGFloat(filter.pointPixelScale)

            // sourceRect is in points, relative to the display's top-left origin.
            let local = CGRect(x: rect.minX - bounds.minX,
                               y: rect.minY - bounds.minY,
                               width: rect.width, height: rect.height)

            let config = SCStreamConfiguration()
            config.sourceRect = local
            // Match the output pixel dimensions to the region's aspect so SCK does
            // not letterbox the result.
            config.width      = max(1, Int((rect.width  * scale).rounded()))
            config.height     = max(1, Int((rect.height * scale).rounded()))
            config.showsCursor = false

            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            print("captureRegionFast error: \(error)")
            return nil
        }
    }

    // MARK: - Window

    func captureWindow(windowID: CGWindowID) async -> NSImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else { return nil }

            let filter = SCContentFilter(desktopIndependentWindow: window)
            let scale  = CGFloat(filter.pointPixelScale)

            let config = SCStreamConfiguration()
            config.width      = max(1, Int(filter.contentRect.width  * scale))
            config.height     = max(1, Int(filter.contentRect.height * scale))
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = true

            let cg = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            return NSImage(cgImage: cg, size: filter.contentRect.size)
        } catch {
            print("captureWindow error: \(error)")
            return nil
        }
    }

    // MARK: - Display helper

    private func captureDisplayImage(displayID: CGDirectDisplayID) async -> NSImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == displayID })
                    ?? content.displays.first
            else { return nil }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let scale  = CGFloat(filter.pointPixelScale)

            let config = SCStreamConfiguration()
            config.width      = max(1, Int(CGFloat(display.width)  * scale))
            config.height     = max(1, Int(CGFloat(display.height) * scale))
            config.showsCursor = false

            let cg = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            return NSImage(cgImage: cg, size: CGSize(width: display.width, height: display.height))
        } catch {
            print("captureDisplayImage error: \(error)")
            return nil
        }
    }

    // MARK: - Permission

    /// Non-intrusively reports whether Screen Recording permission is granted.
    /// Unlike attempting a real capture, this never triggers the system prompt,
    /// so it's safe to call before starting a capture flow.
    func hasScreenRecordingPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Registers Kagami in System Settings → Privacy & Security → Screen Recording
    /// and presents the native permission prompt on first use. Returns the current
    /// access state (false until the user grants access).
    @discardableResult
    func requestScreenRecordingPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// Returns true when permission is already granted; otherwise shows a single
    /// guided alert and returns false so callers can abort cleanly instead of
    /// producing a blank (wallpaper-only) capture.
    ///
    /// macOS only applies a newly granted Screen Recording permission to a freshly
    /// launched process, so the alert offers to quit/relaunch Kagami. We do NOT
    /// call CGRequestScreenCaptureAccess() repeatedly — that's what caused the
    /// system prompt to reappear on every attempt.
    func ensureScreenRecordingPermission() -> Bool {
        if hasScreenRecordingPermission() { return true }

        // Register the app with TCC and show the native prompt exactly once per
        // process (the first time the user initiates a capture without access).
        if !Self.didRequestPermission {
            Self.didRequestPermission = true
            requestScreenRecordingPermission()
            return false
        }

        let alert = NSAlert()
        alert.messageText = "Screen Recording Permission Required"
        alert.informativeText = """
        Kagami needs Screen Recording permission to capture your screen instead of just the desktop wallpaper.

        1. Click “Open System Settings” and enable Kagami under Screen Recording.
        2. Quit and reopen Kagami so the new permission takes effect.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Quit Kagami")
        alert.addButton(withTitle: "Cancel")

        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            openPrivacySettings()
        case .alertSecondButtonReturn:
            NSApp.terminate(nil)
        default:
            break
        }
        return false
    }

    private static var didRequestPermission = false

    func openPrivacySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    func ensureMicrophonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            let alert = NSAlert()
            alert.messageText = "Microphone Permission Required"
            alert.informativeText = """
            Kagami needs Microphone access to record audio with your screen recording.

            Open System Settings → Privacy & Security → Microphone and enable Kagami.
            """
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
            }
            return false
        @unknown default:
            return false
        }
    }

    func ensureCameraPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        case .denied, .restricted:
            let alert = NSAlert()
            alert.messageText = "Camera Permission Required"
            alert.informativeText = """
            Kagami needs Camera access to show a webcam overlay during screen recordings.

            Open System Settings → Privacy & Security → Camera and enable Kagami.
            """
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
            }
            return false
        @unknown default:
            return false
        }
    }

    // MARK: - Accessibility (keystroke overlay)

    /// `NSEvent.addGlobalMonitorForEvents` for key events — unlike mouse
    /// events — only delivers anything once the app is trusted for
    /// Accessibility (a different privacy bucket than Screen Recording).
    /// Without this, the keystroke overlay silently sees nothing.
    func hasAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    /// Triggers the native "add to Accessibility" system prompt the first
    /// time it's called for this trust state; macOS also adds a (disabled)
    /// row for Kagami under System Settings even if the prompt doesn't fire.
    @discardableResult
    private func requestAccessibilityPermission() -> Bool {
        let options: [String: Any] = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    /// Returns true when access is already granted. Otherwise fires the
    /// system prompt once per launch, then falls back to a guided alert
    /// (same shape as the other permission gates) so the user can find the
    /// right settings pane. This is a soft dependency — callers should let
    /// the feature continue without whatever needs Accessibility rather
    /// than blocking the whole capture/recording on it.
    ///
    /// - Parameter reason: Short description of what needs the access,
    ///   inserted into "Kagami needs Accessibility access to ‹reason›."
    @discardableResult
    func ensureAccessibilityPermission(reason: String = "show the keystroke overlay while you're recording other apps") -> Bool {
        if hasAccessibilityPermission() { return true }

        if !Self.didRequestAccessibilityPermission {
            Self.didRequestAccessibilityPermission = true
            requestAccessibilityPermission()
            return false
        }

        let alert = NSAlert()
        alert.messageText = "Accessibility Permission Required"
        alert.informativeText = """
        Kagami needs Accessibility access to \(reason).

        Open System Settings → Privacy & Security → Accessibility and enable Kagami, then try again.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
        return false
    }

    private static var didRequestAccessibilityPermission = false

    // MARK: - On-screen window list

    struct WindowInfo: Identifiable {
        var id: CGWindowID
        var title: String
        var ownerName: String
        var ownerPID: pid_t
        var bounds: CGRect
    }

    /// Windows belonging to Kagami itself are excluded — capturing our own
    /// picker (or any other Kagami window) isn't a useful "window capture".
    func onScreenWindows() -> [WindowInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return list.compactMap { info -> WindowInfo? in
            guard let wid    = info[kCGWindowNumber as String] as? CGWindowID,
                  let layer  = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid    = info[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let w = bounds["Width"], let h = bounds["Height"], w > 50, h > 50
            else { return nil }

            let title     = info[kCGWindowName as String] as? String ?? ""
            let ownerName = info[kCGWindowOwnerName as String] as? String ?? ""
            let x         = bounds["X"] ?? 0
            let y         = bounds["Y"] ?? 0
            return WindowInfo(id: wid, title: title, ownerName: ownerName, ownerPID: pid, bounds: CGRect(x: x, y: y, width: w, height: h))
        }
    }
}
