import SwiftUI
import AppKit
import CoreImage

struct AnnotationEditorView: View {
    let originalImage: NSImage
    var onSave: ((NSImage) -> Void)?
    var onDismiss: (() -> Void)?

    @State private var workingImage: NSImage
    @StateObject private var canvasState = AnnotationCanvasState()
    @State private var exportedImage: NSImage? = nil
    @State private var zoomLevel: CGFloat = 1.0

    init(originalImage: NSImage, onSave: ((NSImage) -> Void)? = nil, onDismiss: (() -> Void)? = nil) {
        self.originalImage = originalImage
        self.onSave = onSave
        self.onDismiss = onDismiss
        _workingImage = State(initialValue: originalImage)
    }

    var body: some View {
        VStack(spacing: 12) {
            titleBar
            toolbar
            canvasArea
            bottomBar
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .padding(.top, 8)
        .frame(minWidth: 800, minHeight: 600)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            RoundedRectangle(cornerRadius: AnnotationEditorStyle.windowCornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
        }
        .ignoresSafeArea()
        .background(AnnotationWindowConfigurator())
        .preferredColorScheme(.dark)
        .onChange(of: canvasState.strokeColor) { _, newColor in
            canvasState.applyStrokeColorToSelection(newColor)
        }
        .onChange(of: canvasState.fontSize) { _, newSize in
            canvasState.applyFontSizeToSelection(newSize)
        }
        .onChange(of: canvasState.lineWidth) { _, newWidth in
            canvasState.applyLineWidthToSelection(newWidth)
        }
    }

    // MARK: - Title Bar

    private var titleBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "pencil.and.outline")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.7))
            Text("Annotate")
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .foregroundStyle(.white)
            Spacer()
            Text("\(Int(workingImage.size.width)) × \(Int(workingImage.size.height))")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.45))
        }
        .frame(height: 28)
        .padding(.leading, 78)
        .padding(.trailing, 4)
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        AnnotationEditorBar {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    toolGroup([.select])
                    AnnotationBarDivider()
                    toolGroup([.arrow, .line])
                    AnnotationBarDivider()
                    toolGroup([.rectangle, .filledRect, .ellipse, .filledEllipse])
                    AnnotationBarDivider()
                    toolGroup([.pencil, .highlighter])
                    AnnotationBarDivider()
                    toolGroup([.text])
                    AnnotationBarDivider()
                    toolGroup([.spotlight])
                    AnnotationBarDivider()
                    toolGroup([.crop])
                }
                .padding(.vertical, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            AnnotationBarDivider()

            colorAndSizeControls
                .fixedSize()
        }
    }

    private func toolGroup(_ tools: [AnnotationToolType]) -> some View {
        HStack(spacing: 4) {
            ForEach(tools, id: \.self) { tool in
                AnnotationToolButton(
                    icon: tool.sfSymbol,
                    help: tool.displayName,
                    isSelected: canvasState.currentTool == tool
                ) {
                    canvasState.currentTool = tool
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var colorAndSizeControls: some View {
        HStack(spacing: 10) {
            AnnotationStrokeColorPicker(color: $canvasState.strokeColor)

            annotationPicker(selection: $canvasState.lineWidth, help: "Line Width") {
                ForEach([1.0, 2.0, 3.0, 5.0, 8.0], id: \.self) { w in
                    Text("\(Int(w))pt").tag(CGFloat(w))
                }
            }

            if canvasState.currentTool == .text || canvasState.hasSelectedText {
                annotationPicker(selection: $canvasState.fontSize, help: "Font Size") {
                    ForEach([12.0, 16.0, 18.0, 24.0, 32.0, 48.0], id: \.self) { s in
                        Text("\(Int(s))").tag(CGFloat(s))
                    }
                }
            }

            if canvasState.currentTool == .arrow {
                annotationPicker(selection: $canvasState.arrowStyle, help: "Arrow Style") {
                    Text("→").tag(0)
                    Text("⤑").tag(1)
                    Text("↠").tag(2)
                }
            }
        }
    }

    private func annotationPicker<Selection: Hashable, Content: View>(
        selection: Binding<Selection>,
        help: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Picker("", selection: selection, content: content)
            .labelsHidden()
            .frame(minWidth: 64)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .help(help)
    }

    // MARK: - Canvas

    private var canvasArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: AnnotationEditorStyle.canvasCornerRadius, style: .continuous)
                .fill(Color.black.opacity(0.35))

            RoundedRectangle(cornerRadius: AnnotationEditorStyle.canvasCornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)

            AnnotationCanvasView(baseImage: workingImage, state: canvasState) { cropRect in
                applyCrop(to: cropRect)
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        AnnotationEditorBar {
            HStack(spacing: 6) {
                Button { canvasState.undo() } label: {
                    annotationIconLabel("arrow.uturn.backward", isEnabled: canvasState.canUndo)
                }
                .buttonStyle(.plain)
                .disabled(!canvasState.canUndo)
                .keyboardShortcut("z", modifiers: .command)
                .help("Undo")

                Button { canvasState.redo() } label: {
                    annotationIconLabel("arrow.uturn.forward", isEnabled: canvasState.canRedo)
                }
                .buttonStyle(.plain)
                .disabled(!canvasState.canRedo)
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .help("Redo")

                Button { canvasState.deleteSelected() } label: {
                    annotationIconLabel("trash", isEnabled: true)
                }
                .buttonStyle(.plain)
                .help("Delete Selected")
            }

            Spacer()

            HStack(spacing: 10) {
                Button("Cancel") { onDismiss?() }
                    .buttonStyle(AnnotationSecondaryButtonStyle())
                    .keyboardShortcut(.escape)

                Button("Copy") { copyToClipboard() }
                    .buttonStyle(AnnotationSecondaryButtonStyle())
                    .keyboardShortcut("c", modifiers: [.command, .shift])

                Button("Save") {
                    let flat = flattenedImage()
                    _ = CaptureStore.shared.saveScreenshot(flat)
                    onSave?(flat)
                    onDismiss?()
                }
                .buttonStyle(AnnotationPrimaryButtonStyle())
                .keyboardShortcut("s", modifiers: .command)
            }
        }
    }

    private func annotationIconLabel(_ icon: String, isEnabled: Bool) -> some View {
        Image(systemName: icon)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(isEnabled ? Color.white.opacity(0.88) : Color.white.opacity(0.28))
            .frame(width: 34, height: 34)
            .background(Color.white.opacity(isEnabled ? 0.08 : 0.04))
            .clipShape(Circle())
            .contentShape(Circle())
            .frame(width: 40, height: 40)
            .contentShape(Rectangle())
    }

    // MARK: - Actions

    private func copyToClipboard() {
        let flat = flattenedImage()
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([flat])
    }

    private func flattenedImage() -> NSImage {
        let size = workingImage.size
        guard size.width > 0, size.height > 0 else { return workingImage }

        // Render at the source's native pixel density (e.g. 2x/3x on Retina) rather than
        // the image's logical point size, otherwise annotated exports get downsampled to 1x.
        let pixelScale = workingImage.pixelScale
        let pixelsWide = max(1, Int((size.width * pixelScale).rounded()))
        let pixelsHigh = max(1, Int((size.height * pixelScale).rounded()))

        // Use NSBitmapImageRep for reliable offscreen rendering (no force-unwrap)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelsWide,
            pixelsHigh: pixelsHigh,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
            return workingImage
        }
        rep.size = size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.cgContext.scaleBy(x: pixelScale, y: pixelScale)
        ctx.cgContext.interpolationQuality = .high

        workingImage.draw(in: NSRect(origin: .zero, size: size))

        let spotlights = canvasState.annotations.filter { $0.toolType == .spotlight }
        let otherAnnotations = canvasState.annotations.filter { $0.toolType != .spotlight }

        if !spotlights.isEmpty, let blurred = blurredImage(from: workingImage, radius: SpotlightStyle.blurRadius) {
            for ann in spotlights {
                renderSpotlightToContext(ann, blurredImage: blurred, in: ctx.cgContext, imageSize: size)
            }
        }

        for ann in otherAnnotations {
            renderAnnotationToContext(ann, in: ctx.cgContext, imageSize: size)
        }

        NSGraphicsContext.restoreGraphicsState()

        let output = NSImage(size: size)
        output.addRepresentation(rep)
        return output
    }

    private func renderAnnotationToContext(_ ann: Annotation, in ctx: CGContext, imageSize: CGSize) {
        // Simplified: draw using AppKit drawing calls
        let color = ann.color.nsColor
        ctx.setStrokeColor(color.cgColor)
        ctx.setFillColor(color.cgColor)
        ctx.setLineWidth(ann.lineWidth)

        switch ann.toolType {
        case .rectangle:
            let rect = normalizedRect(ann.startPoint, ann.endPoint)
            ctx.stroke(rect)
        case .filledRect:
            let rect = normalizedRect(ann.startPoint, ann.endPoint)
            ctx.setFillColor(color.cgColor)
            ctx.fill(rect)
        case .ellipse:
            let rect = normalizedRect(ann.startPoint, ann.endPoint)
            ctx.strokeEllipse(in: rect)
        case .filledEllipse:
            let rect = normalizedRect(ann.startPoint, ann.endPoint)
            ctx.setFillColor(color.cgColor)
            ctx.fillEllipse(in: rect)
        case .highlighter:
            let rect = normalizedRect(ann.startPoint, ann.endPoint)
            ctx.setFillColor(color.withAlphaComponent(0.35).cgColor)
            ctx.fill(rect)
        case .arrow, .line:
            ctx.move(to: ann.startPoint)
            ctx.addLine(to: ann.endPoint)
            ctx.strokePath()
        case .pencil:
            if let first = ann.points.first {
                ctx.move(to: first)
                ann.points.dropFirst().forEach { ctx.addLine(to: $0) }
                ctx.strokePath()
            }
        case .text where !ann.text.isEmpty:
            let attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: color,
                .font: NSFont.systemFont(ofSize: ann.fontSize)
            ]
            ann.text.draw(at: ann.startPoint, withAttributes: attrs)
        default:
            break
        }
    }

    private func blurredImage(from image: NSImage, radius: CGFloat) -> NSImage? {
        guard let tiff = image.tiffRepresentation,
              let ciImage = CIImage(data: tiff) else { return nil }

        let filter = CIFilter(name: "CIGaussianBlur")!
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage else { return nil }

        let cropped = output.cropped(to: ciImage.extent)
        let rep = NSCIImageRep(ciImage: cropped)
        let result = NSImage(size: image.size)
        result.addRepresentation(rep)
        return result
    }

    private func renderSpotlightToContext(
        _ ann: Annotation,
        blurredImage: NSImage,
        in ctx: CGContext,
        imageSize: CGSize
    ) {
        let geometry = SpotlightGeometry(annotation: ann, minimumRadius: 8)
        let ellipseRect = geometry.ellipseRect
        guard ellipseRect.width > 4, ellipseRect.height > 4 else { return }

        ctx.saveGState()

        let clipPath = CGMutablePath()
        clipPath.addRect(CGRect(origin: .zero, size: imageSize))
        clipPath.addEllipse(in: ellipseRect)
        ctx.addPath(clipPath)
        ctx.clip(using: .evenOdd)

        blurredImage.draw(in: CGRect(origin: .zero, size: imageSize))
        ctx.setFillColor(NSColor.black.withAlphaComponent(SpotlightStyle.dimOpacity).cgColor)
        ctx.fill(CGRect(origin: .zero, size: imageSize))

        ctx.restoreGState()
    }

    private func normalizedRect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    private func applyCrop(to rect: CGRect) {
        guard rect.width > 1, rect.height > 1,
              let cropped = croppedImage(from: workingImage, rect: rect) else { return }

        canvasState.pushUndo()
        canvasState.transformForCrop(rect)
        workingImage = cropped
    }

    private func croppedImage(from image: NSImage, rect: CGRect) -> NSImage? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        let pixelScale = image.pixelScale
        let pixelRect = CGRect(
            x: rect.origin.x * pixelScale,
            y: rect.origin.y * pixelScale,
            width: rect.width * pixelScale,
            height: rect.height * pixelScale
        ).integral

        guard pixelRect.width > 0, pixelRect.height > 0,
              let cropped = cgImage.cropping(to: pixelRect) else { return nil }

        return NSImage(cgImage: cropped, size: NSSize(width: rect.width, height: rect.height))
    }
}

