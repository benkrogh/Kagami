import SwiftUI
import AppKit

// MARK: - Canvas State

@MainActor
final class AnnotationCanvasState: ObservableObject {
    @Published var annotations: [Annotation] = []
    @Published var currentTool: AnnotationToolType = .select
    @Published var strokeColor: Color = Color(hex: "#544CC8")
    @Published var fillColor: Color = .clear
    @Published var lineWidth: CGFloat = 3
    @Published var fontSize: CGFloat = 18
    @Published var arrowStyle: Int = 0
    @Published var activeTextAnnotation: UUID? = nil

    private var undoStack: [[Annotation]] = []
    private var redoStack: [[Annotation]] = []

    func pushUndo() {
        undoStack.append(annotations)
        redoStack.removeAll()
    }

    func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(annotations)
        annotations = prev
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(annotations)
        annotations = next
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func deleteSelected() {
        pushUndo()
        annotations.removeAll { $0.isSelected }
    }

    func selectAll() {
        for i in annotations.indices { annotations[i].isSelected = true }
    }

    func clearSelection() {
        for i in annotations.indices { annotations[i].isSelected = false }
    }

    var selectedAnnotation: Annotation? {
        annotations.last(where: \.isSelected)
    }

    var hasSelectedText: Bool {
        annotations.contains { $0.isSelected && $0.toolType == .text }
    }

    func syncToolbarFromSelection() {
        guard let selected = selectedAnnotation else { return }
        strokeColor = selected.color.swiftUIColor
        if selected.toolType == .text {
            fontSize = selected.fontSize
        } else {
            lineWidth = selected.lineWidth
        }
    }

    func applyStrokeColorToSelection(_ color: Color) {
        guard annotations.contains(where: \.isSelected) else { return }
        let nsColor = NSColor(color)
        for index in annotations.indices where annotations[index].isSelected {
            annotations[index].color = CodableColor(nsColor)
        }
    }

    func applyFontSizeToSelection(_ size: CGFloat) {
        guard hasSelectedText else { return }
        for index in annotations.indices where annotations[index].isSelected && annotations[index].toolType == .text {
            annotations[index].fontSize = size
            var rect = annotations[index].textBounds()
            if rect.height < size * 2 {
                rect.size.height = size * 2
                annotations[index].startPoint = CGPoint(x: rect.minX, y: rect.minY)
                annotations[index].endPoint = CGPoint(x: rect.maxX, y: rect.maxY)
            }
        }
    }

    func applyLineWidthToSelection(_ width: CGFloat) {
        guard annotations.contains(where: \.isSelected) else { return }
        for index in annotations.indices where annotations[index].isSelected && annotations[index].toolType != .text {
            annotations[index].lineWidth = width
        }
    }

    func transformForCrop(_ cropRect: CGRect) {
        let dx = cropRect.origin.x
        let dy = cropRect.origin.y
        let croppedSize = cropRect.size

        annotations = annotations.compactMap { annotation in
            var ann = annotation
            ann.startPoint = CGPoint(x: ann.startPoint.x - dx, y: ann.startPoint.y - dy)
            ann.endPoint = CGPoint(x: ann.endPoint.x - dx, y: ann.endPoint.y - dy)
            ann.points = ann.points.map { CGPoint(x: $0.x - dx, y: $0.y - dy) }

            let bounds = ann.bounds
            guard bounds.maxX > 0, bounds.maxY > 0,
                  bounds.minX < croppedSize.width, bounds.minY < croppedSize.height else {
                return nil
            }
            return ann
        }
    }
}

// MARK: - Canvas View

struct AnnotationCanvasView: View {
    let baseImage: NSImage
    @ObservedObject var state: AnnotationCanvasState
    var onCropFinished: ((CGRect) -> Void)? = nil

    @State private var inProgress: Annotation? = nil
    @State private var pencilPoints: [CGPoint] = []
    @State private var dragStart: CGPoint = .zero
    @State private var editingTextID: UUID? = nil
    @State private var textInput: String = ""
    @State private var cropRect: CGRect? = nil
    @State private var suppressNextTap = false
    @State private var moveDrag: MoveDragState? = nil
    @State private var resizeDrag: ResizeDragState? = nil

    private struct MoveDragState {
        let anchor: CGPoint
        let snapshots: [UUID: Annotation.Snapshot]
        var undoRecorded = false
    }

    private struct ResizeDragState {
        let annotationID: UUID
        let handle: ResizeHandle
        let snapshot: Annotation.Snapshot
        let originalBounds: CGRect
        var undoRecorded = false
    }

