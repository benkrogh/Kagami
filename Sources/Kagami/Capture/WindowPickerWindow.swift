import AppKit
import SwiftUI

// MARK: - Window Picker chrome tokens (match Settings / Annotation editor frosted glass)

private enum WindowPickerStyle {
    static let windowCornerRadius: CGFloat = 18
    static let rowCornerRadius: CGFloat = 10
    static let width: CGFloat = 440
    static let height: CGFloat = 520
}

// MARK: - Window Picker

@MainActor
final class WindowPickerWindowManager {
    static let shared = WindowPickerWindowManager()
    private init() {}

    private var window: NSWindow?
    private var delegate: DocumentWindowDelegate?
    private var escMonitor: EscapeKeyMonitor?

    func show(completion: @escaping (CGWindowID) -> Void) {
        dismiss()

        let windows = ScreenCaptureManager.shared.onScreenWindows()

        let picker = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: WindowPickerStyle.width, height: WindowPickerStyle.height),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        picker.title = "Select a Window"
        picker.titlebarAppearsTransparent = true
        picker.titleVisibility = .hidden
        picker.titlebarSeparatorStyle = .none
        picker.backgroundColor = .clear
        picker.isOpaque = false
        picker.appearance = NSAppearance(named: .darkAqua)
        picker.isMovableByWindowBackground = true
        picker.collectionBehavior = [.moveToActiveSpace, .fullScreenPrimary]
        // Without this, closing the picker from inside its own SwiftUI button
        // action (tapping a row) deallocates the window mid-callback and
        // crashes the app: AppKit's `close()` also drops its own internal
        // reference, and losing the last reference to the window (and its
        // hosting view) while one of its own SwiftUI buttons is still on the
        // call stack is a use-after-free. Every other document-style window in
        // the app (Settings, Annotation editor, History) sets this for the
        // same reason.
        picker.isReleasedWhenClosed = false

        let windowDelegate = DocumentWindowDelegate { [weak self] in
            self?.cleanup()
        }
        picker.delegate = windowDelegate
        delegate = windowDelegate

        let monitor = EscapeKeyMonitor { [weak self] in self?.dismiss() }
        monitor.start()
        escMonitor = monitor

        let view = WindowPickerView(
            windows: windows,
            onSelect: { [weak self] windowID in
                self?.dismiss()
                completion(windowID)
            },
            onCancel: { [weak self] in self?.dismiss() }
        )

        let chromeView = WindowPickerChromeView(frame: NSRect(x: 0, y: 0, width: WindowPickerStyle.width, height: WindowPickerStyle.height))
        let hostingView = NSHostingView(rootView: view)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        chromeView.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: chromeView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: chromeView.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: chromeView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: chromeView.bottomAnchor),
        ])
        picker.contentView = chromeView
        picker.center()
        picker.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = picker
        AppWindowActivation.updateActivationPolicy()
    }

    func dismiss() {
        escMonitor?.stop()
        escMonitor = nil
        window?.delegate = nil
        window?.close()
        cleanup()
    }

    private func cleanup() {
        escMonitor?.stop()
        escMonitor = nil
        window = nil
        delegate = nil
        AppWindowActivation.updateActivationPolicy()
    }
}

/// Full-bleed frosted chrome that extends under the title bar traffic lights —
/// same treatment as the Settings window and the Annotation editor.
private final class WindowPickerChromeView: NSVisualEffectView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .behindWindow
        appearance = NSAppearance(named: .darkAqua)
        state = .active
        wantsLayer = true
        layer?.cornerRadius = WindowPickerStyle.windowCornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        layer?.cornerRadius = WindowPickerStyle.windowCornerRadius
    }
}

// MARK: - Window Picker View

struct WindowPickerView: View {
    let windows: [ScreenCaptureManager.WindowInfo]
    var onSelect: (CGWindowID) -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Color.white.opacity(0.08))

            if windows.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(windows) { win in
                            WindowPickerRow(window: win) { onSelect(win.id) }
                        }
                    }
                    .padding(12)
                }
            }

            Divider().background(Color.white.opacity(0.08))
            footer
        }
        .frame(width: WindowPickerStyle.width, height: WindowPickerStyle.height)
        .overlay {
            RoundedRectangle(cornerRadius: WindowPickerStyle.windowCornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "macwindow")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.7))
            VStack(alignment: .leading, spacing: 1) {
                Text("Capture Window")
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Choose a window to capture")
                    .font(.system(.caption))
                    .foregroundStyle(Color.white.opacity(0.45))
            }
            Spacer()
        }
        .padding(.leading, 78)
        .padding(.trailing, 20)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "macwindow")
                .font(.system(size: 28))
                .foregroundStyle(Color.white.opacity(0.25))
            Text("No windows available to capture")
                .font(.system(.callout, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            Text("Press Esc to cancel")
                .font(.system(.caption))
                .foregroundStyle(Color.white.opacity(0.35))
            Spacer()
            Button("Cancel", action: onCancel)
                .buttonStyle(WindowPickerSecondaryButtonStyle())
                .keyboardShortcut(.escape)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

// MARK: - Row

private struct WindowPickerRow: View {
    let window: ScreenCaptureManager.WindowInfo
    let onSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                appIcon
                    .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(window.title.isEmpty ? window.ownerName : window.title)
                        .font(.system(.body, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(window.ownerName)
                        .font(.system(.caption))
                        .foregroundStyle(Color.white.opacity(0.5))
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Text("\(Int(window.bounds.width)) × \(Int(window.bounds.height))")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.4))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(isHovering ? Color.white.opacity(0.1) : Color.white.opacity(0.03))
            .clipShape(RoundedRectangle(cornerRadius: WindowPickerStyle.rowCornerRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: WindowPickerStyle.rowCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    @ViewBuilder
    private var appIcon: some View {
        if let icon = NSRunningApplication(processIdentifier: window.ownerPID)?.icon {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(0.08))
                .overlay(
                    Image(systemName: "macwindow")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.6))
                )
        }
    }
}

private struct WindowPickerSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.callout, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.white.opacity(configuration.isPressed ? 0.18 : 0.12))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
