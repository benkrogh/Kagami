import AppKit

// MARK: - Region shroud overlay
//
// Darkens the rest of the display so the active capture region reads as the
// only "live" part of the screen — the region itself is left completely
// clear (full brightness) while everywhere else is dimmed. Used during area
// screen recording and scrolling capture so the user always sees what is
// being captured. sharingType = .none keeps the shroud out of the
// recording/screenshot itself; only the plain screen content underneath the
// clear hole ever reaches the capture.

@MainActor
enum RegionIndicatorWindow {
    /// `rect` is in global display points with the origin at the TOP-LEFT of the
    /// primary display (the space produced by `AreaSelectorWindow`).
    static func make(forTopLeftGlobalRect rect: CGRect) -> NSWindow {
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        let bottomLeftRect = CGRect(
            x: rect.minX,
            y: primaryH - (rect.minY + rect.height),
            width: rect.width,
            height: rect.height
        )

        // Shroud the whole display that contains the region so everything
        // outside it — not just a thin border — reads as dimmed.
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(bottomLeftRect) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let screenFrame = screen?.frame ?? bottomLeftRect.insetBy(dx: -400, dy: -400)

        let win = NSWindow(contentRect: screenFrame, styleMask: .borderless, backing: .buffered, defer: false)
        win.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
        win.backgroundColor = .clear
        win.isOpaque = false
        win.hasShadow = false
        win.ignoresMouseEvents = true
        win.sharingType = .none
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let holeRect = CGRect(
            x: bottomLeftRect.minX - screenFrame.minX,
            y: bottomLeftRect.minY - screenFrame.minY,
            width: bottomLeftRect.width,
            height: bottomLeftRect.height
        )
        win.contentView = RegionShroudView(frame: NSRect(origin: .zero, size: screenFrame.size), holeRect: holeRect)
        return win
    }
}

final class RegionShroudView: NSView {
    private let holeRect: CGRect

    init(frame: NSRect, holeRect: CGRect) {
        self.holeRect = holeRect
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        NSColor.black.withAlphaComponent(0.5).setFill()
        bounds.fill()

        // Punch a fully transparent hole over the active region.
        ctx.saveGState()
        ctx.setBlendMode(.clear)
        ctx.fill(holeRect)
        ctx.restoreGState()

        // Subtle neutral edge so the cutout still reads clearly against bright content.
        let path = NSBezierPath(rect: holeRect.insetBy(dx: 0.5, dy: 0.5))
        path.lineWidth = 1
        NSColor.white.withAlphaComponent(0.6).setStroke()
        path.stroke()
    }
}