    var body: some View {
        GeometryReader { geo in
            let frame = imageFrame(in: geo.size)
            let scale = imageScale(imageSize: baseImage.size, viewSize: geo.size)

            ZStack(alignment: .topLeading) {
                // Base image
                Image(nsImage: baseImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: geo.size.width, height: geo.size.height)

                // Spotlight overlays (blurred + dimmed outside focus area)
                ForEach(state.annotations.filter { $0.toolType == .spotlight }) { ann in
                    spotlightOverlay(for: ann, frame: frame, scale: scale, containerSize: geo.size)
                }
                if let ip = inProgress, ip.toolType == .spotlight {
                    spotlightOverlay(for: ip, frame: frame, scale: scale, containerSize: geo.size)
                }

                // Committed annotations
                Canvas { ctx, size in
                    let canvasFrame = imageFrame(in: size)
                    let canvasScale = imageScale(imageSize: baseImage.size, viewSize: size)
                    for ann in state.annotations where ann.toolType != .spotlight {
                        drawAnnotation(ann, in: ctx, frame: canvasFrame, scale: canvasScale)
                    }
                    if let ip = inProgress, ip.toolType != .spotlight {
                        drawAnnotation(ip, in: ctx, frame: canvasFrame, scale: canvasScale)
                    }
                    if state.currentTool == .select {
                        for ann in state.annotations where ann.toolType == .spotlight && ann.isSelected {
                            drawSelectionChrome(for: ann, in: &ctx, frame: canvasFrame, scale: canvasScale)
                        }
                    }
                }

                // Text input overlay
                if let tid = editingTextID,
                   let ann = state.annotations.first(where: { $0.id == tid }) {
                    let viewRect = textViewRect(for: ann, frame: frame, scale: scale)

                    AnnotationTextInput(
                        text: $textInput,
                        fontSize: ann.fontSize * scale,
                        color: ann.color.nsColor,
                        onCommit: { commitTextEdit() }
                    )
                    .frame(width: viewRect.width, height: viewRect.height)
                    .offset(x: viewRect.minX, y: viewRect.minY)
                }

                // Crop overlay
                if state.currentTool == .crop, cropRect != nil {
                    CropOverlayView(
                        cropRect: Binding(
                            get: { cropRect ?? CGRect(origin: .zero, size: baseImage.size) },
                            set: { cropRect = $0 }
                        ),
                        imageBounds: CGRect(origin: .zero, size: baseImage.size),
                        imageFrame: frame,
                        scale: scale,
                        viewSize: geo.size,
                        onApply: {
                            if let rect = cropRect {
                                onCropFinished?(rect)
                            }
                            cropRect = nil
                            state.currentTool = .select
                        },
                        onCancel: {
                            cropRect = nil
                            state.currentTool = .select
                        }
                    )
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .onChange(of: state.currentTool) { _, newTool in
                if newTool == .crop {
                    cropRect = CGRect(origin: .zero, size: baseImage.size)
                } else {
                    cropRect = nil
                }
            }
            .gesture(
                editingTextID == nil && state.currentTool != .crop
                    ? DragGesture(minimumDistance: 0)
                        .onChanged { val in handleDragChanged(val, in: geo.size) }
                        .onEnded   { val in handleDragEnded(val, in: geo.size) }
                    : nil
            )
            .onTapGesture { pt in handleTap(at: pt, in: geo.size) }
        }
    }

    // MARK: - Gesture Handlers

    private func handleDragChanged(_ val: DragGesture.Value, in viewSize: CGSize) {
        guard editingTextID == nil else { return }

        let frame = imageFrame(in: viewSize)
        let scale = imageScale(imageSize: baseImage.size, viewSize: viewSize)
        let start = unscaledPoint(val.startLocation, frame: frame, scale: scale)
        let cur   = unscaledPoint(val.location, frame: frame, scale: scale)

        switch state.currentTool {
        case .select:
            handleSelectDrag(from: start, to: cur)

        case .pencil:
            if inProgress == nil {
                state.pushUndo()
                pencilPoints = [start]
                inProgress = Annotation(toolType: .pencil, color: NSColor(state.strokeColor), lineWidth: state.lineWidth, points: pencilPoints)
            }
            pencilPoints.append(cur)
            inProgress?.points = pencilPoints

        case .text:
            if inProgress == nil {
                if let index = hitTestAnnotation(at: start), state.annotations[index].toolType == .text {
                    beginTextEditing(id: state.annotations[index].id)
                    suppressNextTap = true
                    return
                }
                state.pushUndo()
                dragStart = start
            }
            var ann = Annotation(
                toolType: .text,
                startPoint: dragStart,
                endPoint: cur,
                color: NSColor(state.strokeColor),
                lineWidth: state.lineWidth,
                fontSize: state.fontSize
            )
            ann.id = inProgress?.id ?? UUID()
            inProgress = ann

        default:
            if inProgress == nil {
                state.pushUndo()
                dragStart = start
            }
            var ann = Annotation(
                toolType: state.currentTool,
                startPoint: dragStart,
                endPoint: cur,
                color: NSColor(state.strokeColor),
                lineWidth: state.lineWidth,
                text: "",
                fontSize: state.fontSize,
                arrowStyle: state.arrowStyle
            )
            ann.id = inProgress?.id ?? UUID()
            inProgress = ann
        }
    }

    private func handleDragEnded(_ val: DragGesture.Value, in viewSize: CGSize) {
        if let ip = inProgress {
            if ip.toolType != .crop {
                var committed = ip
                if ip.toolType == .text {
                    committed = normalizedTextAnnotation(ip)
                } else if ip.toolType == .spotlight {
                    committed = normalizedSpotlightAnnotation(ip)
                }
                state.annotations.append(committed)
                if ip.toolType == .text {
                    beginTextEditing(id: committed.id)
                    suppressNextTap = true
                }
            }
        }
        inProgress = nil
        pencilPoints = []
        moveDrag = nil
        resizeDrag = nil
    }

    private func handleSelectDrag(from start: CGPoint, to current: CGPoint) {
        if moveDrag == nil, resizeDrag == nil {
            let tolerance = 10.0
            for annotation in state.annotations.reversed() where annotation.isResizable {
                if let handle = ResizeHandle.hitTest(at: start, in: annotation.bounds, tolerance: tolerance) {
                    if let index = state.annotations.firstIndex(where: { $0.id == annotation.id }) {
                        state.clearSelection()
                        state.annotations[index].isSelected = true
                        state.syncToolbarFromSelection()
                    }
                    resizeDrag = ResizeDragState(
                        annotationID: annotation.id,
                        handle: handle,
                        snapshot: annotation.snapshot,
                        originalBounds: annotation.bounds
                    )
                    return
                }
            }

            if let index = hitTestAnnotation(at: start) {
                if !state.annotations[index].isSelected {
                    state.clearSelection()
                    state.annotations[index].isSelected = true
                    state.syncToolbarFromSelection()
                }
                let snapshots = Dictionary(
                    uniqueKeysWithValues: state.annotations
                        .filter(\.isSelected)
                        .map { ($0.id, $0.snapshot) }
                )
                moveDrag = MoveDragState(anchor: start, snapshots: snapshots)
            } else {
                state.clearSelection()
            }
            return
        }

        if var drag = resizeDrag,
           let index = state.annotations.firstIndex(where: { $0.id == drag.annotationID }) {
            let newBounds = ResizeHandle.resizeBounds(drag.originalBounds, handle: drag.handle, to: current)
            guard abs(newBounds.width - drag.originalBounds.width) > 0.5
                    || abs(newBounds.height - drag.originalBounds.height) > 0.5 else { return }

            if !drag.undoRecorded {
                state.pushUndo()
                drag.undoRecorded = true
            }

            state.annotations[index].applyResizedBounds(newBounds, from: drag.snapshot)
            if state.annotations[index].toolType == .text {
                state.annotations[index] = normalizedTextAnnotation(state.annotations[index])
            }
            resizeDrag = drag
            return
        }

        guard var drag = moveDrag else { return }
        let delta = CGPoint(x: current.x - drag.anchor.x, y: current.y - drag.anchor.y)
        guard abs(delta.x) > 0.5 || abs(delta.y) > 0.5 else { return }

        if !drag.undoRecorded {
            state.pushUndo()
            drag.undoRecorded = true
        }

        for index in state.annotations.indices {
            guard let snapshot = drag.snapshots[state.annotations[index].id] else { continue }
            state.annotations[index].restore(from: snapshot, translatedBy: delta)
        }

        moveDrag = drag
    }

    private func hitTestAnnotation(at imagePoint: CGPoint) -> Int? {
        for index in state.annotations.indices.reversed() {
            if state.annotations[index].hitTest(imagePoint) {
                return index
            }
        }
        return nil
    }

    private func handleTap(at point: CGPoint, in viewSize: CGSize) {
        let frame = imageFrame(in: viewSize)
        let scale = imageScale(imageSize: baseImage.size, viewSize: viewSize)
        let imgPt = unscaledPoint(point, frame: frame, scale: scale)

        if suppressNextTap {
            suppressNextTap = false
            return
        }

        if editingTextID != nil {
            commitTextEdit()
            return
        }

        if state.currentTool == .text {
            if let index = hitTestAnnotation(at: imgPt), state.annotations[index].toolType == .text {
                beginTextEditing(id: state.annotations[index].id)
                return
            }

            state.pushUndo()
            let end = CGPoint(x: imgPt.x + 160, y: imgPt.y + state.fontSize * 2)
            let ann = normalizedTextAnnotation(Annotation(
                toolType: .text,
                startPoint: imgPt,
                endPoint: end,
                color: NSColor(state.strokeColor),
                lineWidth: state.lineWidth,
                fontSize: state.fontSize
            ))
            state.annotations.append(ann)
            beginTextEditing(id: ann.id)
            return
        }

        if state.currentTool == .select {
            state.clearSelection()
            if let index = hitTestAnnotation(at: imgPt) {
                state.annotations[index].isSelected = true
                state.syncToolbarFromSelection()
            }
        }
    }

    private func beginTextEditing(id: UUID) {
        state.clearSelection()
        guard let index = state.annotations.firstIndex(where: { $0.id == id }) else { return }
        state.annotations[index].isSelected = true
        state.syncToolbarFromSelection()
        editingTextID = id
        textInput = state.annotations[index].text
    }

    private func commitTextEdit() {
        guard let tid = editingTextID else { return }
        if let i = state.annotations.firstIndex(where: { $0.id == tid }) {
            if textInput.isEmpty {
                state.annotations.remove(at: i)
            } else {
                state.annotations[i].text = textInput
                state.annotations[i] = normalizedTextAnnotation(state.annotations[i])
            }
        }
        editingTextID = nil
        textInput = ""
        state.clearSelection()
    }

    // MARK: - Drawing

    private func drawAnnotation(_ ann: Annotation, in ctx: GraphicsContext, frame: CGRect, scale: CGFloat) {
        let color = ann.color.swiftUIColor
        let start = scaledPoint(ann.startPoint, frame: frame, scale: scale)
        let end   = scaledPoint(ann.endPoint, frame: frame, scale: scale)
        let lw    = ann.lineWidth * scale

        var ctx = ctx

        switch ann.toolType {
        case .arrow:
            drawArrow(from: start, to: end, color: color, lineWidth: lw, style: ann.arrowStyle, in: &ctx)

        case .line:
            var path = Path(); path.move(to: start); path.addLine(to: end)
            ctx.stroke(path, with: .color(color), lineWidth: lw)

        case .rectangle:
            let rect = rectFrom(start, end)
            ctx.stroke(Path(rect), with: .color(color), lineWidth: lw)

        case .filledRect:
            let rect = rectFrom(start, end)
            ctx.fill(Path(rect), with: .color(color))

        case .ellipse:
            let rect = rectFrom(start, end)
            ctx.stroke(Path(ellipseIn: rect), with: .color(color), lineWidth: lw)

        case .filledEllipse:
            let rect = rectFrom(start, end)
            ctx.fill(Path(ellipseIn: rect), with: .color(color))

        case .text:
            let rect = textViewRect(for: ann, frame: frame, scale: scale)
            if !ann.text.isEmpty, ann.id != editingTextID {
                ctx.draw(
                    Text(ann.text)
                        .font(.system(size: ann.fontSize * scale))
                        .foregroundColor(color),
                    in: rect
                )
            }
            drawTextBoxOutline(rect, isEditing: ann.id == editingTextID, in: &ctx)

        case .highlighter:
            let rect = rectFrom(start, end)
            ctx.fill(Path(rect), with: .color(color.opacity(0.35)))

        case .pencil:
            drawPencil(ann.points.map { scaledPoint($0, frame: frame, scale: scale) }, color: color, lineWidth: lw, in: &ctx)

        case .spotlight:
            break

        case .crop, .select:
            break
        }

        if ann.isSelected, state.currentTool == .select {
            drawSelectionChrome(for: ann, in: &ctx, frame: frame, scale: scale)
        }
    }

    private func normalizedTextAnnotation(_ ann: Annotation) -> Annotation {
        var normalized = ann
        let rect = textRect(from: ann)
        normalized.startPoint = CGPoint(x: rect.minX, y: rect.minY)
        normalized.endPoint = CGPoint(x: rect.maxX, y: rect.maxY)
        return normalized
    }

    private func textRect(from ann: Annotation) -> CGRect {
        ann.textBounds()
    }

    private func drawTextBoxOutline(
        _ rect: CGRect,
        isEditing: Bool,
        in ctx: inout GraphicsContext
    ) {
        guard isEditing else { return }
        let outlineColor = Color(red: 0.45, green: 0.72, blue: 1.0)
        ctx.stroke(
            Path(rect),
            with: .color(outlineColor),
            style: StrokeStyle(lineWidth: 1, dash: [4, 3])
        )
    }

    private func drawSelectionChrome(
        for ann: Annotation,
        in ctx: inout GraphicsContext,
        frame: CGRect,
        scale: CGFloat
    ) {
        let scaledBounds = scaledSelectionBounds(for: ann, frame: frame, scale: scale)
        let outlineColor = Color(red: 0.45, green: 0.72, blue: 1.0)

        if ann.toolType == .spotlight {
            ctx.stroke(
                Path(ellipseIn: scaledBounds),
                with: .color(outlineColor),
                style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])
            )
        } else {
            ctx.stroke(
                Path(scaledBounds),
                with: .color(outlineColor),
                style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])
            )
        }

        guard ann.isResizable else { return }

        let handleSize = max(6, 8 * scale)
        for handle in ResizeHandle.allCases {
            let point = handle.point(in: scaledBounds)
            let handleRect = CGRect(
                x: point.x - handleSize / 2,
                y: point.y - handleSize / 2,
                width: handleSize,
                height: handleSize
            )
            ctx.fill(Path(handleRect), with: .color(.white))
            ctx.stroke(Path(handleRect), with: .color(outlineColor), lineWidth: 1)
        }
    }

    private func textViewRect(for ann: Annotation, frame: CGRect, scale: CGFloat) -> CGRect {
        scaledRect(textRect(from: ann), frame: frame, scale: scale)
    }

    private func drawArrow(from s: CGPoint, to e: CGPoint, color: Color, lineWidth: CGFloat, style: Int, in ctx: inout GraphicsContext) {
        var path = Path()
        path.move(to: s); path.addLine(to: e)
        ctx.stroke(path, with: .color(color), lineWidth: lineWidth)

        let angle  = atan2(e.y - s.y, e.x - s.x)
        let tipLen = max(lineWidth * 4, 12.0)
        let tipAngle = CGFloat.pi / 6

        var head = Path()
        head.move(to: e)
        head.addLine(to: CGPoint(x: e.x - tipLen * cos(angle - tipAngle),
                                 y: e.y - tipLen * sin(angle - tipAngle)))
        head.move(to: e)
        head.addLine(to: CGPoint(x: e.x - tipLen * cos(angle + tipAngle),
                                 y: e.y - tipLen * sin(angle + tipAngle)))
        ctx.stroke(head, with: .color(color), lineWidth: lineWidth)
    }

    private func spotlightOverlay(
        for ann: Annotation,
        frame: CGRect,
        scale: CGFloat,
        containerSize: CGSize
    ) -> some View {
        let geometry = SpotlightGeometry(annotation: ann)
        let cutoutRect = scaledRect(geometry.ellipseRect, frame: frame, scale: scale)

        return SpotlightOverlayView(
            baseImage: baseImage,
            cutoutRect: cutoutRect,
            imageFrame: frame,
            containerSize: containerSize
        )
    }

    private func scaledSelectionBounds(for ann: Annotation, frame: CGRect, scale: CGFloat) -> CGRect {
        if ann.toolType == .spotlight {
            return scaledRect(SpotlightGeometry(annotation: ann).ellipseRect, frame: frame, scale: scale)
        }
        return scaledRect(ann.bounds, frame: frame, scale: scale)
    }

    private func normalizedSpotlightAnnotation(_ ann: Annotation) -> Annotation {
        var normalized = ann
        let geometry = SpotlightGeometry(annotation: ann)
        normalized.startPoint = CGPoint(x: geometry.ellipseRect.minX, y: geometry.ellipseRect.minY)
        normalized.endPoint = CGPoint(x: geometry.ellipseRect.maxX, y: geometry.ellipseRect.maxY)
        return normalized
    }

    private func drawPencil(_ pts: [CGPoint], color: Color, lineWidth: CGFloat, in ctx: inout GraphicsContext) {
        guard pts.count > 1 else { return }
        var path = Path()
        path.move(to: pts[0])
        for pt in pts.dropFirst() { path.addLine(to: pt) }
        ctx.stroke(path, with: .color(color), lineWidth: lineWidth)
    }

    // MARK: - Coordinate helpers

    private func imageFrame(in viewSize: CGSize) -> CGRect {
        let scale = imageScale(imageSize: baseImage.size, viewSize: viewSize)
        let width = baseImage.size.width * scale
        let height = baseImage.size.height * scale
        return CGRect(
            x: (viewSize.width - width) / 2,
            y: (viewSize.height - height) / 2,
            width: width,
            height: height
        )
    }

    private func imageScale(imageSize: CGSize, viewSize: CGSize) -> CGFloat {
        min(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
    }

    private func scaledPoint(_ pt: CGPoint, frame: CGRect, scale: CGFloat) -> CGPoint {
        CGPoint(x: frame.minX + pt.x * scale, y: frame.minY + pt.y * scale)
    }

    private func unscaledPoint(_ pt: CGPoint, frame: CGRect, scale: CGFloat) -> CGPoint {
        CGPoint(x: (pt.x - frame.minX) / scale, y: (pt.y - frame.minY) / scale)
    }

    private func scaledRect(_ rect: CGRect, frame: CGRect, scale: CGFloat) -> CGRect {
        CGRect(
            x: frame.minX + rect.minX * scale,
            y: frame.minY + rect.minY * scale,
            width: rect.width * scale,
            height: rect.height * scale
        )
    }

    private func unscaledRect(_ rect: CGRect, frame: CGRect, scale: CGFloat) -> CGRect {
        CGRect(
            x: (rect.minX - frame.minX) / scale,
            y: (rect.minY - frame.minY) / scale,
            width: rect.width / scale,
            height: rect.height / scale
        )
    }

    private func rectFrom(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }
}

