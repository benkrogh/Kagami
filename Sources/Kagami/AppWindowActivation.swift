import AppKit

/// Manages switching between menu-bar (.accessory) and regular app modes so document
/// windows appear in the Dock and Cmd-Tab while open.
@MainActor
enum AppWindowActivation {
    static func updateActivationPolicy() {
        let hasDocumentWindows = NSApp.windows.contains(where: isDocumentWindow)
        NSApp.setActivationPolicy(hasDocumentWindows ? .regular : .accessory)
    }

    private static func isDocumentWindow(_ window: NSWindow) -> Bool {
        window.isVisible
            && window.styleMask.contains(.titled)
            && !window.styleMask.contains(.borderless)
    }
}

/// Sends open annotation editors behind other apps so they don't cover the screen
/// when the user starts a new capture.
@MainActor
enum CaptureFocus {
    static func prepareForCapture() {
        AnnotationEditorWindowManager.shared.orderAllBack()
    }
}

final class DocumentWindowDelegate: NSObject, NSWindowDelegate {
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}
