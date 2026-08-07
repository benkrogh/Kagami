import Foundation
import AppKit
import Combine

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    @Published var saveLocation: URL
    @Published var imageFormat: ImageFormat
    @Published var captureDelay: Int
    @Published var showCursorInScreenshots: Bool
    @Published var showCursorInRecordings: Bool
    @Published var playCaptureSound: Bool
    @Published var autoOpenAnnotation: Bool
    @Published var recordingQuality: RecordingQuality
    @Published var recordingFPS: Int
    @Published var recordingCountdown: Int
    @Published var showClickHighlight: Bool
    @Published var clickHighlightColor: String
    @Published var showKeystrokes: Bool
    @Published var recordMicrophone: Bool
    @Published var recordSystemAudio: Bool
    @Published var autoHideDesktopIcons: Bool
    @Published var quickAccessPosition: QuickAccessPosition
    @Published var webcamBubbleSize: CGFloat
    @Published var webcamShape: WebcamShape
    @Published var webcamMirrored: Bool
    @Published var webcamDeviceID: String?

    private init() {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first!
        let defaultSave = pictures.appendingPathComponent("Kagami")

        saveLocation           = defaults.url(forKey: "saveLocation") ?? defaultSave
        imageFormat            = ImageFormat(rawValue: defaults.string(forKey: "imageFormat") ?? "") ?? .png
        captureDelay           = defaults.integer(forKey: "captureDelay")
        showCursorInScreenshots = defaults.object(forKey: "showCursorInScreenshots") as? Bool ?? true
        showCursorInRecordings  = defaults.object(forKey: "showCursorInRecordings")  as? Bool ?? true
        playCaptureSound        = defaults.object(forKey: "playCaptureSound")         as? Bool ?? true
        autoOpenAnnotation      = defaults.object(forKey: "autoOpenAnnotation")       as? Bool ?? false
        recordingQuality        = RecordingQuality(rawValue: defaults.string(forKey: "recordingQuality") ?? "") ?? .high
        recordingFPS            = defaults.object(forKey: "recordingFPS") as? Int ?? 30
        recordingCountdown      = defaults.object(forKey: "recordingCountdown") as? Int ?? 3
        showClickHighlight      = defaults.object(forKey: "showClickHighlight")       as? Bool ?? true
        clickHighlightColor     = defaults.string(forKey: "clickHighlightColor")       ?? "#FF9500"
        showKeystrokes          = defaults.object(forKey: "showKeystrokes")            as? Bool ?? false
        recordMicrophone        = defaults.object(forKey: "recordMicrophone")          as? Bool ?? false
        recordSystemAudio       = defaults.object(forKey: "recordSystemAudio")         as? Bool ?? false
        autoHideDesktopIcons    = defaults.object(forKey: "autoHideDesktopIcons")      as? Bool ?? false
        quickAccessPosition     = QuickAccessPosition(rawValue: defaults.string(forKey: "quickAccessPosition") ?? "") ?? .bottomRight

        let storedBubbleSize = defaults.double(forKey: "webcamBubbleSize")
        webcamBubbleSize     = storedBubbleSize > 0 ? CGFloat(storedBubbleSize) : 200
        webcamShape          = WebcamShape(rawValue: defaults.string(forKey: "webcamShape") ?? "") ?? .circle
        webcamMirrored       = defaults.object(forKey: "webcamMirrored") as? Bool ?? true
        webcamDeviceID       = defaults.string(forKey: "webcamDeviceID")
    }

    func saveAll() {
        defaults.set(saveLocation,            forKey: "saveLocation")
        defaults.set(imageFormat.rawValue,    forKey: "imageFormat")
        defaults.set(captureDelay,            forKey: "captureDelay")
        defaults.set(showCursorInScreenshots, forKey: "showCursorInScreenshots")
        defaults.set(showCursorInRecordings,  forKey: "showCursorInRecordings")
        defaults.set(playCaptureSound,        forKey: "playCaptureSound")
        defaults.set(autoOpenAnnotation,      forKey: "autoOpenAnnotation")
        defaults.set(recordingQuality.rawValue, forKey: "recordingQuality")
        defaults.set(recordingFPS,            forKey: "recordingFPS")
        defaults.set(recordingCountdown,      forKey: "recordingCountdown")
        defaults.set(showClickHighlight,      forKey: "showClickHighlight")
        defaults.set(clickHighlightColor,     forKey: "clickHighlightColor")
        defaults.set(showKeystrokes,          forKey: "showKeystrokes")
        defaults.set(recordMicrophone,        forKey: "recordMicrophone")
        defaults.set(recordSystemAudio,       forKey: "recordSystemAudio")
        defaults.set(autoHideDesktopIcons,    forKey: "autoHideDesktopIcons")
        defaults.set(quickAccessPosition.rawValue, forKey: "quickAccessPosition")
        defaults.set(Double(webcamBubbleSize), forKey: "webcamBubbleSize")
        defaults.set(webcamShape.rawValue,    forKey: "webcamShape")
        defaults.set(webcamMirrored,          forKey: "webcamMirrored")
        defaults.set(webcamDeviceID,           forKey: "webcamDeviceID")
    }

    enum ImageFormat: String, CaseIterable {
        case png, jpg, tiff
        var displayName: String { rawValue.uppercased() }
        var fileExtension: String { rawValue }
        var bitmapFormat: NSBitmapImageRep.FileType {
            switch self {
            case .png:  return .png
            case .jpg:  return .jpeg
            case .tiff: return .tiff
            }
        }
    }

    enum RecordingQuality: String, CaseIterable {
        case low, medium, high
        var displayName: String { rawValue.capitalized }

        /// Screen content (sharp text and UI edges) needs far more bits per
        /// pixel than camera footage to avoid visible macroblocking — and
        /// that need scales with resolution. A flat bitrate that looks fine
        /// at 1080p starves a Retina/4K/5K capture, which is what reads back
        /// as "blurry" or "downsampled" even though the actual pixel
        /// dimensions are correct. Bucket by total captured pixel count so
        /// quality holds up across displays.
        func videoBitRate(pixelWidth: Int, pixelHeight: Int) -> Int {
            let megapixels = Double(pixelWidth * pixelHeight) / 1_000_000

            let tiers: [(maxMP: Double, low: Int, medium: Int, high: Int)] = [
                (2.3, 4_000_000, 8_000_000, 15_000_000),           // up to ~1080p
                (4.0, 8_000_000, 15_000_000, 25_000_000),          // up to ~1440p / 2K
                (9.0, 15_000_000, 25_000_000, 50_000_000),         // up to ~4K
                (.infinity, 20_000_000, 35_000_000, 65_000_000)    // 5K Retina and beyond
            ]
            let tier = tiers.first(where: { megapixels <= $0.maxMP }) ?? tiers[tiers.count - 1]

            switch self {
            case .low:    return tier.low
            case .medium: return tier.medium
            case .high:   return tier.high
            }
        }
    }

    enum QuickAccessPosition: String, CaseIterable {
        case bottomRight, bottomLeft, topRight, topLeft
        var displayName: String {
            switch self {
            case .bottomRight: return "Bottom Right"
            case .bottomLeft:  return "Bottom Left"
            case .topRight:    return "Top Right"
            case .topLeft:     return "Top Left"
            }
        }
    }

    enum WebcamShape: String, CaseIterable {
        case circle, roundedSquare
        var displayName: String {
            switch self {
            case .circle:       return "Circle"
            case .roundedSquare: return "Rounded Square"
            }
        }
    }
}