// MARK: - Spotlight Overlay

enum SpotlightStyle {
    static let blurRadius: CGFloat = 6
    static let dimOpacity: Double = 0.35
    static let minimumRadius: CGFloat = 40
}

struct SpotlightGeometry {
    let center: CGPoint
    let radius: CGFloat
    let ellipseRect: CGRect

    init(start: CGPoint, end: CGPoint, minimumRadius: CGFloat = SpotlightStyle.minimumRadius) {
        center = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        radius = max(hypot(end.x - start.x, end.y - start.y) / 2, minimumRadius)
        ellipseRect = CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        )
    }

    init(annotation: Annotation, minimumRadius: CGFloat = SpotlightStyle.minimumRadius) {
        self.init(start: annotation.startPoint, end: annotation.endPoint, minimumRadius: minimumRadius)
    }
}

private struct SpotlightOverlayView: View {
    let baseImage: NSImage
    let cutoutRect: CGRect
    let imageFrame: CGRect
    let containerSize: CGSize

    var body: some View {
        ZStack {
            Image(nsImage: baseImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: containerSize.width, height: containerSize.height)
                .blur(radius: SpotlightStyle.blurRadius)

            Color.black.opacity(SpotlightStyle.dimOpacity)
        }
        .frame(width: containerSize.width, height: containerSize.height)
        .mask(outsideSpotlightMask)
        .allowsHitTesting(false)
    }

