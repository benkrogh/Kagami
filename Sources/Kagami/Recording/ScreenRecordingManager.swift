import AppKit
import AVFoundation
import ScreenCaptureKit

// MARK: - Recording State

enum RecordingState {
    case idle, starting, recording, stopping
}

enum RecordingKind {
    case video, gif
}

// MARK: - Stream output
//
// Appends retimed CMSampleBuffers on the SCStream handler queue. Based on the
// ScreenCaptureKit recording pattern: start the writer session at .zero after
// capture begins, then offset each sample's PTS relative to the first frame.

private final class RecordingStreamOutput: NSObject, SCStreamOutput {
    let videoInput: AVAssetWriterInput
    let audioInput: AVAssetWriterInput?
    let micInput: AVAssetWriterInput?
    private weak var assetWriter: AVAssetWriter?
    private let timeline: RecordingTimeline
    private let appendQueue: DispatchQueue
    var onMicrophoneLevel: ((Float) -> Void)?

    private(set) var sessionStarted = false
    private var writerSessionStarted = false
    private(set) var lastVideoPTS: CMTime = .zero
    private(set) var lastVideoFrameDuration: CMTime = .zero

    init(
        videoInput: AVAssetWriterInput,
        audioInput: AVAssetWriterInput?,
        micInput: AVAssetWriterInput?,
        assetWriter: AVAssetWriter,
        timeline: RecordingTimeline,
        appendQueue: DispatchQueue
    ) {
        self.videoInput = videoInput
        self.audioInput = audioInput
        self.micInput = micInput
        self.assetWriter = assetWriter
        self.timeline = timeline
        self.appendQueue = appendQueue
    }

    func beginSession() {
        sessionStarted = true
        writerSessionStarted = false
        lastVideoPTS = .zero
        lastVideoFrameDuration = .zero
    }

    func endSession() {
        sessionStarted = false
    }

    var sessionEndTime: CMTime {
        guard lastVideoPTS.isValid, lastVideoPTS >= .zero else { return .zero }
        if lastVideoFrameDuration.isValid, lastVideoFrameDuration > .zero {
            return lastVideoPTS + lastVideoFrameDuration
        }
        return lastVideoPTS
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else { return }

        appendQueue.async { [self] in
            guard sessionStarted else { return }

            switch type {
            case .screen:
                guard isCompleteFrame(sampleBuffer),
                      videoInput.isReadyForMoreMediaData
                else { return }

                if !writerSessionStarted {
                    let pts = sampleBuffer.presentationTimeStamp
                    timeline.anchor(at: pts)
                    assetWriter?.startSession(atSourceTime: pts)
                    writerSessionStarted = true
                }

                lastVideoPTS = sampleBuffer.presentationTimeStamp
                lastVideoFrameDuration = sampleBuffer.duration
                if !videoInput.append(sampleBuffer) {
                    print("Recording: video append failed")
                }

            case .audio:
                guard writerSessionStarted,
                      let audioInput,
                      audioInput.isReadyForMoreMediaData
                else { return }

                if !audioInput.append(sampleBuffer) {
                    print("Recording: audio append failed")
                }

            case .microphone:
                onMicrophoneLevel?(AudioSampleProcessing.peakLevel(in: sampleBuffer))

                guard writerSessionStarted,
                      let micInput,
                      micInput.isReadyForMoreMediaData
                else { return }

                let prepared = AudioSampleProcessing.prepareForWriter(from: sampleBuffer)
                if !micInput.append(prepared) {
                    print("Recording: microphone append failed")
                }

            @unknown default:
                break
            }
        }
    }

    private func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let attachments = attachmentsArray.first,
              let statusRaw = attachments[SCStreamFrameInfo.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw)
        else { return false }
        return status == .complete
    }
}

// MARK: - Recording Manager

@MainActor
final class ScreenRecordingManager: NSObject, ObservableObject {
    static let shared = ScreenRecordingManager()
    private override init() { super.init() }

    @Published var state: RecordingState = .idle
    @Published var elapsed: TimeInterval = 0
    @Published var isRecordingMicrophone = false
    @Published private(set) var recordingKind: RecordingKind = .video

    /// GIFs balloon in file size fast, so recordings started in GIF mode
    /// auto-stop after this many seconds. `onGifDurationReached` fires once
    /// when the cap is hit; the caller (menu bar controller) is responsible
    /// for actually stopping + saving, same as a manual stop button press.
    static let gifMaxDuration: TimeInterval = 20
    var onGifDurationReached: (() -> Void)?

