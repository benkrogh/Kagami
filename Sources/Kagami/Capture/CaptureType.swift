import Foundation

enum CaptureMode: String, CaseIterable {
    case area
    case window
    case fullscreen
    case scrolling
    case allInOne

    var displayName: String {
        switch self {
        case .area:       return "Capture Area"
        case .window:     return "Capture Window"
        case .fullscreen: return "Capture Fullscreen"
        case .scrolling:  return "Scrolling Capture"
        case .allInOne:   return "All-in-One"
        }
    }

    var icon: String {
        switch self {
        case .area:       return "crop"
        case .window:     return "macwindow"
        case .fullscreen: return "display"
        case .scrolling:  return "scroll"
        case .allInOne:   return "rectangle.on.rectangle"
        }
    }

    var keyEquivalent: String {
        switch self {
        case .area:       return "1"
        case .window:     return "2"
        case .fullscreen: return "3"
        case .scrolling:  return "5"
        case .allInOne:   return "0"
        }
    }
}
