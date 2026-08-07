import AppKit
import SwiftUI

// MARK: - Floating Screenshot Window

@MainActor
final class FloatingWindowManager {
    static let shared = FloatingWindowManager()
    private init() {}

    private var floatingWindows: [UUID: NSWindow] = [:]

    func pin(image: NSImage) {
        let id   = UUID()
        let size = constrainedSize(image.size)

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Pinned Screenshot"
        win.level = .floating
        win.isMovableByWindowBackground = true
        win.collectionBehavior = [.canJoinAllSpaces]
        win.contentView = NSHostingView(rootView: FloatingImageView(image: image, windowID: id) { [weak self] in
            self?.close(id: id)
        })
        win.center()
        win.makeKeyAndOrderFront(nil)
        floatingWindows[id] = win
    }

    private func close(id: UUID) {
        floatingWindows[id]?.close()
        floatingWindows.removeValue(forKey: id)
    }

    private func constrainedSize(_ size: CGSize, maxEdge: CGFloat = 600) -> CGSize {
        let scale = min(maxEdge / size.width, maxEdge / size.height, 1)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
}

// MARK: - Floating Image View

struct FloatingImageView: View {
    let image: NSImage
    let windowID: UUID
    var onClose: (() -> Void)?

    @State private var opacity: Double = 1.0
    @State private var isLocked = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .opacity(opacity)

            // Controls overlay (visible on hover)
            VStack(spacing: 4) {
                Button { onClose?() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.white)
                        .shadow(radius: 2)
                }
                .buttonStyle(.plain)

                Button { isLocked.toggle() } label: {
                    Image(systemName: isLocked ? "lock.fill" : "lock.open")
                        .foregroundColor(.white)
                        .shadow(radius: 2)
                }
                .buttonStyle(.plain)
                .help(isLocked ? "Unlock (allow interaction)" : "Lock (click-through)")
            }
            .padding(6)
        }
        .contextMenu {
            Slider(value: $opacity, in: 0.1...1.0, step: 0.1)
            Text("Opacity: \(Int(opacity * 100))%")
            Divider()
            Button("Close") { onClose?() }
        }
    }
}
