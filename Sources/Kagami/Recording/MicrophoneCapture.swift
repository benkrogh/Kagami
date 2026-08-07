import AVFoundation
import CoreMedia

/// Shared timeline anchor set when the first screen frame arrives.
final class RecordingTimeline {
    private(set) var firstVideoPTS: CMTime?
    private let lock = NSLock()

    var isAnchored: Bool {
        lock.lock()
        defer { lock.unlock() }
        return firstVideoPTS != nil
    }

    func anchor(at pts: CMTime) {
        lock.lock()
        defer { lock.unlock() }
        guard firstVideoPTS == nil else { return }
        firstVideoPTS = pts
    }

    func retimed(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        lock.lock()
        let anchor = firstVideoPTS
        lock.unlock()
        guard let anchor else { return nil }

        let pts = sampleBuffer.presentationTimeStamp - anchor
        let timing = CMSampleTimingInfo(
            duration: sampleBuffer.duration,
            presentationTimeStamp: pts,
            decodeTimeStamp: sampleBuffer.decodeTimeStamp
        )
        return try? CMSampleBuffer(copying: sampleBuffer, withNewTiming: [timing])
    }
}

/// Captures the default microphone via AVCaptureSession (macOS 14 fallback).
/// Delivers CMSampleBuffers compatible with AVAssetWriter AAC encoding.
final class MicrophoneCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    static let sampleRate: Double = 48_000
    static let channelCount: AVAudioChannelCount = 2

    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let captureQueue = DispatchQueue(label: "com.kagami.recording.mic.capture")
    private let appendQueue: DispatchQueue
    private let timeline: RecordingTimeline
    private weak var writerInput: AVAssetWriterInput?
    private var stopped = false
    var onLevel: ((Float) -> Void)?

    init(appendQueue: DispatchQueue, writerInput: AVAssetWriterInput, timeline: RecordingTimeline) {
        self.appendQueue = appendQueue
        self.writerInput = writerInput
        self.timeline = timeline
        super.init()
    }

    func prepare() throws {
        stopped = false

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = .high

        guard let device = AVCaptureDevice.default(for: .audio) else {
            throw MicrophoneCaptureError.noInputDevice
        }

        try configurePreferredStereoFormat(on: device)

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw MicrophoneCaptureError.noInputDevice
        }
        session.addInput(input)

        output.setSampleBufferDelegate(self, queue: captureQueue)
        guard session.canAddOutput(output) else {
            throw MicrophoneCaptureError.noInputDevice
        }
        session.addOutput(output)
    }

    func beginSession() {
        guard !session.isRunning else { return }
        captureQueue.async { [self] in
            self.session.startRunning()
        }
    }

    func stop() {
        stopped = true
        appendQueue.sync { }
        captureQueue.async { [self] in
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
        writerInput = nil
    }

    /// Prefer a 2-channel PCM format so pro interfaces don't deliver 18+ channels.
    private func configurePreferredStereoFormat(on device: AVCaptureDevice) throws {
        let stereoFormats = device.formats.filter { format in
            guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format.formatDescription)?.pointee else {
                return false
            }
            return asbd.mFormatID == kAudioFormatLinearPCM
                && asbd.mChannelsPerFrame == 2
                && asbd.mSampleRate >= 44_100
        }

        guard let best = stereoFormats.max(by: { a, b in
            let aRate = CMAudioFormatDescriptionGetStreamBasicDescription(a.formatDescription)!.pointee.mSampleRate
            let bRate = CMAudioFormatDescriptionGetStreamBasicDescription(b.formatDescription)!.pointee.mSampleRate
            return aRate < bRate
        }) else { return }

        try device.lockForConfiguration()
        device.activeFormat = best
        device.unlockForConfiguration()
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard !stopped,
              sampleBuffer.isValid,
              CMSampleBufferDataIsReady(sampleBuffer)
        else { return }

        onLevel?(AudioSampleProcessing.peakLevel(in: sampleBuffer))

        appendQueue.async { [self] in
            guard !self.stopped,
                  self.timeline.isAnchored,
                  let writerInput = self.writerInput,
                  writerInput.isReadyForMoreMediaData
            else { return }

            let source = self.timeline.retimed(sampleBuffer) ?? sampleBuffer
            let prepared = AudioSampleProcessing.prepareForWriter(from: source)
            if !writerInput.append(prepared) {
                print("Recording: microphone append failed")
            }
        }
    }
}

enum MicrophoneCaptureError: Error {
    case formatUnavailable
    case converterUnavailable
    case noInputDevice
}
