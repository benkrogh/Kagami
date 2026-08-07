import AppKit
import SwiftUI

@MainActor
final class QuickAccessWindowManager {
    static let shared = QuickAccessWindowManager()
    private init() {}

    private var currentPanel: NSPanel?
    private var autoCloseTask: DispatchWorkItem?

    private let cardWidth: CGFloat = 280
    private let cardHeight: CGFloat = 330

    func show(for item: CaptureItem) {
        dismiss()

        let panel = makeFloatingPanel(width: cardWidth, height: cardHeight, cornerRadius: 16) {
            QuickAccessView(
                captureItem: item,
                onDismiss: { [weak self] in self?.dismiss() },
                onBeginSharing: { [weak self] in self?.suspendAutoClose() }
            )
        }
        positionPanel(panel)
        panel.orderFront(nil)
        currentPanel = panel

        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        autoCloseTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
    }

    func dismiss() {
        autoCloseTask?.cancel()
        autoCloseTask = nil
        currentPanel?.orderOut(nil)
        currentPanel = nil
    }

    /// Cancels the pending auto-close without hiding the card — used while the
    /// share picker is open so the card (and its anchor view) doesn't vanish
    /// out from under the user mid-pick. The card is dismissed explicitly once
    /// sharing finishes.
    private func suspendAutoClose() {
        autoCloseTask?.cancel()
        autoCloseTask = nil
    }

    private func positionPanel(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let sv = screen.visibleFrame
        let margin: CGFloat = 16
        // Pull the window frame out by the shadow inset so the visible card keeps
        // the intended margin from the screen edge.
        let edgeAdjust = margin - toolbarShadowInset

        let pos = AppSettings.shared.quickAccessPosition
        let x: CGFloat
        let y: CGFloat

        switch pos {
        case .bottomRight: x = sv.maxX - panel.frame.width - edgeAdjust; y = sv.minY + edgeAdjust
        case .bottomLeft:  x = sv.minX + edgeAdjust;                   y = sv.minY + edgeAdjust
        case .topRight:    x = sv.maxX - panel.frame.width - edgeAdjust; y = sv.maxY - panel.frame.height - edgeAdjust
        case .topLeft:     x = sv.minX + edgeAdjust;                   y = sv.maxY - panel.frame.height - edgeAdjust
        }

        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
