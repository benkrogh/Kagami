import AppKit
import SwiftUI

@MainActor
final class MenuBarController: NSObject {
    private var statusItem: NSStatusItem
    private var recordingStatusItem: NSStatusItem?
    private var recordingTimer: Timer?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configure()
    }

    deinit {
        recordingTimer?.invalidate()
    }

    // MARK: - Setup

    private func configure() {
        guard let button = statusItem.button else { return }
        if let icon = Self.loadMenuBarIcon() {
            button.image = icon
        } else {
            button.image = NSImage(systemSymbolName: "camera.on.rectangle", accessibilityDescription: "Kagami")
            button.image?.isTemplate = true
        }
        statusItem.menu = buildMenu()
        registerGlobalHotkeys()
    }

    private func registerGlobalHotkeys() {
        GlobalHotkeyManager.shared.start { [weak self] action in
            guard let self else { return }
            switch action {
            case .captureArea:       self.captureArea()
            case .captureWindow:     self.captureWindow()
            case .captureFullscreen: self.captureFullscreen()
            case .startRecording:    self.startOrStopRecording()
            case .scrollingCapture:  self.scrollingCapture()
            case .textRecognition:   self.textRecognition()
            case .openHistory:       self.openHistory()
            }
        }
    }

    private static func loadMenuBarIcon() -> NSImage? {
        let subdirs: [String?] = ["Images", nil]
        let bundles = [ResourceBundle.assets, Bundle.main]

        for bundle in bundles {
            for subdir in subdirs {
                guard let url = bundle.url(forResource: "menubar-icon", withExtension: "svg", subdirectory: subdir),
                      let image = NSImage(contentsOf: url) else { continue }
                image.size = NSSize(width: 18, height: 14)
                image.isTemplate = true
                return image
            }
        }
        return nil
    }

    // MARK: - Menu

    func buildMenu() -> NSMenu {
        let menu = NSMenu()

        // --- Screenshots ---
        menu.addItem(sectionHeader("CAPTURE"))

        menu.addItem(hotkeyMenuItem("Capture Area",       action: #selector(captureArea),        .captureArea))
        menu.addItem(hotkeyMenuItem("Capture Window",     action: #selector(captureWindow),      .captureWindow))
        menu.addItem(hotkeyMenuItem("Capture Fullscreen", action: #selector(captureFullscreen),  .captureFullscreen))
        menu.addItem(hotkeyMenuItem("Scrolling Capture",  action: #selector(scrollingCapture),   .scrollingCapture))

        menu.addItem(.separator())

        // --- Recording ---
        menu.addItem(sectionHeader("RECORD"))

        let recItem = hotkeyMenuItem("Start Recording", action: #selector(startOrStopRecording), .startRecording)
        recItem.tag = 100
        menu.addItem(recItem)

        menu.addItem(.separator())

        // --- Tools ---
        menu.addItem(sectionHeader("TOOLS"))

        menu.addItem(hotkeyMenuItem("Text Recognition (OCR)", action: #selector(textRecognition), .textRecognition))
        menu.addItem(menuItem("Pin Screenshot",         action: #selector(pinScreenshot),   key: ""))
        menu.addItem(menuItem("Hide Desktop Icons",     action: #selector(toggleDesktopIcons), key: ""))

        menu.addItem(.separator())

        // --- App ---
        menu.addItem(hotkeyMenuItem("Capture History", action: #selector(openHistory), .openHistory))
        menu.addItem(menuItem("Settings…",       action: #selector(openSettings), key: ",", modifiers: .command))

        menu.addItem(.separator())
        menu.addItem(menuItem("Quit Kagami", action: #selector(quitApp), key: "q", modifiers: .command))

        return menu
    }

    private func sectionHeader(_ title: String) -> NSMenuItem {
        let item = NSMenuItem()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        item.attributedTitle = NSAttributedString(string: title, attributes: attrs)
        item.isEnabled = false
        return item
    }

    private func menuItem(_ title: String, action: Selector, key: String, modifiers: NSEvent.ModifierFlags = []) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    private func hotkeyMenuItem(_ title: String, action: Selector, _ hotkey: GlobalHotkeyManager.Action) -> NSMenuItem {
        guard let shortcut = GlobalHotkeyManager.Shortcut.shortcut(for: hotkey) else {
            return menuItem(title, action: action, key: "")
        }
        return menuItem(title, action: action, key: shortcut.keyEquivalent, modifiers: shortcut.modifierFlags)
    }

    // MARK: - Screenshot Actions

    @objc private func captureArea() {
        guard ScreenCaptureManager.shared.ensureScreenRecordingPermission() else { return }
        delayAndCapture {
            AreaSelectorWindowManager.shared.startCapture { rect in
                Task { @MainActor in
                    guard let image = await ScreenCaptureManager.shared.captureArea(rect) else { return }
                    self.handleCapture(image)
                }
            }
        }
    }

    @objc private func captureWindow() {
        guard ScreenCaptureManager.shared.ensureScreenRecordingPermission() else { return }
        delayAndCapture {
            // Show window picker overlay
            WindowPickerWindowManager.shared.show { windowID in
                Task { @MainActor in
                    guard let image = await ScreenCaptureManager.shared.captureWindow(windowID: windowID) else { return }
                    self.handleCapture(image)
                }
            }
        }
    }

    @objc private func captureFullscreen() {
        guard ScreenCaptureManager.shared.ensureScreenRecordingPermission() else { return }
        delayAndCapture {
            Task { @MainActor in
                guard let screen = NSScreen.main ?? NSScreen.screens.first,
                      let image = await ScreenCaptureManager.shared.captureFullscreen(screen: screen) else { return }
                self.handleCapture(image)
            }
        }
    }

    @objc private func scrollingCapture() {
        delayAndCapture {
            ScrollingCaptureManager.shared.start()
        }
    }

    private func handleCapture(_ image: NSImage) {
        let settings = AppSettings.shared
        if settings.autoOpenAnnotation {
            AnnotationEditorWindowManager.shared.openEditor(for: image)
        } else {
            guard let item = CaptureStore.shared.saveScreenshot(image) else { return }
            QuickAccessWindowManager.shared.show(for: item)
        }
    }

    // MARK: - Recording Actions

    @objc private func startOrStopRecording() {
        guard statusItem.menu?.item(withTag: 100) != nil else { return }

        if ScreenRecordingManager.shared.state == .idle {
            showRecordingControls()
        } else {
            finishRecording()
        }
    }

    private var recordingSetupPanel: NSPanel?
    private var recordingSetupEscMonitor: EscapeKeyMonitor?

    private func showRecordingControls() {
        guard ScreenCaptureManager.shared.ensureScreenRecordingPermission() else { return }

        closeRecordingSetup()

        let panel = makeFloatingPanel(width: 350, height: 118) {
            RecordingControlsView(
                onStart: { [weak self] options, kind in
                    self?.beginRecording(with: options, kind: kind)
                },
                onCancel: { [weak self] in
                    self?.closeRecordingSetup()
                }
            )
        }
        positionToolbarPanelCentered(panel)
        panel.orderFront(nil)
        recordingSetupPanel = panel

        let monitor = EscapeKeyMonitor { [weak self] in self?.closeRecordingSetup() }
        monitor.start()
        recordingSetupEscMonitor = monitor
    }

    private func closeRecordingSetup() {
        recordingSetupEscMonitor?.stop()
        recordingSetupEscMonitor = nil
        recordingSetupPanel?.orderOut(nil)
        recordingSetupPanel = nil
    }

    private func beginRecording(with options: RecordingSetupOptions, kind: RecordingKind) {
        closeRecordingSetup()

        if options.recordArea {
            AreaSelectorWindowManager.shared.startCapture { [weak self] rect in
                self?.showAreaRecordingReady(rect: rect, options: options, kind: kind)
            }
        } else {
            applyRecordingOptions(options)
            startRecordingSequence(options: options, kind: kind, captureRect: nil)
        }
    }

    private func applyRecordingOptions(_ options: RecordingSetupOptions) {
        AppSettings.shared.recordMicrophone = options.recordMicrophone
        AppSettings.shared.recordSystemAudio = options.recordSystemAudio
        AppSettings.shared.showClickHighlight = options.showClicks
        AppSettings.shared.showKeystrokes = options.showKeystrokes
    }

    // MARK: - Countdown + start

    private var countdownEscMonitor: EscapeKeyMonitor?

    /// Kicks off the webcam warm-up (if requested) immediately, runs the
    /// "3…2…1" countdown so it has time to produce real frames, then starts
    /// the actual screen capture. Pressing Escape during the countdown backs
    /// out cleanly instead of starting a recording.
    private func startRecordingSequence(options: RecordingSetupOptions, kind: RecordingKind, captureRect: CGRect?) {
        Task { @MainActor in
            await WebcamRecordingController.shared.begin(enabled: options.showWebcam, anchorRect: captureRect)

            let monitor = EscapeKeyMonitor { [weak self] in self?.cancelRecordingCountdown() }
            monitor.start()
            countdownEscMonitor = monitor

            RecordingCountdownWindowManager.shared.run(
                seconds: AppSettings.shared.recordingCountdown,
                anchorRect: captureRect
            ) { [weak self] in
                guard let self else { return }
                self.countdownEscMonitor?.stop()
                self.countdownEscMonitor = nil

                Task { @MainActor in
                    let ok: Bool
                    if let captureRect {
                        ok = await ScreenRecordingManager.shared.startRecording(captureRect: captureRect, kind: kind)
                    } else {
                        ok = await ScreenRecordingManager.shared.startRecording(kind: kind)
                    }
                    if ok {
                        if kind == .gif {
                            // Auto-stop once the GIF hits its length cap, same
                            // codepath as the user pressing Stop themselves.
                            ScreenRecordingManager.shared.onGifDurationReached = { [weak self] in
                                self?.finishRecording()
                            }
                        }
                        RecordingOverlaysController.shared.begin(
                            showClicks: options.showClicks,
                            showKeystrokes: options.showKeystrokes,
                            anchorRect: captureRect
                        )
                        self.showRecordingToolbar(captureRect: captureRect)
                        self.updateRecordingMenuItem(recording: true)
                    } else {
                        WebcamRecordingController.shared.stop()
                    }
                }
            }
        }
    }

    private func cancelRecordingCountdown() {
        countdownEscMonitor?.stop()
        countdownEscMonitor = nil
        RecordingCountdownWindowManager.shared.cancel()
        WebcamRecordingController.shared.stop()
    }

    private var areaReadyPanel: NSPanel?
    private var areaReadyEscMonitor: EscapeKeyMonitor?
    private var areaReadyIndicator: NSWindow?

    private func showAreaRecordingReady(rect: CGRect, options: RecordingSetupOptions, kind: RecordingKind) {
        closeAreaRecordingReady()

        let indicator = RegionIndicatorWindow.make(forTopLeftGlobalRect: rect)
        indicator.orderFront(nil)
        areaReadyIndicator = indicator

        let panel = makeToolbarPanel(width: 260, height: 52) {
            AreaRecordingReadyView(
                onRecord: { [weak self] in
                    guard let self else { return }
                    self.closeAreaRecordingReady()
                    self.applyRecordingOptions(options)
                    self.startRecordingSequence(options: options, kind: kind, captureRect: rect)
                },
                onCancel: { [weak self] in
                    self?.closeAreaRecordingReady()
                }
            )
        }
        panel.sharingType = .none
        elevateForCaptureControls(panel)
        positionToolbarPanelForCapture(panel, captureRect: rect)
        panel.orderFront(nil)
        areaReadyPanel = panel

        let monitor = EscapeKeyMonitor { [weak self] in self?.closeAreaRecordingReady() }
        monitor.start()
        areaReadyEscMonitor = monitor
    }

    private func closeAreaRecordingReady() {
        areaReadyEscMonitor?.stop()
        areaReadyEscMonitor = nil
        areaReadyPanel?.orderOut(nil)
        areaReadyPanel = nil
        areaReadyIndicator?.orderOut(nil)
        areaReadyIndicator = nil
    }

    private var recordingToolbarPanel: NSPanel?
    private var recordingEscMonitor: EscapeKeyMonitor?

    private func showRecordingToolbar(captureRect: CGRect? = nil) {
        guard recordingToolbarPanel == nil else { return }
        // The webcam toggle button is only ever present when the bubble was
        // enabled for this session (fixed for its whole duration), so size
        // the pill to match instead of always reserving room for it.
        let width: CGFloat = WebcamRecordingController.shared.isEnabledForSession ? 300 : 250
        let panel = makeToolbarPanel(width: width, height: 52) {
            RecordingToolbarView(
                onStop:    { self.finishRecording() },
                onDiscard: { self.discardRecording() }
            )
        }
        panel.sharingType = .none
        elevateForCaptureControls(panel)
        if let captureRect {
            positionToolbarPanelForCapture(panel, captureRect: captureRect)
        } else {
            positionToolbarPanelCentered(panel)
        }
        panel.orderFront(nil)
        recordingToolbarPanel = panel

        let monitor = EscapeKeyMonitor { [weak self] in self?.discardRecording() }
        monitor.start()
        recordingEscMonitor = monitor
    }

    private func finishRecording() {
        ScreenRecordingManager.shared.onGifDurationReached = nil
        Task {
            if let item = await ScreenRecordingManager.shared.stopRecording() {
                QuickAccessWindowManager.shared.show(for: item)
            }
            WebcamRecordingController.shared.stop()
            RecordingOverlaysController.shared.stop()
            self.closeRecordingToolbar()
            self.updateRecordingMenuItem(recording: false)
        }
    }

    private func discardRecording() {
        ScreenRecordingManager.shared.onGifDurationReached = nil
        Task {
            await ScreenRecordingManager.shared.discardRecording()
            WebcamRecordingController.shared.stop()
            RecordingOverlaysController.shared.stop()
            self.closeRecordingToolbar()
            self.updateRecordingMenuItem(recording: false)
        }
    }

    private func closeRecordingToolbar() {
        recordingEscMonitor?.stop()
        recordingEscMonitor = nil
        recordingToolbarPanel?.orderOut(nil)
        recordingToolbarPanel = nil
    }

    private func updateRecordingMenuItem(recording: Bool) {
        guard let menu = statusItem.menu,
              let recItem = menu.item(withTag: 100) else { return }
        recItem.title = recording ? "Stop Recording" : "Start Recording"
    }

    // MARK: - Tool Actions

    @objc private func textRecognition() {
        TextRecognitionManager.shared.captureAndRecognize()
    }

    @objc private func pinScreenshot() {
        guard ScreenCaptureManager.shared.ensureScreenRecordingPermission() else { return }
        AreaSelectorWindowManager.shared.startCapture { rect in
            Task { @MainActor in
                guard let image = await ScreenCaptureManager.shared.captureArea(rect) else { return }
                FloatingWindowManager.shared.pin(image: image)
            }
        }
    }

    private var desktopIconsHidden = false
    @objc private func toggleDesktopIcons() {
        desktopIconsHidden.toggle()
        UserDefaults(suiteName: "com.apple.finder")?.set(desktopIconsHidden, forKey: "CreateDesktop")
        NSWorkspace.shared.launchApplication("Finder")
        // Rebuild menu to update title
        let item = statusItem.menu?.items.first { $0.action == #selector(toggleDesktopIcons) }
        item?.title = desktopIconsHidden ? "Show Desktop Icons" : "Hide Desktop Icons"
    }

    // MARK: - App Actions

    @objc private func openHistory() {
        CaptureHistoryWindowManager.shared.open()
    }

    @objc private func openSettings() {
        SettingsWindowManager.shared.open()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - Delay helper

    private func delayAndCapture(_ action: @escaping () -> Void) {
        CaptureFocus.prepareForCapture()
        let delay = AppSettings.shared.captureDelay
        if delay == 0 {
            // Small delay to let menu close
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: action)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(delay), execute: action)
        }
    }
}