extension NSImage {
    /// Ratio of the image's native pixel dimensions to its logical point size
    /// (e.g. 2.0 on a Retina/2x display, 3.0 on some 3x displays, 1.0 otherwise).
    var pixelScale: CGFloat {
        guard size.width > 0,
              let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return 1 }
        return CGFloat(cgImage.width) / size.width
    }
}

// MARK: - Editor Chrome

private enum AnnotationEditorStyle {
    static let windowCornerRadius: CGFloat = 18
    static let barCornerRadius: CGFloat = 14
    static let canvasCornerRadius: CGFloat = 12
    static let toolHitSize: CGFloat = 40
    static let toolVisualSize: CGFloat = 34
}

private struct AnnotationWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            applyChrome(to: view)
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            applyChrome(to: view)
        }
    }

    private func applyChrome(to view: NSView) {
        guard let window = view.window else { return }

        window.titlebarSeparatorStyle = .none
        window.appearance = NSAppearance(named: .darkAqua)
        window.toolbarStyle = .unifiedCompact
    }
}

private struct AnnotationEditorBar<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 12) {
            content
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(ToolbarBlurBackground())
        .clipShape(RoundedRectangle(cornerRadius: AnnotationEditorStyle.barCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AnnotationEditorStyle.barCornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
    }
}

private struct AnnotationBarDivider: View {
    var body: some View {
        Divider()
            .frame(height: 24)
            .background(Color.white.opacity(0.18))
    }
}

private struct AnnotationToolButton: View {
    let icon: String
    let help: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isSelected ? Color.black : Color.white.opacity(0.88))
                .frame(width: AnnotationEditorStyle.toolVisualSize, height: AnnotationEditorStyle.toolVisualSize)
                .background(isSelected ? Color.white : Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .frame(width: AnnotationEditorStyle.toolHitSize, height: AnnotationEditorStyle.toolHitSize)
        .contentShape(Rectangle())
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct AnnotationPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.callout, weight: .semibold))
            .foregroundStyle(.black)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.white.opacity(configuration.isPressed ? 0.85 : 1))
            .clipShape(Capsule())
    }
}

