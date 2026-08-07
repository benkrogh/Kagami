import AppKit

typealias AreaSelectorCompletion = (CGRect) -> Void

// MARK: - Overlay View

final class AreaSelectorView: NSView {

    var onComplete: AreaSelectorCompletion?
    var onCancel: (() -> Void)?

    private var startPoint: NSPoint = .zero
    private var currentPoint: NSPoint = .zero
    private var isDragging = false
    private let crosshairColor = NSColor.white.withAlphaComponent(0.9)

    override init(frame: NSRect) {
        super.init(frame: frame)
        let opts: NSTrackingArea.Options = [.mouseMoved, .activeAlways, .inVisibleRect]
        addTrackingArea(NSTrackingArea(rect: bounds, options: opts, owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() }  // Escape
    }

    override func mouseDown(with event: NSEvent) {
        startPoint   = convert(event.locationInWindow, from: nil)
        currentPoint = startPoint
        isDragging   = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        isDragging   = false

        let sel = selectionRect
        if sel.width > 5 && sel.height > 5 {
            onComplete?(viewRectToScreenRect(sel))
        } else {
            onCancel?()
        }
    }

    override func mouseMoved(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        // Dim overlay
        NSColor.black.withAlphaComponent(0.45).setFill()
        bounds.fill()

        if isDragging {
            drawSelectionOverlay()
        }

        drawCrosshair()
        if isDragging { drawDimensions() }
    }

    private var selectionRect: CGRect {
        CGRect(
            x: min(startPoint.x, currentPoint.x),
            y: min(startPoint.y, currentPoint.y),
            width: abs(currentPoint.x - startPoint.x),
            height: abs(currentPoint.y - startPoint.y)
        )
    }

    private func drawSelectionOverlay() {
        let sel = selectionRect
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // Cut clear hole for selection
        ctx.saveGState()
        ctx.setBlendMode(.clear)
        ctx.fill(sel)
        ctx.restoreGState()

        // White selection border
        let path = NSBezierPath(rect: sel.insetBy(dx: -0.5, dy: -0.5))
        NSColor.white.setStroke()
        path.lineWidth = 1.5
        path.stroke()

        drawHandles(for: sel)
    }

    private func drawHandles(for rect: CGRect) {
        let size: CGFloat = 6
        let corners: [CGPoint] = [
            CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.midX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.midY),
            CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.midX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.midY),
        ]
        for pt in corners {
            let r = CGRect(x: pt.x - size/2, y: pt.y - size/2, width: size, height: size)
            let p = NSBezierPath(roundedRect: r, xRadius: 1, yRadius: 1)
            NSColor.white.setFill(); p.fill()
            NSColor.black.withAlphaComponent(0.5).setStroke(); p.lineWidth = 0.5; p.stroke()
        }
    }

    private func drawCrosshair() {
        let x = currentPoint.x, y = currentPoint.y
        crosshairColor.setStroke()
        let h = NSBezierPath(); h.move(to: NSPoint(x: 0, y: y)); h.line(to: NSPoint(x: bounds.width, y: y))
        h.lineWidth = 0.5; h.stroke()
        let v = NSBezierPath(); v.move(to: NSPoint(x: x, y: 0)); v.line(to: NSPoint(x: x, y: bounds.height))
        v.lineWidth = 0.5; v.stroke()
    }

    private func drawDimensions() {
        let sel  = selectionRect
        let text = "\(Int(sel.width)) × \(Int(sel.height))"
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white,
            .font: NSFont.boldSystemFont(ofSize: 11)
        ]
        let size    = text.size(withAttributes: attrs)
        let padding: CGFloat = 6
        var labelOrigin = CGPoint(x: sel.midX - size.width/2 - padding, y: sel.maxY + 8)
        if labelOrigin.y + size.height + padding * 2 > bounds.height { labelOrigin.y = sel.minY - size.height - padding * 2 - 8 }

        let bgRect = CGRect(x: labelOrigin.x, y: labelOrigin.y, width: size.width + padding * 2, height: size.height + padding)
        let bg = NSBezierPath(roundedRect: bgRect, xRadius: 4, yRadius: 4)
        NSColor(white: 0, alpha: 0.7).setFill(); bg.fill()
        text.draw(at: NSPoint(x: bgRect.minX + padding, y: bgRect.minY + padding / 2), withAttributes: attrs)
    }

    // MARK: - Coordinate conversion

    private func viewRectToScreenRect(_ rect: CGRect) -> CGRect {
        guard let win = window else { return rect }
        // Convert NSView rect → screen coordinates (y=0 at bottom of primary screen)
        let topLeft = win.convertPoint(toScreen: convert(CGPoint(x: rect.minX, y: rect.maxY), to: nil))
        // CGWindowListCreateImage wants y=0 at TOP of primary display
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(
            x: topLeft.x,
            y: primaryHeight - topLeft.y,
            width: rect.width,
            height: rect.height
        )
    }
}

// MARK: - Window Manager

@MainActor
final class AreaSelectorWindowManager {
    static let shared = AreaSelectorWindowManager()
    private init() {}

    private var windows: [NSWindow] = []
    private var escMonitor: EscapeKeyMonitor?
    private var hintPanel: NSPanel?

    /// - Parameter hint: When provided, shows a small floating pill explaining what
    ///   the selection is for (e.g. text recognition) while the user drags out a
    ///   region. Dismissed automatically once the selection completes or cancels.
    func startCapture(hint: String? = nil, completion: @escaping AreaSelectorCompletion) {
        dismiss()
        CaptureFocus.prepareForCapture()

        // Esc cancels area selection even when another app has keyboard focus.
        let monitor = EscapeKeyMonitor { [weak self] in self?.dismiss() }
        monitor.start()
        escMonitor = monitor

        for screen in NSScreen.screens {
            let win = NSWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            win.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
            win.backgroundColor   = .clear
            win.isOpaque          = false
            win.hasShadow         = false
            win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            win.setFrame(screen.frame, display: false)

            let view = AreaSelectorView(frame: screen.frame)
            view.onComplete = { [weak self] rect in
                self?.dismiss()
                completion(rect)
            }
            view.onCancel = { [weak self] in self?.dismiss() }

            win.contentView = view
            win.makeKeyAndOrderFront(nil)
            win.makeFirstResponder(view)
            windows.append(win)
        }

        if let hint {
            showHint(hint)
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    private func showHint(_ text: String) {
        let panel = makeToolbarPanel(width: 420, height: 48) {
            AreaSelectionHintView(text: text)
        }
        panel.ignoresMouseEvents = true
        panel.sharingType = .none
        elevateForCaptureControls(panel)
        positionToolbarPanelCentered(panel)
        panel.orderFront(nil)
        hintPanel = panel
    }

    func dismiss() {
        escMonitor?.stop()
        escMonitor = nil
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        hintPanel?.orderOut(nil)
        hintPanel = nil
    }
}
