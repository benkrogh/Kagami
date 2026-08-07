import SwiftUI
import AppKit

struct BackgroundToolView: View {
    let screenshot: NSImage
    @State private var selectedBackground: BackgroundStyle = .gradient1
    @State private var padding: CGFloat = 40
    @State private var aspectRatio: AspectRatioPreset = .original
    @State private var alignment: Alignment = .center
    var onExport: ((NSImage) -> Void)?
    var onDismiss: (() -> Void)?

    enum BackgroundStyle: String, CaseIterable {
        case gradient1, gradient2, gradient3, gradient4, gradient5
        case solid_white = "White", solid_black = "Black", solid_gray = "Gray"
        case custom

        var displayName: String { rawValue }

        var view: AnyView {
            switch self {
            case .gradient1: return AnyView(LinearGradient(colors: [.purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
            case .gradient2: return AnyView(LinearGradient(colors: [.orange, .pink], startPoint: .topLeading, endPoint: .bottomTrailing))
            case .gradient3: return AnyView(LinearGradient(colors: [.teal, .green], startPoint: .top, endPoint: .bottom))
            case .gradient4: return AnyView(LinearGradient(colors: [.indigo, .purple, .pink], startPoint: .topLeading, endPoint: .bottomTrailing))
            case .gradient5: return AnyView(LinearGradient(colors: [.yellow, .orange, .red], startPoint: .leading, endPoint: .trailing))
            case .solid_white: return AnyView(Color.white)
            case .solid_black: return AnyView(Color.black)
            case .solid_gray:  return AnyView(Color.gray)
            case .custom:      return AnyView(Color.blue)
            }
        }
    }

    enum AspectRatioPreset: String, CaseIterable {
        case original = "Original"
        case square   = "1:1"
        case wide16_9 = "16:9"
        case twitter  = "Twitter"
        case instagram = "Instagram"

        var ratio: CGFloat? {
            switch self {
            case .original:  return nil
            case .square:    return 1.0
            case .wide16_9:  return 16/9
            case .twitter:   return 2.0
            case .instagram: return 1.0
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Preview
            GeometryReader { geo in
                let canvas = canvasSize(for: geo.size)
                ZStack {
                    Color(NSColor.controlBackgroundColor)
                    selectedBackground.view
                        .frame(width: canvas.width, height: canvas.height)
                        .cornerRadius(8)
                    Image(nsImage: screenshot)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(
                            width: canvas.width - padding * 2,
                            height: canvas.height - padding * 2
                        )
                        .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
                }
                .frame(width: canvas.width, height: canvas.height)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Controls panel
            VStack(alignment: .leading, spacing: 16) {
                Text("Background")
                    .font(.headline)

                // Background styles
                Text("Style").font(.caption).foregroundColor(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3), spacing: 4) {
                    ForEach(BackgroundStyle.allCases, id: \.self) { style in
                        if style != .custom {
                            style.view
                                .frame(height: 36)
                                .cornerRadius(6)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(selectedBackground == style ? Color.accentColor : .clear, lineWidth: 2)
                                )
                                .onTapGesture { selectedBackground = style }
                        }
                    }
                }

                Divider()

                // Padding
                VStack(alignment: .leading) {
                    HStack {
                        Text("Padding").font(.caption).foregroundColor(.secondary)
                        Spacer()
                        Text("\(Int(padding))px").font(.caption)
                    }
                    Slider(value: $padding, in: 0...120, step: 4)
                }

                // Aspect ratio
                Text("Aspect Ratio").font(.caption).foregroundColor(.secondary)
                Picker("", selection: $aspectRatio) {
                    ForEach(AspectRatioPreset.allCases, id: \.self) {
                        Text($0.rawValue).tag($0)
                    }
                }
                .pickerStyle(.menu)

                Spacer()

                // Actions
                Button("Copy") { exportImage { img in
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([img])
                }}
                .frame(maxWidth: .infinity)

                Button("Save") { exportImage { img in
                    if let item = CaptureStore.shared.saveScreenshot(img) {
                        QuickAccessWindowManager.shared.show(for: item)
                    }
                    onDismiss?()
                }}
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)

                Button("Cancel") { onDismiss?() }
                    .frame(maxWidth: .infinity)
            }
            .padding(16)
            .frame(width: 220)
        }
        .frame(minWidth: 700, minHeight: 500)
    }

    private func canvasSize(for viewSize: CGSize) -> CGSize {
        let availW = viewSize.width - 40
        let availH = viewSize.height - 40
        if let ratio = aspectRatio.ratio {
            let h = min(availH, availW / ratio)
            return CGSize(width: h * ratio, height: h)
        }
        let imgRatio = screenshot.size.width / screenshot.size.height
        let h = min(availH, availW / imgRatio)
        return CGSize(width: h * imgRatio, height: h)
    }

    private func exportImage(completion: (NSImage) -> Void) {
        let targetSize: CGSize
        let imgRatio = screenshot.size.width / screenshot.size.height
        if let ratio = aspectRatio.ratio {
            let w = max(screenshot.size.width + padding * 2, 800)
            targetSize = CGSize(width: w, height: w / ratio)
        } else {
            targetSize = CGSize(
                width: screenshot.size.width + padding * 2,
                height: screenshot.size.height + padding * 2
            )
        }

        // Render at the screenshot's native pixel density so the composited export stays
        // Retina-sharp instead of collapsing to a 1x (point-sized) bitmap.
        let pixelScale = screenshot.pixelScale
        let pixelsWide = max(1, Int((targetSize.width * pixelScale).rounded()))
        let pixelsHigh = max(1, Int((targetSize.height * pixelScale).rounded()))

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
            completion(screenshot)
            return
        }
        rep.size = targetSize

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.cgContext.scaleBy(x: pixelScale, y: pixelScale)
        ctx.cgContext.interpolationQuality = .high

        // Draw background (simplified: just white for export)
        NSColor.systemBlue.setFill()
        NSRect(origin: .zero, size: targetSize).fill()

        // Draw screenshot centered
        let imgW = targetSize.width - padding * 2
        let imgH = imgW / imgRatio
        let imgRect = NSRect(x: padding, y: (targetSize.height - imgH) / 2, width: imgW, height: imgH)
        screenshot.draw(in: imgRect)

        NSGraphicsContext.restoreGraphicsState()

        let output = NSImage(size: targetSize)
        output.addRepresentation(rep)
        completion(output)
    }
}