    private var outsideSpotlightMask: some View {
        Rectangle()
            .frame(width: imageFrame.width, height: imageFrame.height)
            .position(x: imageFrame.midX, y: imageFrame.midY)
            .overlay {
                Ellipse()
                    .frame(width: cutoutRect.width, height: cutoutRect.height)
                    .position(x: cutoutRect.midX, y: cutoutRect.midY)
                    .blendMode(.destinationOut)
            }
            .compositingGroup()
    }
}

// MARK: - Text Input

private struct AnnotationTextInput: NSViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat
    var color: NSColor
    var onCommit: () -> Void

    func makeNSView(context: Context) -> NSTextView {
        let textView = NSTextView()
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textContainerInset = NSSize(width: 2, height: 2)
        textView.font = NSFont.systemFont(ofSize: fontSize)
        textView.textColor = color
        textView.string = text
        textView.delegate = context.coordinator
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
        }
        return textView
    }

    func updateNSView(_ textView: NSTextView, context: Context) {
        if textView.string != text {
            textView.string = text
        }
        textView.font = NSFont.systemFont(ofSize: fontSize)
        textView.textColor = color
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onCommit: onCommit)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var onCommit: () -> Void

        init(text: Binding<String>, onCommit: @escaping () -> Void) {
            self.text = text
            self.onCommit = onCommit
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                onCommit()
                return true
            }
            return false
        }
    }
}

