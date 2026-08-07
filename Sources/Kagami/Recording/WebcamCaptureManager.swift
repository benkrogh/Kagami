import AVFoundation
import AppKit
import SwiftUI

// MARK: - Webcam capture session
//
// Drives a live camera feed for the on-screen webcam bubble (see
// WebcamOverlayWindow.swift). The session itself is exposed so a
// AVCaptureVideoPreviewLayer can attach directly to it — this keeps the
// preview hardware-accelerated and avoids manually shuttling pixel buffers.

@MainActor
final class WebcamCaptureManager: NSObject, ObservableObject {
    static let shared = WebcamCaptureManager()
    private override init() { super.init() }

    let session = AVCaptureSession()

    @Published private(set) var isRunning = false
    @Published private(set) var availableDevices: [AVCaptureDevice] = []
    @Published private(set) var selectedDeviceID: String?

    private var currentInput: AVCaptureDeviceInput?
    private let sessionQueue = DispatchQueue(label: "com.kagami.webcam.session")

    // MARK: - Devices

    func refreshDevices() {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .external],
            mediaType: .video,
            position: .unspecified
        )
        availableDevices = discovery.devices
    }

    // MARK: - Lifecycle

    func start(deviceID: String? = nil) throws {
        refreshDevices()

        let preferredID = deviceID ?? AppSettings.shared.webcamDeviceID
        let device = availableDevices.first(where: { $0.uniqueID == preferredID })
            ?? AVCaptureDevice.default(for: .video)
            ?? availableDevices.first

        guard let device else { throw WebcamCaptureError.noDevice }

        try configureSession(device: device)
        selectedDeviceID = device.uniqueID
        AppSettings.shared.webcamDeviceID = device.uniqueID

        sessionQueue.async { [session] in
            if !session.isRunning { session.startRunning() }
        }
        isRunning = true
    }

    func switchDevice(to deviceID: String) {
        guard deviceID != selectedDeviceID,
              let device = availableDevices.first(where: { $0.uniqueID == deviceID })
        else { return }

        do {
            try configureSession(device: device)
            selectedDeviceID = device.uniqueID
            AppSettings.shared.webcamDeviceID = device.uniqueID
            AppSettings.shared.saveAll()
        } catch {
            print("Webcam device switch error: \(error)")
        }
    }

    func stop() {
        isRunning = false
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    private func configureSession(device: AVCaptureDevice) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        if let currentInput {
            session.removeInput(currentInput)
        }

        session.sessionPreset = .high

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw WebcamCaptureError.cannotAddInput }
        session.addInput(input)
        currentInput = input
    }
}

enum WebcamCaptureError: Error {
    case noDevice
    case cannotAddInput
}

// MARK: - Preview

/// SwiftUI wrapper around an `AVCaptureVideoPreviewLayer` bound to the shared
/// capture session. Kept hardware-accelerated by rendering the preview layer
/// directly as the view's backing layer.
struct WebcamPreviewView: NSViewRepresentable {
    let session: AVCaptureSession
    var mirrored: Bool

    func makeNSView(context: Context) -> WebcamPreviewNSView {
        let view = WebcamPreviewNSView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.setMirrored(mirrored)
        return view
    }

    func updateNSView(_ nsView: WebcamPreviewNSView, context: Context) {
        nsView.setMirrored(mirrored)
    }
}

final class WebcamPreviewNSView: NSView {
    let previewLayer = AVCaptureVideoPreviewLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = previewLayer
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
    }

    func setMirrored(_ mirrored: Bool) {
        guard let connection = previewLayer.connection else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = mirrored
    }
}
