import SwiftUI
import AppKit

// MARK: - Settings chrome tokens (match floating UI / annotation editor)

private enum SettingsStyle {
    static let windowCornerRadius: CGFloat = 18
    static let groupCornerRadius: CGFloat = 12
    static let controlCornerRadius: CGFloat = 8
    static let tabCornerRadius: CGFloat = 9
    static let contentWidth: CGFloat = 560
    static let windowHeight: CGFloat = 560
}

private enum SettingsTab: String, CaseIterable, Identifiable {
    case general, screenshots, recording, storage

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:     return "General"
        case .screenshots: return "Screenshots"
        case .recording:   return "Recording"
        case .storage:     return "Storage"
        }
    }

    var icon: String {
        switch self {
        case .general:     return "gearshape.fill"
        case .screenshots: return "camera.fill"
        case .recording:   return "video.fill"
        case .storage:     return "externaldrive.fill"
        }
    }
}

// MARK: - Root

struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @State private var selectedTab: SettingsTab = .general

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            tabBar
                .padding(.horizontal, 20)
                .padding(.bottom, 16)

            ScrollView {
                Group {
                    switch selectedTab {
                    case .general:
                        GeneralSettingsView(settings: settings)
                    case .screenshots:
                        ScreenshotSettingsView(settings: settings)
                    case .recording:
                        RecordingSettingsView(settings: settings)
                    case .storage:
                        StorageSettingsView(settings: settings)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: SettingsStyle.contentWidth, height: SettingsStyle.windowHeight)
        .overlay {
            RoundedRectangle(cornerRadius: SettingsStyle.windowCornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .onDisappear { settings.saveAll() }
    }

    private var titleBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.7))
            Text("Settings")
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .foregroundStyle(.white)
            Spacer()
        }
        .frame(height: 28)
        .padding(.leading, 78)
        .padding(.trailing, 20)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(SettingsTab.allCases) { tab in
                Button {
                    withAnimation(.easeOut(duration: 0.18)) {
                        selectedTab = tab
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 11, weight: .semibold))
                        Text(tab.title)
                            .font(.system(.callout, weight: .semibold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(selectedTab == tab ? Color.black : Color.white.opacity(0.75))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(selectedTab == tab ? Color.white : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: SettingsStyle.tabCornerRadius, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: SettingsStyle.tabCornerRadius, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Section chrome

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(.caption2, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.45))
                .tracking(0.6)
                .padding(.leading, 4)

            VStack(spacing: 0) {
                content
            }
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: SettingsStyle.groupCornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: SettingsStyle.groupCornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            }
        }
    }
}

private struct SettingsRowDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(height: 1)
            .padding(.leading, 14)
    }
}

private struct SettingsToggleRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(title)
                .font(.system(.body, weight: .medium))
                .foregroundStyle(.white)
        }
        .toggleStyle(.switch)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

private struct SettingsPickerRow<Selection: Hashable, Content: View>: View {
    let title: String
    @Binding var selection: Selection
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(.body, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer(minLength: 8)
            Picker("", selection: $selection, content: content)
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(minWidth: 110, alignment: .trailing)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: SettingsStyle.controlCornerRadius, style: .continuous))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct SettingsCaption: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(.caption))
            .foregroundStyle(Color.white.opacity(0.45))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsColorRow: View {
    let title: String
    @Binding var color: Color

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(.body, weight: .medium))
                .foregroundStyle(.white)
            Spacer(minLength: 8)
            ColorPicker("", selection: $color, supportsOpacity: false)
                .labelsHidden()
                .frame(width: 36, height: 24)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSection(title: "Appearance") {
                SettingsToggleRow(title: "Play capture sound", isOn: $settings.playCaptureSound)
                SettingsRowDivider()
                SettingsPickerRow(title: "Quick access position", selection: $settings.quickAccessPosition) {
                    ForEach(AppSettings.QuickAccessPosition.allCases, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
            }

            SettingsSection(title: "Capture") {
                SettingsPickerRow(title: "Self-timer", selection: $settings.captureDelay) {
                    Text("No Delay").tag(0)
                    Text("1 second").tag(1)
                    Text("3 seconds").tag(3)
                    Text("5 seconds").tag(5)
                }
                SettingsRowDivider()
                SettingsToggleRow(title: "Auto-open annotation after capture", isOn: $settings.autoOpenAnnotation)
                SettingsRowDivider()
                SettingsToggleRow(title: "Auto-hide desktop icons", isOn: $settings.autoHideDesktopIcons)
            }
        }
    }
}

// MARK: - Screenshots

struct ScreenshotSettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSection(title: "Format") {
                SettingsPickerRow(title: "Image format", selection: $settings.imageFormat) {
                    ForEach(AppSettings.ImageFormat.allCases, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
                SettingsRowDivider()
                SettingsToggleRow(title: "Show cursor in screenshots", isOn: $settings.showCursorInScreenshots)
            }
        }
    }
}

// MARK: - Recording

