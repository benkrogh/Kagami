import Foundation
import AppKit
import SwiftUI

// MARK: - Tool Types

enum AnnotationToolType: String, CaseIterable, Codable {
    case select, arrow, line, rectangle, filledRect, ellipse, filledEllipse
    case text, highlighter, pencil, spotlight, crop

    var displayName: String {
        switch self {
        case .select:       return "Select"
        case .arrow:        return "Arrow"
        case .line:         return "Line"
        case .rectangle:    return "Rectangle"
        case .filledRect:   return "Filled Rect"
        case .ellipse:      return "Ellipse"
        case .filledEllipse:return "Filled Ellipse"
        case .text:         return "Text"
        case .highlighter:  return "Highlight"
        case .pencil:       return "Pencil"
        case .spotlight:    return "Spotlight"
        case .crop:         return "Crop"
        }
    }

    var sfSymbol: String {
        switch self {
        case .select:        return "cursorarrow"
        case .arrow:         return "arrow.up.right"
        case .line:          return "line.diagonal"
        case .rectangle:     return "rectangle"
        case .filledRect:    return "rectangle.fill"
        case .ellipse:       return "circle"
        case .filledEllipse: return "circle.fill"
        case .text:          return "textformat"
        case .highlighter:   return "highlighter"
        case .pencil:        return "pencil"
        case .spotlight:     return "light.max"
        case .crop:          return "crop"
        }
    }
}

// MARK: - Codable Color

struct CodableColor: Codable, Equatable {
    var r: Double, g: Double, b: Double, a: Double

    init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? color
        r = c.redComponent; g = c.greenComponent
        b = c.blueComponent; a = c.alphaComponent
    }

    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
    var swiftUIColor: Color { Color(nsColor) }
}

// MARK: - Annotation Model

struct Annotation: Identifiable, Codable {
    var id = UUID()
    var toolType: AnnotationToolType
    var startPoint: CGPoint
    var endPoint: CGPoint
    var color: CodableColor
    var fillColor: CodableColor?
    var lineWidth: CGFloat
    var text: String
    var fontSize: CGFloat
    var points: [CGPoint]          // pencil strokes
    var arrowStyle: Int            // 0–3
    var isSelected: Bool = false

    init(
        toolType: AnnotationToolType,
        startPoint: CGPoint = .zero,
        endPoint: CGPoint = .zero,
        color: NSColor = .systemRed,
        fillColor: NSColor? = nil,
        lineWidth: CGFloat = 3,
        text: String = "",
        fontSize: CGFloat = 18,
        points: [CGPoint] = [],
        arrowStyle: Int = 0
    ) {
        self.toolType     = toolType
        self.startPoint   = startPoint
        self.endPoint     = endPoint
        self.color        = CodableColor(color)
        self.fillColor    = fillColor.map { CodableColor($0) }
        self.lineWidth    = lineWidth
        self.text         = text
        self.fontSize     = fontSize
        self.points       = points
        self.arrowStyle   = arrowStyle
    }

    var bounds: CGRect {
        if toolType == .text {
            return textBounds()
        }
        if toolType == .spotlight {
            return SpotlightGeometry(annotation: self).ellipseRect
        }
        if !points.isEmpty {
            let xs = points.map(\.x), ys = points.map(\.y)
            return CGRect(
                x: xs.min()!, y: ys.min()!,
                width: xs.max()! - xs.min()!,
                height: ys.max()! - ys.min()!
            ).insetBy(dx: -lineWidth, dy: -lineWidth)
        }
        return CGRect(
            x: min(startPoint.x, endPoint.x),
            y: min(startPoint.y, endPoint.y),
            width: abs(endPoint.x - startPoint.x),
            height: abs(endPoint.y - startPoint.y)
        ).insetBy(dx: -lineWidth, dy: -lineWidth)
    }

    func textBounds() -> CGRect {
        var rect = CGRect(
            x: min(startPoint.x, endPoint.x),
            y: min(startPoint.y, endPoint.y),
            width: abs(endPoint.x - startPoint.x),
            height: abs(endPoint.y - startPoint.y)
        )
        rect.size.width = max(rect.width, 120)
        rect.size.height = max(rect.height, fontSize * 2)
        return rect
    }