// MARK: - Crop Overlay

enum CropHandle: CaseIterable, Hashable {
    case topLeft, top, topRight, left, right, bottomLeft, bottom, bottomRight

    static let hitThickness: CGFloat = 28

    var cursor: NSCursor {
        if #available(macOS 15.0, *) {
            return Self.modernCursor(for: self)
        }
        switch self {
        case .topLeft, .bottomRight, .topRight, .bottomLeft: return .crosshair
        case .top, .bottom: return .resizeUpDown
        case .left, .right: return .resizeLeftRight
        }
    }

    @available(macOS 15.0, *)
    private static func modernCursor(for handle: CropHandle) -> NSCursor {
        let position: NSCursor.FrameResizePosition
        switch handle {
        case .topLeft:     position = .topLeft
        case .top:         position = .top
        case .topRight:    position = .topRight
        case .left:        position = .left
        case .right:       position = .right
        case .bottomLeft:  position = .bottomLeft
        case .bottom:      position = .bottom
        case .bottomRight: position = .bottomRight
        }
        return NSCursor.frameResize(position: position, directions: .all)
    }

    func point(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft:     return CGPoint(x: rect.minX, y: rect.minY)
        case .top:         return CGPoint(x: rect.midX, y: rect.minY)
        case .topRight:    return CGPoint(x: rect.maxX, y: rect.minY)
        case .left:        return CGPoint(x: rect.minX, y: rect.midY)
        case .right:       return CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomLeft:  return CGPoint(x: rect.minX, y: rect.maxY)
        case .bottom:      return CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }

    /// Generous view-space hit zone for each handle or edge.
    func hitZone(in viewRect: CGRect, thickness: CGFloat = CropHandle.hitThickness) -> CGRect {
        let half = thickness / 2
        switch self {
        case .topLeft:
            return CGRect(x: viewRect.minX - half, y: viewRect.minY - half, width: thickness, height: thickness)
        case .topRight:
            return CGRect(x: viewRect.maxX - half, y: viewRect.minY - half, width: thickness, height: thickness)
        case .bottomLeft:
            return CGRect(x: viewRect.minX - half, y: viewRect.maxY - half, width: thickness, height: thickness)
        case .bottomRight:
            return CGRect(x: viewRect.maxX - half, y: viewRect.maxY - half, width: thickness, height: thickness)
        case .top:
            return CGRect(
                x: viewRect.minX + half,
                y: viewRect.minY - half,
                width: max(0, viewRect.width - thickness),
                height: thickness
            )
        case .bottom:
            return CGRect(
                x: viewRect.minX + half,
                y: viewRect.maxY - half,
                width: max(0, viewRect.width - thickness),
                height: thickness
            )
        case .left:
            return CGRect(
                x: viewRect.minX - half,
                y: viewRect.minY + half,
                width: thickness,
                height: max(0, viewRect.height - thickness)
            )
        case .right:
            return CGRect(
                x: viewRect.maxX - half,
                y: viewRect.minY + half,
                width: thickness,
                height: max(0, viewRect.height - thickness)
            )
        }
    }

    static func hitTest(at viewPoint: CGPoint, in viewRect: CGRect, thickness: CGFloat = CropHandle.hitThickness) -> CropHandle? {
        guard viewRect.width > 0, viewRect.height > 0 else { return nil }

        for handle in [CropHandle.topLeft, .topRight, .bottomLeft, .bottomRight, .top, .bottom, .left, .right] {
            if handle.hitZone(in: viewRect, thickness: thickness).contains(viewPoint) {
                return handle
            }
        }
        return nil
    }

    static func resizeRect(
        _ original: CGRect,
        handle: CropHandle,
        to point: CGPoint,
        within bounds: CGRect,
        minSize: CGFloat = 24
    ) -> CGRect {
        var minX = original.minX
        var maxX = original.maxX
        var minY = original.minY
        var maxY = original.maxY

        switch handle {
        case .topLeft:
            minX = min(point.x, maxX - minSize)
            minY = min(point.y, maxY - minSize)
        case .top:
            minY = min(point.y, maxY - minSize)
        case .topRight:
            maxX = max(point.x, minX + minSize)
            minY = min(point.y, maxY - minSize)
        case .left:
            minX = min(point.x, maxX - minSize)
        case .right:
            maxX = max(point.x, minX + minSize)
        case .bottomLeft:
            minX = min(point.x, maxX - minSize)
            maxY = max(point.y, minY + minSize)
        case .bottom:
            maxY = max(point.y, minY + minSize)
        case .bottomRight:
            maxX = max(point.x, minX + minSize)
            maxY = max(point.y, minY + minSize)
        }

        var rect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        rect = rect.intersection(bounds)

        if rect.width < minSize { rect.size.width = minSize }
        if rect.height < minSize { rect.size.height = minSize }
        if rect.maxX > bounds.maxX { rect.origin.x = bounds.maxX - rect.width }
        if rect.maxY > bounds.maxY { rect.origin.y = bounds.maxY - rect.height }
        if rect.minX < bounds.minX { rect.origin.x = bounds.minX }
        if rect.minY < bounds.minY { rect.origin.y = bounds.minY }

        return rect
    }

    static func movedRect(_ rect: CGRect, by delta: CGPoint, within bounds: CGRect) -> CGRect {
        var moved = rect.offsetBy(dx: delta.x, dy: delta.y)
        if moved.minX < bounds.minX { moved.origin.x = bounds.minX }
        if moved.minY < bounds.minY { moved.origin.y = bounds.minY }
        if moved.maxX > bounds.maxX { moved.origin.x = bounds.maxX - moved.width }
        if moved.maxY > bounds.maxY { moved.origin.y = bounds.maxY - moved.height }
        return moved
    }
}

