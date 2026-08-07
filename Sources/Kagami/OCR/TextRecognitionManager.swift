import Vision
import AppKit

@MainActor
final class TextRecognitionManager {
    static let shared = TextRecognitionManager()
    private init() {}

    func recognizeText(in image: NSImage, completion: @escaping (String) -> Void) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            completion("")
            return
        }

        let request = VNRecognizeTextRequest { request, error in
            guard error == nil,
                  let observations = request.results as? [VNRecognizedTextObservation]
            else {
                DispatchQueue.main.async { completion("") }
                return
            }

            let text = observations
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")

            DispatchQueue.main.async { completion(text) }
        }
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        DispatchQueue.global(qos: .userInitiated).async {
            try? handler.perform([request])
        }
    }

    /// Capture area, recognize text, copy to clipboard
    func captureAndRecognize() {
        guard ScreenCaptureManager.shared.ensureScreenRecordingPermission() else { return }
        AreaSelectorWindowManager.shared.startCapture(
            hint: "Select an area to copy visible text to your clipboard"
        ) { rect in
            Task { @MainActor in
                guard let image = await ScreenCaptureManager.shared.captureArea(rect) else { return }
                self.recognizeText(in: image) { text in
                    if !text.isEmpty {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        ConfirmationToastWindowManager.shared.show(
                            icon: "checkmark.circle.fill",
                            message: "Text copied to clipboard",
                            anchorRect: rect
                        )
                    } else {
                        ConfirmationToastWindowManager.shared.show(
                            icon: "exclamationmark.triangle.fill",
                            message: "No text found in selection",
                            anchorRect: rect
                        )
                    }
                }
            }
        }
    }
}
