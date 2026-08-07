import Foundation

struct CaptureItem: Codable, Identifiable, Hashable {
    var id: UUID
    var timestamp: Date
    var type: CaptureItemType
    var fileURL: URL
    var thumbnailData: Data?
    var width: Double
    var height: Double
    var fileSize: Int64
    var durationSeconds: Double?  // for recordings

    var dimensions: CGSize { CGSize(width: width, height: height) }

    var formattedSize: String {
        let bytes = Double(fileSize)
        if bytes < 1024 { return "\(fileSize) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", bytes / 1024) }
        return String(format: "%.1f MB", bytes / (1024 * 1024))
    }

    var formattedTimestamp: String {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f.string(from: timestamp)
    }

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        type: CaptureItemType,
        fileURL: URL,
        thumbnailData: Data? = nil,
        dimensions: CGSize = .zero,
        fileSize: Int64 = 0,
        durationSeconds: Double? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.type = type
        self.fileURL = fileURL
        self.thumbnailData = thumbnailData
        self.width = dimensions.width
        self.height = dimensions.height
        self.fileSize = fileSize
        self.durationSeconds = durationSeconds
    }

    enum CaptureItemType: String, Codable {
        case screenshot
        case recording
        case gif

        var icon: String {
            switch self {
            case .screenshot: return "camera"
            case .recording:  return "video"
            case .gif:        return "film"
            }
        }
    }
}
