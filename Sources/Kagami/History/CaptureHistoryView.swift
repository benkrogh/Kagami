import SwiftUI
import AppKit

struct CaptureHistoryView: View {
    @ObservedObject var store = CaptureStore.shared
    @State private var selectedType: CaptureItem.CaptureItemType? = nil
    @State private var searchText = ""
    @State private var selectedItem: CaptureItem? = nil

    var filtered: [CaptureItem] {
        store.captures.filter { item in
            (selectedType == nil || item.type == selectedType) &&
            (searchText.isEmpty || item.fileURL.lastPathComponent.localizedCaseInsensitiveContains(searchText))
        }
    }

    var body: some View {
        HSplitView {
            // Sidebar
            VStack(alignment: .leading, spacing: 0) {
                Text("History")
                    .font(.title2).bold()
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 8)

                // Filter tabs
                HStack(spacing: 4) {
                    filterTab(nil, label: "All")
                    filterTab(.screenshot, label: "Screenshots")
                    filterTab(.recording, label: "Videos")
                    filterTab(.gif, label: "GIFs")
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

                Divider()

                // Search
                HStack {
                    Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                    TextField("Search", text: $searchText)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                Divider()

                if filtered.isEmpty {
                    Spacer()
                    Text("No captures yet")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(filtered) { item in
                                HistoryRowView(item: item, isSelected: selectedItem?.id == item.id)
                                    .onTapGesture { selectedItem = item }
                                    .contextMenu { contextMenu(for: item) }
                            }
                        }
                    }
                }

                Divider()
                HStack {
                    Text("\(filtered.count) items")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .frame(width: 300)
            .background(Color(NSColor.controlBackgroundColor))

            // Detail panel
            if let item = selectedItem {
                CaptureDetailView(item: item)
            } else {
                VStack {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("Select a capture to preview")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(NSColor.windowBackgroundColor))
            }
        }
        .frame(minWidth: 700, minHeight: 500)
    }

    private func filterTab(_ type: CaptureItem.CaptureItemType?, label: String) -> some View {
        Button {
            selectedType = type
        } label: {
            Text(label)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(selectedType == type ? Color.accentColor.opacity(0.15) : Color.clear)
                .cornerRadius(4)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func contextMenu(for item: CaptureItem) -> some View {
        Button("Open in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.fileURL]) }
        Button("Copy") {
            if let img = NSImage(contentsOf: item.fileURL) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([img])
            }
        }
        Button("Annotate") {
            if let img = NSImage(contentsOf: item.fileURL) {
                AnnotationEditorWindowManager.shared.openEditor(for: img, captureItem: item)
            }
        }
        Divider()
        Button("Delete", role: .destructive) { store.deleteCapture(item) }
    }
}

// MARK: - Row View

struct HistoryRowView: View {
    let item: CaptureItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            if let data = item.thumbnailData, let img = NSImage(data: data) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 48, height: 36)
                    .cornerRadius(4)
                    .clipped()
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.2))
                    .frame(width: 48, height: 36)
                    .overlay(Image(systemName: item.type.icon).font(.caption).foregroundColor(.secondary))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.fileURL.lastPathComponent)
                    .font(.caption)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(item.formattedTimestamp)
                    Text("•")
                    Text(item.formattedSize)
                }
                .font(.caption2)
                .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
    }
}

// MARK: - Detail View

struct CaptureDetailView: View {
    let item: CaptureItem
    @State private var image: NSImage? = nil

    var body: some View {
        VStack(spacing: 0) {
            if let img = image {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()

            // Info + actions
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("\(Int(item.dimensions.width)) × \(Int(item.dimensions.height)) px", systemImage: "aspectratio")
                    Label(item.formattedSize, systemImage: "doc")
                    Label(item.formattedTimestamp, systemImage: "calendar")
                }
                .font(.caption)
                .foregroundColor(.secondary)

                Spacer()

                Button("Annotate") {
                    if let img = image {
                        AnnotationEditorWindowManager.shared.openEditor(for: img, captureItem: item)
                    }
                }
                Button("Open in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([item.fileURL])
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(12)
        }
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear { image = NSImage(contentsOf: item.fileURL) }
        .onChange(of: item.id) { image = NSImage(contentsOf: item.fileURL) }
    }
}