struct RecordingSettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSection(title: "Quality") {
                SettingsPickerRow(title: "Quality", selection: $settings.recordingQuality) {
                    ForEach(AppSettings.RecordingQuality.allCases, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
                SettingsRowDivider()
                SettingsPickerRow(title: "Frame rate", selection: $settings.recordingFPS) {
                    Text("24 fps").tag(24)
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
                SettingsRowDivider()
                SettingsPickerRow(title: "Countdown before recording", selection: $settings.recordingCountdown) {
                    Text("Off").tag(0)
                    Text("3 seconds").tag(3)
                    Text("5 seconds").tag(5)
                }
            }

            SettingsSection(title: "Audio") {
                SettingsToggleRow(title: "Record microphone", isOn: $settings.recordMicrophone)
                SettingsRowDivider()
                SettingsToggleRow(title: "Record system audio", isOn: $settings.recordSystemAudio)
            }

            SettingsSection(title: "Overlays") {
                SettingsToggleRow(title: "Show cursor", isOn: $settings.showCursorInRecordings)
                SettingsRowDivider()
                SettingsToggleRow(title: "Highlight clicks", isOn: $settings.showClickHighlight)
                if settings.showClickHighlight {
                    SettingsRowDivider()
                    SettingsColorRow(
                        title: "Click highlight color",
                        color: Binding(
                            get: { Color(hex: settings.clickHighlightColor) },
                            set: { settings.clickHighlightColor = $0.hexString }
                        )
                    )
                }
                SettingsRowDivider()
                SettingsToggleRow(title: "Show keystroke overlay", isOn: $settings.showKeystrokes)
                SettingsRowDivider()
                SettingsCaption(text: "These toggles set the defaults for the record-setup panel; each recording can still turn them on or off individually.")
            }

            SettingsSection(title: "Webcam") {
                SettingsToggleRow(title: "Mirror video", isOn: $settings.webcamMirrored)
                SettingsRowDivider()
                SettingsPickerRow(title: "Bubble shape", selection: $settings.webcamShape) {
                    ForEach(AppSettings.WebcamShape.allCases, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
                SettingsRowDivider()
                SettingsCaption(text: "Drag the bubble to reposition it while recording, or drag its corner handle to resize.")
            }
        }
    }
}

// MARK: - Storage

struct StorageSettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSection(title: "Save Location") {
                HStack(spacing: 12) {
                    Text(settings.saveLocation.path)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canCreateDirectories = true
                        panel.canChooseFiles = false
                        if panel.runModal() == .OK, let url = panel.url {
                            settings.saveLocation = url
                        }
                    }
                    .buttonStyle(SettingsSecondaryButtonStyle())
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }

            SettingsSection(title: "History") {
                SettingsCaption(text: "Captures older than 30 days are automatically removed.")
                SettingsRowDivider()
                HStack {
                    Spacer(minLength: 0)
                    Button("Clear History…", role: .destructive) {
                        let alert = NSAlert()
                        alert.messageText = "Clear all capture history?"
                        alert.informativeText = "This will delete all saved captures and cannot be undone."
                        alert.addButton(withTitle: "Clear")
                        alert.addButton(withTitle: "Cancel")
                        alert.alertStyle = .warning
                        if alert.runModal() == .alertFirstButtonReturn {
                            CaptureStore.shared.captures.forEach { CaptureStore.shared.deleteCapture($0) }
                        }
                    }
                    .buttonStyle(SettingsDestructiveButtonStyle())
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
    }
}

private struct SettingsSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.callout, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.white.opacity(configuration.isPressed ? 0.18 : 0.12))
            .clipShape(RoundedRectangle(cornerRadius: SettingsStyle.controlCornerRadius, style: .continuous))
    }
}

private struct SettingsDestructiveButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.callout, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.red.opacity(configuration.isPressed ? 0.55 : 0.45))
            .clipShape(RoundedRectangle(cornerRadius: SettingsStyle.controlCornerRadius, style: .continuous))
    }
}

// MARK: - Settings Window

@MainActor
final class SettingsWindowManager {
    static let shared = SettingsWindowManager()
    private init() {}
    private var window: NSWindow?
    private var delegate: DocumentWindowDelegate?

    func open() {
        if let win = window, win.isVisible {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: SettingsStyle.contentWidth, height: SettingsStyle.windowHeight),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = "Kagami Settings"
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.titlebarSeparatorStyle = .none
        win.backgroundColor = .clear
        win.isOpaque = false
        win.appearance = NSAppearance(named: .darkAqua)
        win.isReleasedWhenClosed = false
        win.collectionBehavior = [.moveToActiveSpace, .fullScreenPrimary]
        win.isMovableByWindowBackground = true

        let windowDelegate = DocumentWindowDelegate { [weak self] in
            self?.window = nil
            self?.delegate = nil
            AppWindowActivation.updateActivationPolicy()
        }
        win.delegate = windowDelegate
        delegate = windowDelegate

        let chromeView = SettingsChromeView(frame: NSRect(x: 0, y: 0, width: SettingsStyle.contentWidth, height: SettingsStyle.windowHeight))
        let hostingView = NSHostingView(rootView: SettingsView())
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        chromeView.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: chromeView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: chromeView.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: chromeView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: chromeView.bottomAnchor),
        ])
        win.contentView = chromeView
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win
        AppWindowActivation.updateActivationPolicy()
    }
}

/// Full-bleed frosted chrome — same hudWindow treatment as the annotation editor.
private final class SettingsChromeView: NSVisualEffectView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .behindWindow
        appearance = NSAppearance(named: .darkAqua)
        state = .active
        wantsLayer = true
        layer?.cornerRadius = SettingsStyle.windowCornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        layer?.cornerRadius = SettingsStyle.windowCornerRadius
    }
}
