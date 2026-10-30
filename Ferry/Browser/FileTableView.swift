import AppKit
import StorageCore
import SwiftUI
import UniformTypeIdentifiers

/// Commands the file table asks the browser to perform.
enum ItemCommand {
    case open
    case quickLook
    case download
    case copy
    case cut
    case paste
    case rename
    case delete
    case copyPath
    case copyURL
    case presign(Duration)
    case permissions
    case newFolder
    case upload
}

/// The sortable, multi-selectable listing of the current directory. Folders expand in place.
struct FileTableView: View {
    @Bindable var tab: BrowserTab
    let canPaste: Bool
    let perform: (ItemCommand, [RemoteItem]) -> Void

    @State private var columns = TableColumnCustomization<RemoteItem>()

    var body: some View {
        // Read here so loading or expanding a folder, or an upload starting, updates the rows.
        let children = Dictionary(uniqueKeysWithValues: tab.childItems.map { folder, items in
            (folder, tab.withUploads(items, in: folder))
        })
        let outline = FileOutline(children: children, expanded: tab.expandedFolders)
        Table(of: RemoteItem.self, selection: $tab.selection, sortOrder: $tab.sortOrder,
              columnCustomization: $columns) {
            TableColumn("Name", value: \.name) { item in
                let uploads = tab.uploads(at: item.path)
                HStack(spacing: 6) {
                    Label {
                        if tab.renamingPath == item.path {
                            InlineNameField(name: item.name, isContainer: item.isContainer) {
                                tab.commitRenaming(item, to: $0)
                            } cancel: {
                                tab.cancelRenaming()
                            }
                        } else {
                            Text(item.name)
                                .renameOnClick(item.path, in: tab)
                        }
                    } icon: {
                        FileIcon(item: item)
                    }
                    .uploadDimmed(item, uploads: uploads)
                    Spacer(minLength: 0)
                    UploadProgressView(jobs: uploads, isContainer: item.isContainer)
                }
            }
            .width(min: 160, ideal: 280)
            .customizationID("name")

            TableColumn("Date Modified", value: \.sortDate) { item in
                Text(item.modificationDate?.formatted(date: .abbreviated, time: .shortened) ?? "")
                    .foregroundStyle(.secondary)
            }
            .width(min: 100, ideal: 150)
            .customizationID("modified")

            TableColumn("Size", value: \.sortSize) { item in
                Text(item.isContainer ? "--" : item.size.map { $0.formatted(.byteCount(style: .file)) } ?? "")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 60, ideal: 80)
            .customizationID("size")

            TableColumn("Kind", value: \.typeDescription) { item in
                Text(item.typeDescription)
                    .foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 120)
            .customizationID("kind")

            TableColumn("Permissions", value: \.permissionsDescription) { item in
                Text(item.permissionsDescription)
                    .font(.body.monospaced())
                    .foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 100)
            .customizationID("permissions")

            TableColumn("Owner", value: \.ownerDescription) { item in
                Text(item.ownerDescription)
                    .foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 100)
            .customizationID("owner")
        } rows: {
            FileRows(items: tab.displayedItems, outline: outline, tab: tab, dragProvider: tab.dragProvider)
        }
        .contextMenu(forSelectionType: RemotePath.self) { paths in
            ItemContextMenu(tab: tab, items: tab.items(at: paths), canPaste: canPaste, perform: perform)
        } primaryAction: { paths in
            perform(.open, tab.items(at: paths))
        }
        .onKeyPress(.space) {
            guard tab.selection.count == 1 else { return .ignored }
            perform(.quickLook, tab.selectedItems)
            return .handled
        }
        .onKeyPress(.return) {
            guard tab.selection.count == 1 else { return .ignored }
            perform(.rename, tab.selectedItems)
            return .handled
        }
        .onDeleteCommand {
            perform(.delete, tab.selectedItems)
        }
        .onCopyCommand {
            commandProviders(.copy)
        }
        .onCutCommand {
            commandProviders(.cut)
        }
        .onPasteCommand(of: [.plainText]) { _ in
            perform(.paste, [])
        }
        .onAppear(perform: updateColumnVisibility)
        .onChange(of: tab.capabilities) { updateColumnVisibility() }
        .accessibilityIdentifier("fileTable")
    }

    /// Permissions and owner only make sense for protocols that report them.
    private func updateColumnVisibility() {
        let visibility: Visibility = tab.capabilities.contains(.posixAttributes) ? .visible : .hidden
        columns[visibility: "permissions"] = visibility
        columns[visibility: "owner"] = visibility
    }

    private func commandProviders(_ command: ItemCommand) -> [NSItemProvider] {
        let items = tab.selectedItems
        guard !items.isEmpty else { return [] }
        perform(command, items)
        return [NSItemProvider(object: items.map(\.path.string).joined(separator: "\n") as NSString)]
    }
}

/// Expansion state captured by the table body.
private struct FileOutline {
    let children: [RemotePath: [RemoteItem]]
    let expanded: Set<RemotePath>
}

/// Rows for one directory level; folders are disclosure rows holding their own level.
private struct FileRows: TableRowContent {
    typealias TableRowValue = RemoteItem

    let items: [RemoteItem]
    let outline: FileOutline
    let tab: BrowserTab
    let dragProvider: (RemoteItem) -> NSItemProvider?

