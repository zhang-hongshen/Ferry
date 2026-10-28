import AppKit
import StorageCore
import SwiftUI

/// Metadata of the selected item: a thumbnail for images, attributes, and for S3, editable
/// object metadata.
struct InspectorView: View {
    let tab: BrowserTab?

    var body: some View {
        Group {
            if let tab, tab.selection.count == 1, let item = tab.selectedItems.first {
                ItemInspector(tab: tab, item: item)
                    .id(item.path)
            } else if let tab, tab.selection.count > 1 {
                MultipleSelectionInspector(items: tab.selectedItems)
            } else {
                ContentUnavailableView("No Selection", systemImage: "info.circle")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct MultipleSelectionInspector: View {
    let items: [RemoteItem]

    var body: some View {
        Form {
            LabeledContent("Items", value: items.count.formatted())
            LabeledContent("Size", value: items.compactMap(\.size).reduce(0, +).formatted(.byteCount(style: .file)))
        }
        .formStyle(.grouped)
    }
}

private struct ItemInspector: View {
    let tab: BrowserTab
    let item: RemoteItem

    @State private var folderSize: Int64?

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    ThumbnailView(tab: tab, item: item)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 8)
                    Text(item.name)
                        .font(.title3.weight(.semibold))
                        .textSelection(.enabled)
                    Text(summary)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Information") {
                if let date = item.creationDate {
                    LabeledContent("Created", value: date.formatted(date: .complete, time: .shortened))
                }
                if let date = item.modificationDate {
                    LabeledContent("Modified", value: date.formatted(date: .complete, time: .shortened))
                }
                LabeledContent("Path") {
                    Text(item.path.string)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                }
                if item.permissions != nil {
                    LabeledContent("Permissions") {
                        Text(item.permissionsDescription)
                            .font(.body.monospaced())
                    }
                }
                if !item.ownerDescription.isEmpty {
                    LabeledContent("Owner", value: item.ownerDescription)
                }
                if let target = item.symbolicLinkTarget {
                    LabeledContent("Original", value: target)
                }
            }
            if tab.capabilities.contains(.metadataEditing), item.kind == .file {
                MetadataEditor(tab: tab, item: item)
            }
        }
        .formStyle(.grouped)
        .task { await calculateFolderSize() }
    }

    /// Kind and size, like Finder's "Folder – 13.8 MB".
    private var summary: String {
        let size = item.isContainer ? folderSize : item.size
        return ([item.typeDescription] + [size?.formatted(.byteCount(style: .file))].compactMap { $0 })
            .joined(separator: " – ")
    }

    /// Sums the files below a folder. The listing is cancelled when the selection changes; on
    /// failure the size stays hidden, as it is for protocols that report no sizes.
    private func calculateFolderSize() async {
        guard item.isContainer, let provider = tab.provider else { return }
        var total: Int64 = 0
        do {
            for try await page in provider.listRecursively(item.path) {
                total += page.filter { !$0.isContainer }.compactMap(\.size).reduce(0, +)
            }
            folderSize = total
        } catch {
            folderSize = nil
        }
    }
}

/// Shows an image preview. Images over the size limit load only on request.
private struct ThumbnailView: View {
    let tab: BrowserTab
    let item: RemoteItem

    private static let automaticLimit: Int64 = 10 * 1024 * 1024
    @State private var image: NSImage?
    @State private var isLoading = false
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 180)
                    .accessibilityLabel(Text("Preview of \(item.name)"))
            } else if isLoading {
                ProgressView()
                    .frame(height: 96)
            } else if item.isImage && !failed && (item.size ?? 0) > Self.automaticLimit {
                VStack {
                    largeIcon
                    Button("Load Preview", action: load)
                }
            } else {
                largeIcon
            }
        }
        .task {
            if item.isImage, (item.size ?? 0) <= Self.automaticLimit {
                load()
            }
        }
    }

    private var largeIcon: some View {
        Image(nsImage: FileIconCache.icon(for: item))
            .resizable()
            .frame(width: 64, height: 64)
            .accessibilityHidden(true)
    }

    private func load() {
        guard let provider = tab.provider, let id = tab.profile?.id, !isLoading else { return }
        isLoading = true
        Task {
            defer { isLoading = false }
            do {
                let url = try await FileOperations.previewCopy(of: item, connectionID: id, provider: provider)
                image = NSImage(contentsOf: url)
                failed = image == nil
            } catch {
                failed = true
            }
        }
    }
}
