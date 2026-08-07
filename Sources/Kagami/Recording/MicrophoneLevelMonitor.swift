import AVFoundation
import Combine

/// Live microphone level for UI preview (setup panel, recording toolbar).
/// Uses AVAudioEngine separately from the recording pipeline so levels work
/// with pro interfaces before and during capture.
@MainActor
final class MicrophoneLevelMonitor: ObservableObject {
    static let shared = MicrophoneLevelMonitor()

    @Published private(set) var level: Float = 0

    private let engine = AVAudioEngine()
    private var isRunning = false
    private var decayTimer: Timer?

    private init() {}

    func start() {
        guard !isRunning else { return }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return }

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            let peak = Self.peakLevel(in: buffer)
            Task { @MainActor in
                guard let self, self.isRunning else { return }
                self.level = self.level * 0.55 + peak * 0.45
            }
        }

        do {
            engine.prepare()
            try engine.start()
            isRunning = true
            startDecayTimer()
        } catch {
            print("Mic monitor start failed: \(error)")
            input.removeTap(onBus: 0)
        }
    }

    func stop() {
        guard isRunning else {
            level = 0
            return
        }

        isRunning = false
        decayTimer?.invalidate()
        decayTimer = nil

        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        level = 0
    }

    private func startDecayTimer() {
        decayTimer?.invalidate()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRunning else { return }
                self.level *= 0.88
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        decayTimer = timer
    }

    nonisolated static func peakLevel(in buffer: AVAudioPCMBuffer) -> Float {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }

        var peak: Float = 0
        let channelCount = Int(buffer.format.channelCount)

        if let channelData = buffer.floatChannelData {
            if buffer.format.isInterleaved {
                for frame in 0..<frames {
                    for ch in 0..<min(channelCount, 2) {
                        peak = max(peak, abs(channelData[0][frame * channelCount + ch]))
                    }
                }
            } else {
                for ch in 0..<min(channelCount, 2) {
                    let samples = channelData[ch]
                    for frame in 0..<frames {
                        peak = max(peak, abs(samples[frame]))
                    }
                }
            }
        } else if let channelData = buffer.int16ChannelData {
            if buffer.format.isInterleaved {
                for frame in 0..<frames {
                    for ch in 0..<min(channelCount, 2) {
                        peak = max(peak, abs(Float(channelData[0][frame * channelCount + ch]) / 32_768))
                    }
                }
            } else {
                for ch in 0..<min(channelCount, 2) {
                    let samples = channelData[ch]
                    for frame in 0..<frames {
                        peak = max(peak, abs(Float(samples[frame]) / 32_768))
                    }
                }
            }
        }

        return min(1, peak * 2.5)
    }
}
