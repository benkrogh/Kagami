import SwiftUI
import AppKit

// MARK: - Recording setup options

struct RecordingSetupOptions {
    var recordArea: Bool = false
    var recordMicrophone: Bool = false
    var recordSystemAudio: Bool = false
    var showWebcam: Bool = false
    var showKeystrokes: Bool = false
    var showClicks: Bool = false
}

// MARK: - Pre-recording setup (single floating toolbar)

/// One combined toggle row (all capture options + inline close button), and a
/// button row below choosing what to record as (video vs. GIF). Both rows are
/// pinned to the same explicit width (`rowContentWidth`) so the "Record Video"/
/// "Record GIF" buttons — which are flexible and would otherwise happily expand
/// to fill whatever width this panel is given — can never drift wider than the
/// toggle row above them.
struct RecordingControlsView: View {
    var onStart: (RecordingSetupOptions, RecordingKind) -> Void
    var onCancel: () -> Void

    @State private var options: RecordingSetupOptions

    init(onStart: @escaping (RecordingSetupOptions, RecordingKind) -> Void, onCancel: @escaping () -> Void) {
        self.onStart = onStart
        self.onCancel = onCancel
        var initial = RecordingSetupOptions()
        // Seed from the persisted defaults so a user's last audio/overlay
        // choices carry over between recordings instead of silently resetting.
        initial.recordMicrophone = AppSettings.shared.recordMicrophone
        initial.recordSystemAudio = AppSettings.shared.recordSystemAudio
        initial.showKeystrokes = AppSettings.shared.showKeystrokes
        initial.showClicks = AppSettings.shared.showClickHighlight
        _options = State(initialValue: initial)
    }

    /// Shared corner radius so the action buttons visually match the icon
    /// toggles/groups above them instead of looking like separate pills.
    private let buttonCornerRadius: CGFloat = 10

    /// Six 40pt icon buttons + inner spacing/padding (268) + a gap (10) + the
    /// 40pt close button. Kept as an explicit constant — rather than letting
    /// either row size itself naturally — so both rows are guaranteed to line
    /// up exactly regardless of the (fixed-size) panel this view is hosted in.
    private let rowContentWidth: CGFloat = 318

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                optionGroup {
                    RecordingOptionButton(icon: "crop", help: "Record a selected area", isOn: $options.recordArea)
                    RecordingOptionButton(icon: "mic.fill", help: "Record from default microphone", isOn: $options.recordMicrophone)
                    RecordingOptionButton(icon: "speaker.wave.2.fill", help: "Record computer/system audio", isOn: $options.recordSystemAudio)
                    RecordingOptionButton(icon: "person.crop.circle", help: "Show webcam overlay", isOn: $options.showWebcam)
                    RecordingOptionButton(icon: "keyboard", help: "Show keystroke overlay", isOn: $options.showKeystrokes)
                    RecordingOptionButton(icon: "cursorarrow.click.2", help: "Highlight mouse clicks", isOn: $options.showClicks)
                }

                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.85))
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape)
                .help("Cancel")
            }
            .frame(width: rowContentWidth)

            HStack(spacing: 8) {
                Button(action: { onStart(options, .video) }) {
                    HStack(spacing: 6) {
                        Image(systemName: "record.circle")
                            .font(.system(size: 12, weight: .bold))
                        Text("Record Video")
                            .font(.system(.callout, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .foregroundColor(.black)
                    .padding(.vertical, 9)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: buttonCornerRadius, style: .continuous))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return)
                .help("Record a video, with audio")

                Button(action: { onStart(options, .gif) }) {
                    HStack(spacing: 6) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 12, weight: .bold))
                        Text("Record GIF")
                            .font(.system(.callout, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .foregroundColor(.white)
                    .padding(.vertical, 9)
                    .background(Color.white.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: buttonCornerRadius, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("Record a silent GIF, up to \(Int(ScreenRecordingManager.gifMaxDuration))s")
            }
            .frame(width: rowContentWidth)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .fixedSize()
    }

    /// Rounded-rect grouping for related icon toggles — same language as the annotate toolbar.
    private func optionGroup<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 4) {
            content()
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Option toggle button

private struct RecordingOptionButton: View {
    let icon: String
    let help: String
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isOn ? Color.black : Color.white.opacity(0.85))
                .frame(width: 34, height: 34)
                .background(isOn ? Color.white : Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .frame(width: 40, height: 40)
        .contentShape(Rectangle())
        .buttonStyle(.plain)
        .help(help)
    }
}