    private var stream: SCStream?
    private var streamOutput: RecordingStreamOutput?
    private var assetWriter: AVAssetWriter?
    private var timer: Timer?
    private var startTime = Date()
    private var tempURL: URL?
    private var regionIndicatorWindow: NSWindow?
    private var microphoneCapture: MicrophoneCapture?
    private var recordingTimeline = RecordingTimeline()
    private let sampleQueue = DispatchQueue(label: "com.kagami.recording.samples")
    private let writerAppendQueue = DispatchQueue(label: "com.kagami.recording.writer")

    // MARK: - Start Recording

    @discardableResult
    func startRecording(captureRect: CGRect? = nil, excludingWindowIDs: [CGWindowID] = [], kind: RecordingKind = .video) async -> Bool {
        guard state == .idle else { return false }
        guard ScreenCaptureManager.shared.ensureScreenRecordingPermission() else { return false }

        let settings = AppSettings.shared
        let captureMicrophone = settings.recordMicrophone
        let captureSystemAudio = settings.recordSystemAudio
        let useStreamMicrophone = captureMicrophone && streamMicrophoneAvailable

        if captureMicrophone {
            guard await ScreenCaptureManager.shared.ensureMicrophonePermission() else {
                state = .idle
                return false
            }
        }

        state = .starting
        isRecordingMicrophone = captureMicrophone
        recordingKind = kind

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

            let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
                ?? content.displays.first
            guard let display else {
                state = .idle
                return false
            }

            let excluded = content.windows.filter { excludingWindowIDs.contains($0.windowID) }
            let filter = SCContentFilter(display: display, excludingWindows: excluded)
            let scale = CGFloat(filter.pointPixelScale)
            let bounds = CGDisplayBounds(display.displayID)

            let pixelWidth: Int
            let pixelHeight: Int
            var sourceRect: CGRect?

            if let rect = captureRect {
                let local = CGRect(
                    x: rect.minX - bounds.minX,
                    y: rect.minY - bounds.minY,
                    width: rect.width,
                    height: rect.height
                )
                sourceRect = local
                pixelWidth  = max(2, Int((rect.width  * scale).rounded()) & ~1)
                pixelHeight = max(2, Int((rect.height * scale).rounded()) & ~1)

                let indicator = RegionIndicatorWindow.make(forTopLeftGlobalRect: rect)
                indicator.orderFront(nil)
                regionIndicatorWindow = indicator
            } else {
                pixelWidth  = max(2, Int((CGFloat(display.width)  * scale).rounded()) & ~1)
                pixelHeight = max(2, Int((CGFloat(display.height) * scale).rounded()) & ~1)
            }

            tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("kagami_recording_\(UUID().uuidString).mp4")

            let writer = try AVAssetWriter(outputURL: tempURL!, fileType: .mp4)

            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: pixelWidth,
                AVVideoHeightKey: pixelHeight,
                AVVideoColorPropertiesKey: [
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
                ],
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: settings.recordingQuality.videoBitRate(pixelWidth: pixelWidth, pixelHeight: pixelHeight),
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                ]
            ]
            let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            videoInput.expectsMediaDataInRealTime = true
            guard writer.canAdd(videoInput) else { throw RecordingError("Cannot add video input") }
            writer.add(videoInput)

            var audioInput: AVAssetWriterInput?
            if captureSystemAudio {
                let audioSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: MicrophoneCapture.sampleRate,
                    AVNumberOfChannelsKey: MicrophoneCapture.channelCount,
                    AVEncoderBitRateKey: 128_000
                ]
                let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                ai.expectsMediaDataInRealTime = true
                guard writer.canAdd(ai) else { throw RecordingError("Cannot add audio input") }
                writer.add(ai)
                audioInput = ai
            }

            var micInput: AVAssetWriterInput?
            if captureMicrophone {
                let micSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: MicrophoneCapture.sampleRate,
                    AVNumberOfChannelsKey: MicrophoneCapture.channelCount,
                    AVEncoderBitRateKey: 128_000
                ]
                let mi = AVAssetWriterInput(mediaType: .audio, outputSettings: micSettings)
                mi.expectsMediaDataInRealTime = true
                guard writer.canAdd(mi) else { throw RecordingError("Cannot add microphone input") }
                writer.add(mi)
                micInput = mi
            }

            recordingTimeline = RecordingTimeline()

            guard writer.startWriting() else {
                throw writer.error ?? RecordingError("AVAssetWriter failed to start")
            }

            let output = RecordingStreamOutput(
                videoInput: videoInput,
                audioInput: audioInput,
                micInput: useStreamMicrophone ? micInput : nil,
                assetWriter: writer,
                timeline: recordingTimeline,
                appendQueue: writerAppendQueue
            )
            assetWriter = writer
            streamOutput = output
            if useStreamMicrophone {
                output.onMicrophoneLevel = nil
            }

            var micCapture: MicrophoneCapture?
            if captureMicrophone, !useStreamMicrophone, let micInput {
                let mic = MicrophoneCapture(
                    appendQueue: writerAppendQueue,
                    writerInput: micInput,
                    timeline: recordingTimeline
                )
                mic.onLevel = nil
                try mic.prepare()
                micCapture = mic
                microphoneCapture = mic
            }

            let config = SCStreamConfiguration()
            config.width  = pixelWidth
            config.height = pixelHeight
            if let sourceRect { config.sourceRect = sourceRect }
            config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, settings.recordingFPS)))
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.colorSpaceName = CGColorSpace.sRGB
            config.queueDepth = 6
            config.capturesAudio = captureSystemAudio
            // Otherwise Kagami's own UI sounds (recording start/stop, the
            // countdown tick) get picked up in the system-audio track since
            // they play through the same output device being captured.
            config.excludesCurrentProcessAudio = true
            config.sampleRate = 48_000
            config.channelCount = 2
            config.showsCursor = settings.showCursorInRecordings
            if useStreamMicrophone {
                if #available(macOS 15.0, *) {
                    config.captureMicrophone = true
                }
            }

            let s = SCStream(filter: filter, configuration: config, delegate: nil)
            try s.addStreamOutput(output, type: .screen, sampleHandlerQueue: sampleQueue)
            if captureSystemAudio {
                try s.addStreamOutput(output, type: .audio, sampleHandlerQueue: sampleQueue)
            }
            if useStreamMicrophone {
                if #available(macOS 15.0, *) {
                    try s.addStreamOutput(output, type: .microphone, sampleHandlerQueue: sampleQueue)
                }
            }
            try await s.startCapture()
            stream = s

            // Let the mic hardware warm up in parallel with the start cue —
            // its samples are dropped below until the timeline is anchored,
            // so this can't leak the cue into the recording, it just avoids
            // a cold-start glitch once real capture begins.
            if let micCapture {
                micCapture.beginSession()
            }

            let cueDuration = RecordingSounds.playStarted()
            if cueDuration > 0 {
                try? await Task.sleep(nanoseconds: UInt64(min(cueDuration, 1.5) * 1_000_000_000))
            }

            // Only now does the timeline actually get anchored, so nothing
            // captured while the start cue was playing — including anything
            // a nearby mic picked up acoustically — ends up in the saved
            // recording.
            output.beginSession()

            state = .recording
            startTime = Date()
            elapsed = 0

            let elapsedTimer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.state == .recording else { return }
                    self.elapsed = Date().timeIntervalSince(self.startTime)

                    if self.recordingKind == .gif, self.elapsed >= Self.gifMaxDuration, let callback = self.onGifDurationReached {
                        self.onGifDurationReached = nil
                        callback()
                    }
                }
            }
            RunLoop.main.add(elapsedTimer, forMode: .common)
            timer = elapsedTimer

            return true
        } catch {
            print("Recording start error: \(error)")
            isRecordingMicrophone = false
            await cleanupRecording(deleteFile: true)
            state = .idle
            return false
        }
    }

    // MARK: - Stop Recording

    func stopRecording() async -> CaptureItem? {
        if state == .starting {
            await cancelInFlightRecording()
            return nil
        }
        guard state == .recording else { return nil }
        state = .stopping

        // Stop accepting new samples *before* playing the stop cue — both
        // calls below take effect immediately (not just once the stream/
        // session actually tears down), so the cue itself never bleeds into
        // the tail end of the saved recording via a nearby mic.
        streamOutput?.endSession()
        microphoneCapture?.stop()
        RecordingSounds.playStopped()

        timer?.invalidate()
        timer = nil
        onGifDurationReached = nil

        let duration = elapsed
        let kind = recordingKind
        await finalizeWriter(save: true)

        guard let videoURL = tempURL else { state = .idle; return nil }
        let attrs = try? FileManager.default.attributesOfItem(atPath: videoURL.path)
        let fileSize = attrs?[.size] as? Int64 ?? 0
        guard fileSize > 0 else {
            print("Recording: output file is empty")
            try? FileManager.default.removeItem(at: videoURL)
            state = .idle
            elapsed = 0
            recordingKind = .video
            return nil
        }

        let item: CaptureItem?
        switch kind {
        case .video:
            item = CaptureStore.shared.saveRecording(at: videoURL, duration: duration, isGif: false)
        case .gif:
            item = await exportAndSaveGif(sourceVideoURL: videoURL, duration: duration)
        }

        tempURL = nil
        state = .idle
        elapsed = 0
        isRecordingMicrophone = false
        recordingKind = .video
        return item
    }

    func discardRecording() async {
        if state == .starting {
            await cancelInFlightRecording()
            return
        }
        guard state == .recording || state == .stopping else { return }
        state = .stopping
        RecordingSounds.playStopped()

        timer?.invalidate()
        timer = nil
        onGifDurationReached = nil

        await finalizeWriter(save: false)
        state = .idle
        elapsed = 0
        isRecordingMicrophone = false
        recordingKind = .video
    }

    /// Converts the just-recorded MP4 into an animated GIF, then saves the GIF
    /// (not the source video) into the capture store. The intermediate MP4 is
    /// always cleaned up, whether or not the export succeeds.
    private func exportAndSaveGif(sourceVideoURL: URL, duration: Double) async -> CaptureItem? {
        let gifURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kagami_recording_\(UUID().uuidString).gif")

        do {
            try await GifExporter.export(from: sourceVideoURL, to: gifURL)
        } catch {
            print("Recording: GIF export failed: \(error)")
            try? FileManager.default.removeItem(at: sourceVideoURL)
            return nil
        }

        try? FileManager.default.removeItem(at: sourceVideoURL)
        return CaptureStore.shared.saveRecording(at: gifURL, duration: duration, isGif: true)
    }

    // MARK: - Helpers

    private func finalizeWriter(save: Bool) async {
        streamOutput?.endSession()

        microphoneCapture?.stop()
        microphoneCapture = nil

        if let s = stream {
            try? await s.stopCapture()
        }
        stream = nil

        await drainWriterQueue { }

        if let endTime = streamOutput?.sessionEndTime,
           endTime.isValid, endTime > .zero,
           assetWriter?.status == .writing {
            assetWriter?.endSession(atSourceTime: endTime)
        }

        assetWriter?.inputs.forEach { $0.markAsFinished() }

        if let writer = assetWriter {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                writer.finishWriting {
                    if let error = writer.error {
                        print("Recording finish error: \(error)")
                    }
                    cont.resume()
                }
            }
        }

        if !save {
            if let url = tempURL {
                try? FileManager.default.removeItem(at: url)
            }
        }

        streamOutput = nil
        assetWriter = nil
        if !save { tempURL = nil }
        hideRegionIndicator()
    }

    private func cancelInFlightRecording() async {
        state = .stopping
        timer?.invalidate()
        timer = nil
        onGifDurationReached = nil
        await cleanupRecording(deleteFile: true)
        isRecordingMicrophone = false
        elapsed = 0
        recordingKind = .video
        state = .idle
    }

    private func drainWriterQueue(_ work: @escaping () -> Void) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            writerAppendQueue.async {
                work()
                cont.resume()
            }
        }
    }

    private func cleanupRecording(deleteFile: Bool) async {
        streamOutput?.endSession()
        microphoneCapture?.stop()
        microphoneCapture = nil
        await drainWriterQueue { }
        if let s = stream { try? await s.stopCapture() }
        stream = nil
        streamOutput = nil
        assetWriter = nil
        if deleteFile, let url = tempURL {
            try? FileManager.default.removeItem(at: url)
        }
        tempURL = nil
        hideRegionIndicator()
    }

    private func hideRegionIndicator() {
        regionIndicatorWindow?.orderOut(nil)
        regionIndicatorWindow = nil
    }

    var formattedElapsed: String {
        let t = Int(elapsed)
        return String(format: "%02d:%02d", t / 60, t % 60)
    }

    /// Seconds left before a GIF recording auto-stops, formatted for display.
    var formattedGifRemaining: String {
        let remaining = max(0, Int((Self.gifMaxDuration - elapsed).rounded(.up)))
        return String(format: "0:%02d", remaining)
    }

    private var streamMicrophoneAvailable: Bool {
        if #available(macOS 15.0, *) {
            return true
        }
        return false
    }
}

private struct RecordingError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}
