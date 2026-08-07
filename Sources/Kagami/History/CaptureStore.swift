import Foundation
import AppKit

@MainActor
final class CaptureStore: ObservableObject {
    static let shared = CaptureStore()
    private init() {}

    @Published private(set) var captures: [CaptureItem] = []

    private var baseURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("Kagami")
    }

    var capturesDirectory: URL { baseURL.appendingPathComponent("Captures") }
    private var indexURL: URL { baseURL.appendingPathComponent("index.json") }

    // MARK: - Setup

    func setup() {
        try? FileManager.default.createDirectory(at: capturesDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: AppSettings.shared.saveLocation, withIntermediateDirectories: true)
        loadIndex()
        pruneOldCaptures()
    }

    // MARK: - Persistence

    func addCapture(_ item: CaptureItem) {
        captures.insert(item, at: 0)
        saveIndex()
    }

    func deleteCapture(_ item: CaptureItem) {
        try? FileManager.default.removeItem(at: item.fileURL)
        captures.removeAll { $0.id == item.id }
        saveIndex()
    }

    // MARK: - Screenshot save

    func saveScreenshot(_ image: NSImage) -> CaptureItem? {
        let settings = AppSettings.shared
        let fmt = settings.imageFormat
        let ts  = DateFormatter.kagamiFilename.string(from: Date())
        let name = "kagami-screenshot-\(ts).\(fmt.fileExtension)"

        let internalURL = capturesDirectory.appendingPathComponent(name)
        guard let data = image.imageData(for: fmt) else { return nil }
        do { try data.write(to: internalURL) } catch { return nil }

        // Mirror to user save location
        let userURL = settings.saveLocation.appendingPathComponent(name)
        try? data.write(to: userURL)

        let attrs = try? FileManager.default.attributesOfItem(atPath: internalURL.path)
        let item = CaptureItem(
            type: .screenshot,
            fileURL: internalURL,
            thumbnailData: image.thumbnailData(maxEdge: 300),
            dimensions: image.size,
            fileSize: attrs?[.size] as? Int64 ?? 0
        )
        addCapture(item)
        if settings.playCaptureSound { NSSound(named: "Tink")?.play() }
        return item
    }

    // MARK: - Recording save

    func saveRecording(at tempURL: URL, duration: Double, isGif: Bool) -> CaptureItem? {
        let ext = isGif ? "gif" : "mp4"
        let ts  = DateFormatter.kagamiFilename.string(from: Date())
        let name = "kagami-recording-\(ts).\(ext)"

        let internalURL = capturesDirectory.appendingPathComponent(name)
        try? FileManager.default.moveItem(at: tempURL, to: internalURL)

        let userURL = AppSettings.shared.saveLocation.appendingPathComponent(name)
        try? FileManager.default.copyItem(at: internalURL, to: userURL)

        let attrs = try? FileManager.default.attributesOfItem(atPath: internalURL.path)
        let (preview, dimensions) = isGif
            ? (NSImage(contentsOf: internalURL), NSImage(contentsOf: internalURL)?.size ?? .zero)
            : CaptureMediaHelpers.videoMetadata(from: internalURL)

        let item = CaptureItem(
            type: isGif ? .gif : .recording,
            fileURL: internalURL,
            thumbnailData: preview?.thumbnailData(maxEdge: 300),
            dimensions: dimensions,
            fileSize: attrs?[.size] as? Int64 ?? 0,
            durationSeconds: duration
        )
        addCapture(item)
        return item
    }

    // MARK: - Private helpers

    private func loadIndex() {
        guard let data = try? Data(contentsOf: indexURL),
              let items = try? JSONDecoder().decode([CaptureItem].self, from: data) else { return }
        captures = items.filter { FileManager.default.fileExists(atPath: $0.fileURL.path) }
    }

    private func saveIndex() {
        guard let data = try? JSONEncoder().encode(captures) else { return }
        try? data.write(to: indexURL)
    }

    private func pruneOldCaptures() {
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
        captures.filter { $0.timestamp < cutoff }.forEach { deleteCapture($0) }
    }
}

// MARK: - Helpers

extension DateFormatter {
    static let kagamiFilename: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f
    }()
}

extension NSImage {
    func imageData(for format: AppSettings.ImageFormat) -> Data? {
        guard let tiff = tiffRepresentation,
              let bmp  = NSBitmapImageRep(data: tiff) else { return nil }
        // Designers rely on these files for pixel-accurate work, so bias JPEG toward
        // near-lossless quality rather than the smaller/softer default (0.9).
        let props: [NSBitmapImageRep.PropertyKey: Any] = format == .jpg ? [.compressionFactor: 1.0] : [:]
        return bmp.representation(using: format.bitmapFormat, properties: props)
    }

    func thumbnailData(maxEdge: CGFloat) -> Data? {
        let scale = min(maxEdge / size.width, maxEdge / size.height, 1)
        let thumbSize = CGSize(width: size.width * scale, height: size.height * scale)
        let thumb = NSImage(size: thumbSize)
        thumb.lockFocus()
        draw(in: NSRect(origin: .zero, size: thumbSize))
        thumb.unlockFocus()
        return thumb.imageData(for: .png)
    }
}