    func hitTest(_ point: CGPoint) -> Bool {
        if toolType == .spotlight {
            let geometry = SpotlightGeometry(annotation: self)
            return hypot(point.x - geometry.center.x, point.y - geometry.center.y) <= geometry.radius
        }
        return bounds.contains(point)
    }

    struct Snapshot {
        let startPoint: CGPoint
        let endPoint: CGPoint
        let points: [CGPoint]
    }

    var snapshot: Snapshot {
        Snapshot(startPoint: startPoint, endPoint: endPoint, points: points)
    }

    mutating func restore(from snapshot: Snapshot, translatedBy delta: CGPoint) {
        startPoint = CGPoint(x: snapshot.startPoint.x + delta.x, y: snapshot.startPoint.y + delta.y)
        endPoint = CGPoint(x: snapshot.endPoint.x + delta.x, y: snapshot.endPoint.y + delta.y)
        points = snapshot.points.map { CGPoint(x: $0.x + delta.x, y: $0.y + delta.y) }
    }

    var isResizable: Bool {
        switch toolType {
        case .arrow, .line, .rectangle, .filledRect, .ellipse, .filledEllipse,
             .text, .highlighter, .spotlight, .pencil:
            return true
        default:
            return false
        }
    }

    mutating func applyResizedBounds(_ rect: CGRect, from snapshot: Snapshot) {
        var original = self
        original.restore(from: snapshot, translatedBy: .zero)
        let oldBounds = original.bounds
        guard rect.width > 4, rect.height > 4 else { return }

        switch toolType {
        case .pencil:
            guard !snapshot.points.isEmpty, oldBounds.width > 0, oldBounds.height > 0 else { return }
            let scaleX = rect.width / oldBounds.width
            let scaleY = rect.height / oldBounds.height
            points = snapshot.points.map {
                CGPoint(
                    x: rect.minX + ($0.x - oldBounds.minX) * scaleX,
                    y: rect.minY + ($0.y - oldBounds.minY) * scaleY
                )
            }
        case .spotlight:
            let side = max(rect.width, rect.height)
            let center = CGPoint(x: rect.midX, y: rect.midY)
            startPoint = CGPoint(x: center.x - side / 2, y: center.y - side / 2)
            endPoint = CGPoint(x: center.x + side / 2, y: center.y + side / 2)
        default:
            startPoint = CGPoint(x: rect.minX, y: rect.minY)
            endPoint = CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }
}

enum ResizeHandle: CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight

    func point(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft:     return CGPoint(x: rect.minX, y: rect.minY)
        case .topRight:    return CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomLeft:  return CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }

    static func resizeBounds(_ original: CGRect, handle: ResizeHandle, to point: CGPoint, minSize: CGFloat = 8) -> CGRect {
        var minX = original.minX
        var maxX = original.maxX
        var minY = original.minY
        var maxY = original.maxY

        switch handle {
        case .topLeft:
            minX = min(point.x, maxX - minSize)
            minY = min(point.y, maxY - minSize)
        case .topRight:
            maxX = max(point.x, minX + minSize)
            minY = min(point.y, maxY - minSize)
        case .bottomLeft:
            minX = min(point.x, maxX - minSize)
            maxY = max(point.y, minY + minSize)
        case .bottomRight:
            maxX = max(point.x, minX + minSize)
            maxY = max(point.y, minY + minSize)
        }

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    static func hitTest(at point: CGPoint, in bounds: CGRect, tolerance: CGFloat) -> ResizeHandle? {
        for handle in allCases {
            let handlePoint = handle.point(in: bounds)
            let hitRect = CGRect(
                x: handlePoint.x - tolerance,
                y: handlePoint.y - tolerance,
                width: tolerance * 2,
                height: tolerance * 2
            )
            if hitRect.contains(point) { return handle }
        }
        return nil
    }
}
