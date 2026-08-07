import AppKit
import SwiftUI

// MARK: - Floating confirmation toast
//
// Small auto-dismissing pill used to confirm the result of a one-shot action
// (e.g. "Text copied to clipboard" after text recognition) without relying on
// the system notification center.

@MainActor
final class ConfirmationToastWindowManager {
    static let shared = ConfirmationToastWindowManager()
    private init() {}

    private var panel: NSPanel?
    private var dismissWorkItem: DispatchWorkItem?

    /// Shows `message` (with a leading `icon`) in a floating pill.
    /// - Parameter anchorRect: Top-left global rect (AreaSelector space) to
    ///   position near, keeping clear of the region itself. Falls back to
    ///   bottom-centre of the main screen when `nil`.
    func show(icon: String, message: String, anchorRect: CGRect? = nil, duration: TimeInterval = 1.8) {
        dismissWorkItem?.cancel()
        panel?.orderOut(nil)

        let width = toastWidth(for: message)
        let newPanel = makeToolbarPanel(width: width, height: 48) {
            ConfirmationToastView(icon: icon, message: message)
        }
        newPanel.ignoresMouseEvents = true
        newPanel.sharingType = .none
        elevateForCaptureControls(newPanel)

        if let anchorRect {
            positionToolbarPanelForCapture(newPanel, captureRect: anchorRect)
        } else {
            positionToolbarPanelCentered(newPanel)
        }

        newPanel.alphaValue = 0
        newPanel.orderFront(nil)
        panel = newPanel

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            newPanel.animator().alphaValue = 1
        }

        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        dismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    func dismiss() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        guard let current = panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            current.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            current.orderOut(nil)
            if self?.panel === current { self?.panel = nil }
        })
    }

    private func toastWidth(for message: String) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium)]
        let textWidth = (message as NSString).size(withAttributes: attrs).width
        return min(max(textWidth + 90, 200), 420)
    }
}

private struct ConfirmationToastView: View {
    let icon: String
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
            Text(message)
                .font(.system(.callout, weight: .medium))
                .foregroundColor(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 18)
        .frame(maxHeight: .infinity)
    }
}
