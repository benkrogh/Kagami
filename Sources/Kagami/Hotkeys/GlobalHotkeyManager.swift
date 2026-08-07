import AppKit
import Carbon

/// App-wide capture hotkeys registered via Carbon `RegisterEventHotKey`.
///
/// Menu-bar / `LSUIElement` apps almost never become key, so `NSMenuItem.keyEquivalent`
/// is display-only. These Carbon hotkeys fire system-wide without Accessibility permission.
final class GlobalHotkeyManager {
    static let shared = GlobalHotkeyManager()

    enum Action: UInt32, CaseIterable {
        case captureArea = 1
        case captureWindow
        case captureFullscreen
        case startRecording
        case scrollingCapture
        case textRecognition
        case openHistory
    }

    /// Shared definitions for menu labels and Carbon registration.
    struct Shortcut {
        let action: Action
        let keyCode: UInt32
        let carbonModifiers: UInt32
        let keyEquivalent: String
        let modifierFlags: NSEvent.ModifierFlags

        static let defaults: [Shortcut] = [
            Shortcut(action: .captureArea,       keyCode: UInt32(kVK_ANSI_1), carbonModifiers: UInt32(cmdKey | shiftKey), keyEquivalent: "1", modifierFlags: [.command, .shift]),
            Shortcut(action: .captureWindow,     keyCode: UInt32(kVK_ANSI_2), carbonModifiers: UInt32(cmdKey | shiftKey), keyEquivalent: "2", modifierFlags: [.command, .shift]),
            Shortcut(action: .captureFullscreen, keyCode: UInt32(kVK_ANSI_3), carbonModifiers: UInt32(cmdKey | shiftKey), keyEquivalent: "3", modifierFlags: [.command, .shift]),
            Shortcut(action: .startRecording,    keyCode: UInt32(kVK_ANSI_4), carbonModifiers: UInt32(cmdKey | shiftKey), keyEquivalent: "4", modifierFlags: [.command, .shift]),
            Shortcut(action: .scrollingCapture,  keyCode: UInt32(kVK_ANSI_5), carbonModifiers: UInt32(cmdKey | shiftKey), keyEquivalent: "5", modifierFlags: [.command, .shift]),
            Shortcut(action: .textRecognition,   keyCode: UInt32(kVK_ANSI_T), carbonModifiers: UInt32(cmdKey | shiftKey), keyEquivalent: "t", modifierFlags: [.command, .shift]),
            Shortcut(action: .openHistory,       keyCode: UInt32(kVK_ANSI_Y), carbonModifiers: UInt32(cmdKey | shiftKey), keyEquivalent: "y", modifierFlags: [.command, .shift]),
        ]

        static func shortcut(for action: Action) -> Shortcut? {
            defaults.first { $0.action == action }
        }
    }

    private static let signature: OSType = 0x4B474D49 // 'KGMI'

    private var hotKeyRefs: [EventHotKeyRef] = []
    private var handlerRef: EventHandlerRef?
    private var onAction: ((Action) -> Void)?

    private init() {}

    /// Registers the default capture hotkeys. Safe to call more than once (re-registers).
    func start(onAction: @escaping (Action) -> Void) {
        stop()
        self.onAction = onAction
        installHandler()
        registerDefaults()
    }

    func stop() {
        for ref in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()

        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
        onAction = nil
    }

    deinit {
        // Carbon refs must be released even if `stop()` wasn't called.
        for ref in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
        }
    }

    // MARK: - Private

    private func registerDefaults() {
        for shortcut in Shortcut.defaults {
            var hotKeyRef: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: Self.signature, id: shortcut.action.rawValue)
            let status = RegisterEventHotKey(
                shortcut.keyCode,
                shortcut.carbonModifiers,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &hotKeyRef
            )
            if status == noErr, let hotKeyRef {
                hotKeyRefs.append(hotKeyRef)
            } else {
                NSLog("Kagami: failed to register hotkey \(shortcut.keyEquivalent) (status \(status))")
            }
        }
    }

    private func installHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, userData) -> OSStatus in
                GlobalHotkeyManager.handleCarbonEvent(event, userData: userData)
            },
            1,
            &eventType,
            userData,
            &handlerRef
        )
        if status != noErr {
            NSLog("Kagami: failed to install hotkey handler (status \(status))")
        }
    }

    private static func handleCarbonEvent(_ event: EventRef?, userData: UnsafeMutableRawPointer?) -> OSStatus {
        guard let event, let userData else { return OSStatus(eventNotHandledErr) }

        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        guard status == noErr, hotKeyID.signature == signature else {
            return OSStatus(eventNotHandledErr)
        }
        guard let action = Action(rawValue: hotKeyID.id) else {
            return OSStatus(eventNotHandledErr)
        }

        let manager = Unmanaged<GlobalHotkeyManager>.fromOpaque(userData).takeUnretainedValue()
        DispatchQueue.main.async {
            manager.onAction?(action)
        }
        return noErr
    }
}