private struct AnnotationSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.callout, weight: .medium))
            .foregroundStyle(Color.white.opacity(configuration.isPressed ? 0.65 : 0.85))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.white.opacity(configuration.isPressed ? 0.14 : 0.08))
            .clipShape(Capsule())
    }
}

// MARK: - Stroke Color Picker

private struct AnnotationStrokeColorPicker: View {
    @Binding var color: Color
    @State private var showPopover = false

    private let presets: [(name: String, color: Color)] = [
        ("Red", .red),
        ("Orange", .orange),
        ("Yellow", .yellow),
        ("Green", .green),
        ("Cyan", .cyan),
        ("Blue", .blue),
        ("Purple", .purple),
        ("Pink", .pink),
        ("Black", .black),
        ("White", .white),
    ]

    var body: some View {
        Button {
            showPopover.toggle()
        } label: {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(color)
                .frame(width: 34, height: 34)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .frame(width: 40, height: 40)
        .contentShape(Rectangle())
        .buttonStyle(.plain)
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Stroke Color")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                LazyVGrid(
                    columns: Array(repeating: GridItem(.fixed(32), spacing: 8), count: 5),
                    spacing: 8
                ) {
                    ForEach(presets, id: \.name) { preset in
                        Button {
                            color = preset.color
                        } label: {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(preset.color)
                                .frame(width: 32, height: 32)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .strokeBorder(
                                            isSelected(preset.color) ? Color.accentColor : Color.primary.opacity(0.15),
                                            lineWidth: isSelected(preset.color) ? 2 : 1
                                        )
                                )
                                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                        .buttonStyle(.plain)
                        .help(preset.name)
                    }
                }

                Divider()

                HStack(spacing: 8) {
                    Text("Custom")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    AnchoredColorWellRepresentable(color: $color)
                        .frame(width: 44, height: 24)
                }
            }
            .padding(12)
            .frame(width: 196)
        }
        .help("Stroke Color")
    }

    private func isSelected(_ preset: Color) -> Bool {
        NSColor(preset).isEqual(NSColor(color))
    }
}