private struct CropOverlayView: View {
    @Binding var cropRect: CGRect
    let imageBounds: CGRect
    let imageFrame: CGRect
    let scale: CGFloat
    let viewSize: CGSize
    var onApply: () -> Void
    var onCancel: () -> Void

    @State private var dragState: CropDragState? = nil
    @State private var hoveredHandle: CropHandle? = nil
    @State private var isHoveringMoveRegion = false

    private struct CropDragState {
        enum Mode {
            case move(anchor: CGPoint, startRect: CGRect)
            case resize(handle: CropHandle, startRect: CGRect)
        }
        let mode: Mode
    }

    private var viewRect: CGRect {
        scaledCropRect(cropRect)
    }

    var body: some View {
        ZStack {
            ZStack {
                dimmedMask

                Rectangle()
                    .stroke(Color.white, lineWidth: 1.5)
                    .frame(width: viewRect.width, height: viewRect.height)
                    .position(x: viewRect.midX, y: viewRect.midY)

                ruleOfThirdsGrid

                cropMoveZone

                ForEach([CropHandle.top, .bottom, .left, .right], id: \.self) { handle in
                    cropHandleHitZone(handle)
                }

                ForEach([CropHandle.topLeft, .topRight, .bottomLeft, .bottomRight], id: \.self) { handle in
                    cropHandleHitZone(handle)
                }

                ForEach(CropHandle.allCases, id: \.self) { handle in
                    cropHandle(at: handle.point(in: viewRect))
                }
            }
            .onContinuousHover { phase in
                updateHoverCursor(phase)
            }

            cropControls
                .position(
                    x: viewRect.midX,
                    y: min(viewRect.maxY + 36, viewSize.height - 28)
                )
        }
        .frame(width: viewSize.width, height: viewSize.height)
    }

