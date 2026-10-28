import AppKit
import StorageCore
import SwiftUI
import UniformTypeIdentifiers

/// Finder's column view: one column per folder from the tab's top path down to the current directory.
/// Selecting a single folder opens it as the next column.
struct FileColumnView: View {
    @Bindable var tab: BrowserTab
    let canPaste: Bool
    let perform: (ItemCommand, [RemoteItem]) -> Void

    @FocusState private var focusedColumn: RemotePath?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(tab.columnPaths, id: \.self) { folder in
                        column(folder)
                            .id(folder)
                        Divider()
                    }
                }
            }
            .onChange(of: tab.path) { _, path in
                tab.loadColumns()
                withAnimation { proxy.scrollTo(path, anchor: .trailing) }
            }
        }
        .onAppear { tab.loadColumns() }
        .accessibilityIdentifier("fileColumns")
    }

    private func column(_ folder: RemotePath) -> some View {
        List(selection: selection(in: folder)) {
            ForEach(tab.columnContents(of: folder)) { item in
                FileColumnRow(item: item, tab: tab)
                    .itemProvider { tab.dragProvider(for: item) }
            }
        }
        .contextMenu(forSelectionType: RemotePath.self) { paths in
            // The empty-area menu acts on the current directory, so only its column offers it.
            if !paths.isEmpty || folder == tab.path {
                ItemContextMenu(tab: tab, items: tab.items(at: paths), canPaste: canPaste, perform: perform)
            }
        } primaryAction: { paths in
            perform(.open, tab.items(at: paths))
        }
        .focused($focusedColumn, equals: folder)
        .onKeyPress(.leftArrow) { moveLeft(from: folder) }
        .onKeyPress(.rightArrow) { moveRight(from: folder) }
        .onKeyPress(.space) {
            let items = focusedItems(in: folder)
            guard items.count == 1 else { return .ignored }
            perform(.quickLook, items)
            return .handled
        }
        .onKeyPress(.return) {
            let items = focusedItems(in: folder)
            guard items.count == 1 else { return .ignored }
            perform(.rename, items)
            return .handled
        }
        .onDeleteCommand {
            perform(.delete, focusedItems(in: folder))
        }
        .onCopyCommand {
            commandProviders(.copy, in: folder)
        }
        .onCutCommand {
            commandProviders(.cut, in: folder)
        }
        .onPasteCommand(of: [.plainText]) { _ in
            perform(.paste, [])
        }
        .frame(width: 240)
        .frame(maxHeight: .infinity)
    }

    /// The current directory's column holds the selection; a column above it highlights the folder
    /// open to its right.
    private func selection(in folder: RemotePath) -> Binding<Set<RemotePath>> {
        Binding {
            if folder == tab.path {
                return tab.selection
            }
            return openChild(of: folder).map { Set([$0]) } ?? []
        } set: { paths in
            tab.selectInColumn(paths, of: folder)
        }
    }

    private func openChild(of folder: RemotePath) -> RemotePath? {
        guard folder != tab.path, tab.path.hasPrefix(folder) else { return nil }
        return RemotePath(components: Array(tab.path.components.prefix(folder.components.count + 1)))
    }

    /// The items the keyboard acts on in a column: its selection or highlighted folder.
    private func focusedItems(in folder: RemotePath) -> [RemoteItem] {
        if let child = openChild(of: folder) {
            return tab.items(at: [child])
        }
        return tab.selectedItems
    }

    /// Moves to the column on the left, leaving this column's folder highlighted there.
    private func moveLeft(from folder: RemotePath) -> KeyPress.Result {
        guard folder != tab.columnPaths.first, let parent = folder.parent else { return .ignored }
        tab.navigate(to: folder)
        focusedColumn = parent
        return .handled
    }

    /// Moves into the highlighted folder's column and selects its first item.
    private func moveRight(from folder: RemotePath) -> KeyPress.Result {
        let child: RemotePath
        if let open = openChild(of: folder) {
            child = open
        } else if let selected = tab.selectedItems.first, tab.selection.count == 1, selected.isContainer {
            tab.navigate(to: selected.path)
            child = selected.path
        } else {
            return .ignored
        }
        focusedColumn = child
        if let first = tab.columnContents(of: child).first {
            tab.selectInColumn([first.path], of: child)
        }
        return .handled
    }

    private func commandProviders(_ command: ItemCommand, in folder: RemotePath) -> [NSItemProvider] {
        let items = focusedItems(in: folder)
        guard !items.isEmpty else { return [] }
        perform(command, items)
        return [NSItemProvider(object: items.map(\.path.string).joined(separator: "\n") as NSString)]
    }
}

/// One item of a column: icon, name, and a chevron for folders.
private struct FileColumnRow: View {
    let item: RemoteItem
    let tab: BrowserTab

    var body: some View {
        let isRenaming = tab.renamingPath == item.path
        let uploads = tab.uploads(at: item.path)
        HStack(spacing: 6) {
            FileIcon(item: item)
                .uploadDimmed(item, uploads: uploads)
            if isRenaming {
                InlineNameField(name: item.name, isContainer: item.isContainer) {
                    tab.commitRenaming(item, to: $0)
                } cancel: {
                    tab.cancelRenaming()
                }
            } else {
                Text(item.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .renameOnClick(item.path, in: tab)
                    .uploadDimmed(item, uploads: uploads)
            }
            Spacer(minLength: 0)
            UploadProgressView(jobs: uploads, isContainer: item.isContainer)
            if item.isContainer {
                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: isRenaming ? .contain : .ignore)
        .accessibilityLabel(item.name)
        .accessibilityValue(UploadProgressView.status(of: uploads) ?? item.typeDescription)
    }
}