private struct AnchoredColorWellRepresentable: NSViewRepresentable {
    @Binding var color: Color

    func makeNSView(context: Context) -> AnchoredColorWell {
        let well = AnchoredColorWell()
        well.color = NSColor(color)
        well.isEnabled = true
        well.target = context.coordinator
        well.action = #selector(Coordinator.colorChanged(_:))
        return well
    }

    func updateNSView(_ well: AnchoredColorWell, context: Context) {
        let updated = NSColor(color)
        if !well.color.isEqual(updated) {
            well.color = updated
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(color: $color)
    }

    final class Coordinator: NSObject {
        var color: Binding<Color>

        init(color: Binding<Color>) {
            self.color = color
        }

        @objc func colorChanged(_ sender: NSColorWell) {
            color.wrappedValue = Color(sender.color)
        }
    }
}

private final class AnchoredColorWell: NSColorWell {
    override func activate(_ activate: Bool) {
        if activate { repositionSharedColorPanel() }
        super.activate(activate)
    }

    override func mouseDown(with event: NSEvent) {
        repositionSharedColorPanel()
        super.mouseDown(with: event)
        DispatchQueue.main.async { [weak self] in
            self?.repositionSharedColorPanel()
        }
    }

    private func repositionSharedColorPanel() {
        guard let window else { return }

        let panel = NSColorPanel.shared
        if !panel.isVisible {
            panel.orderFront(nil)
        }

        let panelSize = panel.frame.size
        guard panelSize.width > 0, panelSize.height > 0 else { return }

        let anchor = window.convertToScreen(convert(bounds, to: nil))
        var origin = NSPoint(
            x: anchor.midX - panelSize.width * 0.5,
            y: anchor.minY - panelSize.height - 12
        )

        if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - panelSize.width - 8)
            origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - panelSize.height - 8)
        }

        panel.setFrameOrigin(origin)
    }
}
