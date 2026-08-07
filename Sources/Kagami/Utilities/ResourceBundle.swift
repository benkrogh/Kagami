import Foundation

/// Locates packaged resources without touching SwiftPM's `Bundle.module`.
///
/// `Bundle.module` looks for `Kagami.app/Kagami_Kagami.bundle` (bundle root) and
/// otherwise falls back to an absolute `.build/...` path on the developer machine.
/// That layout is invalid for a signed `.app`, and the fallback does not exist for
/// anyone else — so accessing `Bundle.module` crashes distributed builds.
enum ResourceBundle {
    static var assets: Bundle {
        if let bundle = cached { return bundle }

        let candidates: [URL?] = [
            Bundle.main.resourceURL?.appendingPathComponent("Kagami_Kagami.bundle"),
            Bundle.main.bundleURL
                .appendingPathComponent("Contents/Resources/Kagami_Kagami.bundle"),
            Bundle.main.executableURL?
                .deletingLastPathComponent() // MacOS/
                .appendingPathComponent("Kagami_Kagami.bundle"),
        ]

        for url in candidates {
            guard let url, let bundle = Bundle(url: url) else { continue }
            cached = bundle
            return bundle
        }

        // Dev `swift run` / direct binary: bundle sits next to the executable.
        if let execDir = Bundle.main.executableURL?.deletingLastPathComponent() {
            let sibling = execDir.appendingPathComponent("Kagami_Kagami.bundle")
            if let bundle = Bundle(url: sibling) {
                cached = bundle
                return bundle
            }
        }

        cached = .main
        return .main
    }

    private static var cached: Bundle?
}