    @TableRowBuilder<RemoteItem>
    var tableRowBody: some TableRowContent<RemoteItem> {
        ForEach(items.filter(\.isContainer)) { folder in
            DisclosureTableRow(folder, isExpanded: expansion(of: folder)) {
                FileRows(items: outline.children[folder.path] ?? [], outline: outline, tab: tab,
                         dragProvider: dragProvider)
            }
            .itemProvider { dragProvider(folder) }
        }
        ForEach(items.filter { !$0.isContainer }) { file in
            TableRow(file)
                .itemProvider { dragProvider(file) }
        }
    }

    private func expansion(of folder: RemoteItem) -> Binding<Bool> {
        Binding {
            outline.expanded.contains(folder.path)
        } set: { expanded in
            tab.setExpanded(expanded, folder.path)
        }
    }
}

/// The context menu for the clicked items, or for the directory when `items` is empty.
struct ItemContextMenu: View {
    let tab: BrowserTab
    let items: [RemoteItem]
    let canPaste: Bool
    let perform: (ItemCommand, [RemoteItem]) -> Void

    private static let presignDurations: [(LocalizedStringKey, Duration)] = [
        ("1 Hour", .seconds(3600)),
        ("1 Day", .seconds(86_400)),
        ("7 Days", .seconds(7 * 86_400)),
    ]

    var body: some View {
        let capabilities = tab.capabilities
        let uploads = items.flatMap { $0.isContainer ? [] : tab.uploads(at: $0.path) }
        if !items.isEmpty, items.allSatisfy({ item in uploads.contains { $0.destinationPath == item.path } }) {
            let failed = uploads.filter { $0.failureMessage != nil }
            if !failed.isEmpty {
                Button("Retry Upload") { failed.forEach(tab.transfers.retry) }
            }
            Button("Cancel Upload") { uploads.forEach(tab.transfers.cancel) }
        } else if items.isEmpty {
            Button("New Folder") { perform(.newFolder, []) }
                .disabled(!tab.canWriteHere)
            Button("Upload…") { perform(.upload, []) }
                .disabled(!tab.canWriteHere)
            Button("Paste") { perform(.paste, []) }
                .disabled(!canPaste)
        } else {
            if items.count == 1 {
                Button("Open") { perform(.open, items) }
                if !items[0].isContainer {
                    Button("Quick Look") { perform(.quickLook, items) }
                }
            }
            Button("Download…") { perform(.download, items) }
            Divider()
            Button("Copy") { perform(.copy, items) }
            Button("Cut") { perform(.cut, items) }
            Button("Paste") { perform(.paste, []) }
                .disabled(!canPaste)
            Divider()
            if items.count == 1 {
                Button("Rename…") { perform(.rename, items) }
            }
            if capabilities.contains(.permissions) {
                Button("Permissions…") { perform(.permissions, items) }
            }
            Button("Delete…", role: .destructive) { perform(.delete, items) }
            Divider()
            Button("Copy Path") { perform(.copyPath, items) }
            if tab.provider?.url(for: items[0].path) != nil {
                Button("Copy URL") { perform(.copyURL, items) }
            }
            if capabilities.contains(.presignedURLs), items.count == 1, !items[0].isContainer {
                Menu("Copy Presigned Link") {
                    ForEach(Self.presignDurations, id: \.1) { title, duration in
                        Button(title) { perform(.presign(duration), items) }
                    }
                }
            }
        }
    }
}

/// A ring with the progress of a file's upload, a spinner for a folder receiving uploads, and a
/// warning when an upload failed.
struct UploadProgressView: View {
    let jobs: [TransferJob]
    let isContainer: Bool

    var body: some View {
        if let failure = jobs.lazy.compactMap(\.failureMessage).first {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .help(failure)
                .accessibilityLabel("Upload Failed")
                .accessibilityValue(failure)
        } else if isContainer, !jobs.isEmpty {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Uploading")
        } else if let job = jobs.first {
            ProgressView(value: fraction(of: job))
                .progressViewStyle(.circular)
                .controlSize(.small)
                .accessibilityLabel("Uploading")
        }
    }

    /// Spoken by rows that hide their children from accessibility.
    static func status(of jobs: [TransferJob]) -> String? {
        if let failure = jobs.lazy.compactMap(\.failureMessage).first {
            return String(localized: "Upload failed: \(failure)")
        }
        return jobs.isEmpty ? nil : String(localized: "Uploading")
    }

    private func fraction(of job: TransferJob) -> Double {
        guard let total = job.record.totalBytes, total > 0 else { return 0 }
        return min(1, Double(job.record.completedBytes) / Double(total))
    }
}

extension View {
    /// Files still uploading are dimmed, as Finder dims files being copied.
    func uploadDimmed(_ item: RemoteItem, uploads: [TransferJob]) -> some View {
        opacity(!item.isContainer && !uploads.isEmpty ? 0.5 : 1)
    }
}

/// The Finder icon for the item's type.
struct FileIcon: View {
    let item: RemoteItem
    var size: CGFloat = 16

    var body: some View {
        if item.kind == .bucket {
            Image(systemName: "archivebox")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.tint)
                .frame(width: size * 0.8, height: size * 0.8)
                .frame(width: size, height: size)
        } else {
            Image(nsImage: FileIconCache.icon(for: item))
                .resizable()
                .frame(width: size, height: size)
        }
    }
}

enum FileIconCache {
    private static var icons: [String: NSImage] = [:]

    static func icon(for item: RemoteItem) -> NSImage {
        let type = item.contentType ?? .data
        if let icon = icons[type.identifier] {
            return icon
        }
        let icon = NSWorkspace.shared.icon(for: type)
        icons[type.identifier] = icon
        return icon
    }
}