    private var cropMoveZone: some View {
        let inset = CropHandle.hitThickness
        let inner = viewRect.insetBy(dx: inset, dy: inset)
        return Group {
            if inner.width > 0, inner.height > 0 {
                Color.clear
                    .frame(width: inner.width, height: inner.height)
                    .position(x: inner.midX, y: inner.midY)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                handleMoveDrag(value)
                            }
                            .onEnded { _ in
                                dragState = nil
                            }
                    )
            }
        }
    }

    private func cropHandleHitZone(_ handle: CropHandle) -> some View {
        let zone = handle.hitZone(in: viewRect)
        return Color.clear
            .frame(width: max(zone.width, 1), height: max(zone.height, 1))
            .position(x: zone.midX, y: zone.midY)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        handleResizeDrag(value, handle: handle)
                    }
                    .onEnded { _ in
                        dragState = nil
                    }
            )
    }

    private func updateHoverCursor(_ phase: HoverPhase) {
        guard dragState == nil else { return }

        switch phase {
        case .active(let location):
            if let handle = CropHandle.hitTest(at: location, in: viewRect) {
                isHoveringMoveRegion = false
                if hoveredHandle != handle {
                    hoveredHandle = handle
                    handle.cursor.set()
                }
            } else {
                hoveredHandle = nil
                let inner = viewRect.insetBy(dx: CropHandle.hitThickness, dy: CropHandle.hitThickness)
                if inner.contains(location) {
                    if !isHoveringMoveRegion {
                        isHoveringMoveRegion = true
                        NSCursor.openHand.set()
                    }
                } else {
                    isHoveringMoveRegion = false
                    NSCursor.arrow.set()
                }
            }
        case .ended:
            hoveredHandle = nil
            isHoveringMoveRegion = false
            NSCursor.arrow.set()
        }
    }

    private var dimmedMask: some View {
        Color.black.opacity(0.5)
            .frame(width: viewSize.width, height: viewSize.height)
            .mask {
                Rectangle()
                    .overlay {
                        Rectangle()
                            .frame(width: viewRect.width, height: viewRect.height)
                            .position(x: viewRect.midX, y: viewRect.midY)
                            .blendMode(.destinationOut)
                    }
                    .compositingGroup()
            }
            .allowsHitTesting(false)
    }

    private var ruleOfThirdsGrid: some View {
        Canvas { context, _ in
            let rect = viewRect
            guard rect.width > 0, rect.height > 0 else { return }

            var path = Path()
            for fraction in [1.0 / 3.0, 2.0 / 3.0] {
                let x = rect.minX + rect.width * fraction
                path.move(to: CGPoint(x: x, y: rect.minY))
                path.addLine(to: CGPoint(x: x, y: rect.maxY))

                let y = rect.minY + rect.height * fraction
                path.move(to: CGPoint(x: rect.minX, y: y))
                path.addLine(to: CGPoint(x: rect.maxX, y: y))
            }
            context.stroke(path, with: .color(.white.opacity(0.35)), lineWidth: 0.75)
        }
        .allowsHitTesting(false)
    }

    private func cropHandle(at point: CGPoint) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color.white)
                .frame(width: 10, height: 10)
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .stroke(Color.black.opacity(0.25), lineWidth: 0.5)
                .frame(width: 10, height: 10)
        }
        .position(x: point.x, y: point.y)
        .allowsHitTesting(false)
    }

    private var cropControls: some View {
        HStack(spacing: 10) {
            Button("Cancel", action: onCancel)
                .buttonStyle(CropSecondaryButtonStyle())

            Button("Apply", action: onApply)
                .buttonStyle(CropPrimaryButtonStyle())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(ToolbarBlurBackground())
        .clipShape(Capsule())
        .overlay {
            Capsule()
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
    }

    private func handleResizeDrag(_ value: DragGesture.Value, handle: CropHandle) {
        if dragState == nil {
            dragState = CropDragState(mode: .resize(handle: handle, startRect: cropRect))
            handle.cursor.set()
        }

        let current = unscaledPoint(value.location)
        if case .resize(_, let startRect) = dragState!.mode {
            cropRect = CropHandle.resizeRect(startRect, handle: handle, to: current, within: imageBounds)
        }
    }

    private func handleMoveDrag(_ value: DragGesture.Value) {
        let start = unscaledPoint(value.startLocation)
        let current = unscaledPoint(value.location)

        if dragState == nil {
            dragState = CropDragState(mode: .move(anchor: start, startRect: cropRect))
            NSCursor.closedHand.set()
        }

        if case .move(let anchor, let startRect) = dragState!.mode {
            let delta = CGPoint(x: current.x - anchor.x, y: current.y - anchor.y)
            cropRect = CropHandle.movedRect(startRect, by: delta, within: imageBounds)
        }
    }

    private func scaledCropRect(_ rect: CGRect) -> CGRect {
        CGRect(
            x: imageFrame.minX + rect.minX * scale,
            y: imageFrame.minY + rect.minY * scale,
            width: rect.width * scale,
            height: rect.height * scale
        )
    }

    private func unscaledPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: (point.x - imageFrame.minX) / scale,
            y: (point.y - imageFrame.minY) / scale
        )
    }
}

private struct CropPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.callout, weight: .semibold))
            .foregroundStyle(.black)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(Color.white.opacity(configuration.isPressed ? 0.85 : 1))
            .clipShape(Capsule())
    }
}

private struct CropSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.callout, weight: .medium))
            .foregroundStyle(Color.white.opacity(configuration.isPressed ? 0.65 : 0.85))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Color.white.opacity(configuration.isPressed ? 0.14 : 0.08))
            .clipShape(Capsule())
    }
}
