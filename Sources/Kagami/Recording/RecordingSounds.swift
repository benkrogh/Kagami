import AppKit

/// Recording cues, sourced from `Sources/Kagami/Resources/Sounds/`:
///   - `recording_start.wav` — recording actually begins
///   - `recording_stop.wav`  — recording stops/saves
///   - `count.wav`           — each tick of the pre-recording countdown
/// Falls back to a stock system sound if a file is ever missing.
@MainActor
enum RecordingSounds {
    private static var activeSound: NSSound?

    /// Returns the cue's duration so the caller can hold off on actually
    /// starting to write samples until it's finished playing — otherwise a
    /// nearby microphone can pick the cue up acoustically and it ends up
    /// baked into the first fraction of a second of the recording.
    @discardableResult
    static func playStarted() -> TimeInterval {
        guard AppSettings.shared.playCaptureSound else { return 0 }
        return play(resource: "recording_start", fallbackSystemName: "Pop")
    }

    @discardableResult
    static func playStopped() -> TimeInterval {
        guard AppSettings.shared.playCaptureSound else { return 0 }
        return play(resource: "recording_stop", fallbackSystemName: "Tink")
    }

    /// Soft tick played on each second of the pre-recording countdown. The
    /// final "beep" the user hears is `playStarted()`, fired automatically
    /// once the countdown ends and the recording actually begins.
    static func playCountdownTick() {
        guard AppSettings.shared.playCaptureSound else { return }
        play(resource: "count", fallbackSystemName: "Tink")
    }

    @discardableResult
    private static func play(resource name: String, fallbackSystemName: String) -> TimeInterval {
        let sound: NSSound?
        if let url = locateResource(named: name, ext: "wav") {
            sound = NSSound(contentsOf: url, byReference: false)
        } else {
            sound = NSSound(named: fallbackSystemName)
        }
        activeSound = sound
        sound?.play()
        return sound?.duration ?? 0
    }

    private static func locateResource(named name: String, ext: String) -> URL? {
        let subdirs = ["Sounds", nil]
        for bundle in resourceBundles() {
            for sub in subdirs {
                if let url = bundle.url(forResource: name, withExtension: ext, subdirectory: sub) {
                    return url
                }
            }
        }
        return nil
    }

    private static func resourceBundles() -> [Bundle] {
        var bundles: [Bundle] = [Bundle.main, ResourceBundle.assets]

        if let execDir = Bundle.main.executableURL?.deletingLastPathComponent(),
           let siblings = try? FileManager.default.contentsOfDirectory(
               at: execDir,
               includingPropertiesForKeys: nil
           ) {
            for url in siblings where url.pathExtension == "bundle" {
                if let bundle = Bundle(url: url) {
                    bundles.append(bundle)
                }
            }
        }

        if let resourcesDir = Bundle.main.resourceURL,
           let items = try? FileManager.default.contentsOfDirectory(
               at: resourcesDir,
               includingPropertiesForKeys: nil
           ) {
            for url in items where url.pathExtension == "bundle" {
                if let bundle = Bundle(url: url) {
                    bundles.append(bundle)
                }
            }
        }

        return bundles
    }
}
