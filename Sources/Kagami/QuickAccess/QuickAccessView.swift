import SwiftUI
import AppKit

struct QuickAccessView: View {
    let captureItem: CaptureItem
    var onDismiss: (() -> Void)?
    /// Called right before the share picker opens so the host window's
    /// auto-close timer can be suspended — otherwise the card (and the view
    /// the picker is anchored to) could disappear mid-pick.
    var onBeginSharing: (() -> Void)?

    @State private var copied = false
    @State private var thumbnail: NSImage?
    @State private var displayDimensions: CGSize = .zero
    @State private var shareAnchor: NSView?
    @State private var sharePickerDelegate: SharePickerDelegate?

    private var isScreenshot: Bool { captureItem.type == .screenshot }

    var body: some View {
        VStack(spacing: 14) {
            header
            preview
            metadataBar
            actionBar
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .preferredColorScheme(.dark)
        .onAppear { loadPreview() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: headerIcon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(headerIconTint)
            Text(headerTitle)
                .font(.system(.callout, weight: .semibold))
                .foregroundStyle(.white)
            Spacer()
            Button { onDismiss?() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.55))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
    }

    private var headerIcon: String {
        switch captureItem.type {
        case .screenshot: return "camera.fill"
        case .recording:  return "video.fill"
        case .gif:        return "film.fill"
        }
    }

    private var headerIconTint: Color {
        captureItem.type == .recording ? .red : Color.white.opacity(0.85)
    }

    private var headerTitle: String {
        switch captureItem.type {
        case .screenshot: return "Screenshot"
        case .recording:  return "Recording"
        case .gif:        return "GIF"
        }
    }

    // MARK: - Preview

    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(0.35))
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)

            if let thumb = thumbnail {
                Image(nsImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(4)
            } else {
                Image(systemName: captureItem.type.icon)
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.25))
            }

            if captureItem.type == .recording {
                Image(systemName: "play.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 44, height: 44)
                    .background(Color.black.opacity(0.45))
                    .clipShape(Circle())
            }
        }
        .frame(height: 148)
    }

    // MARK: - Metadata

    private var metadataBar: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(dimensionLabel)
                    .font(.system(.caption, design: .monospaced, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                Text(captureItem.formattedSize)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.45))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                if let duration = captureItem.durationSeconds, duration > 0 {
                    Text(formatDuration(duration))
                        .font(.system(.caption, design: .monospaced, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                }
                Text(captureItem.formattedTimestamp)
                    .font(.system(.caption2))
                    .foregroundStyle(Color.white.opacity(0.45))
            }
        }
        .padding(.horizontal, 4)
    }

    private var dimensionLabel: String {
        let w = Int(displayDimensions.width)
        let h = Int(displayDimensions.height)
        guard w > 0, h > 0 else { return "—" }
        return "\(w) × \(h)"
    }

    // MARK: - Actions

    private var actionBar: some View {
        HStack(spacing: 8) {
            actionButton(
                icon: copied ? "checkmark" : "doc.on.clipboard",
                label: copied ? "Copied" : "Copy",
                isPrimary: false,
                action: copyToClipboard
            )
            actionButton(icon: "folder", label: "Save", isPrimary: false, action: revealInFinder)
            if isScreenshot {
                actionButton(icon: "pencil", label: "Annotate", isPrimary: false, action: openAnnotator)
            }
            actionButton(icon: "square.and.arrow.up", label: "Share", isPrimary: true, action: share)
                .background(ShareAnchorView { view in shareAnchor = view })
        }
    }

    private func actionButton(
        icon: String,
        label: String,
        isPrimary: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                Text(label)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(isPrimary ? Color.black : Color.white.opacity(0.88))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(isPrimary ? Color.white : Color.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Loading

    private func loadPreview() {
        displayDimensions = captureItem.dimensions

        if let data = captureItem.thumbnailData, let img = NSImage(data: data) {
            thumbnail = img
            if displayDimensions == .zero { displayDimensions = img.size }
            return
        }

        switch captureItem.type {
        case .screenshot:
            if let img = NSImage(contentsOf: captureItem.fileURL) {
                thumbnail = img
                if displayDimensions == .zero { displayDimensions = img.size }
            }
        case .recording:
            let meta = CaptureMediaHelpers.videoMetadata(from: captureItem.fileURL)
            thumbnail = meta.thumbnail
            if displayDimensions == .zero { displayDimensions = meta.dimensions }
        case .gif:
            if let img = NSImage(contentsOf: captureItem.fileURL) {
                thumbnail = img
                if displayDimensions == .zero { displayDimensions = img.size }
            }
        }
    }

    // MARK: - Actions

    private func copyToClipboard() {
        let pb = NSPasteboard.general
        pb.clearContents()
        if isScreenshot, let image = NSImage(contentsOf: captureItem.fileURL) {
            pb.writeObjects([image])
        } else {
            pb.writeObjects([captureItem.fileURL as NSURL])
        }
        withAnimation { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
    }

    private func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([captureItem.fileURL])
        onDismiss?()
    }

    private func openAnnotator() {
        guard let image = NSImage(contentsOf: captureItem.fileURL) else { return }
        AnnotationEditorWindowManager.shared.openEditor(for: image, captureItem: captureItem)
        onDismiss?()
    }

    private func share() {
        // The card lives in a non-activating panel, so it's never
        // `NSApp.keyWindow` — anchor to the button's own view/window instead.
        guard let anchor = shareAnchor, anchor.window != nil else { return }

        onBeginSharing?()
        NSApp.activate(ignoringOtherApps: true)

        let picker = NSSharingServicePicker(items: [captureItem.fileURL])
        let delegate = SharePickerDelegate { [onDismiss] in
            DispatchQueue.main.async { onDismiss?() }
        }
        sharePickerDelegate = delegate
        picker.delegate = delegate
        picker.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    private func formatDuration(_ seconds: Double) -> String {
        let t = Int(seconds.rounded())
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

// MARK: - Share support

/// Zero-size NSView placed behind the Share button purely so we can hand
/// `NSSharingServicePicker` a real anchor (and its owning `NSWindow`) — the
/// quick-access card's panel is non-activating and never becomes key, so
/// `NSApp.keyWindow` isn't a reliable way to find it.
private struct ShareAnchorView: NSViewRepresentable {
    let onResolve: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { onResolve(view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Closes the quick-access card once the user finishes with the share
/// picker (whether they picked a service or dismissed it).
private final class SharePickerDelegate: NSObject, NSSharingServicePickerDelegate {
    private let onFinish: () -> Void

    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
    }

    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        sharingServicePicker.delegate = nil
        onFinish()
    }
}
