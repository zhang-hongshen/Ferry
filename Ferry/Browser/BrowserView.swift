import AppKit
import QuickLook
import StorageCore
import SwiftUI
import UniformTypeIdentifiers

/// The browser of one tab: path bar, file table, status bar, toolbar, and every file operation's UI.
struct BrowserView: View {
    @Bindable var tab: BrowserTab
    let model: BrowserWindowModel
    @Binding var editorRequest: ConnectionEditorRequest?

    @Environment(ConnectionStore.self) private var store
    @Environment(ConnectionPool.self) private var pool
    @Environment(TransferQueue.self) private var transfers
    @Environment(RemoteClipboard.self) private var clipboard
    @Environment(RemoteFileEditor.self) private var editor

    @State private var pendingDeletion: [RemoteItem]?
    @State private var permissionsTarget: [RemoteItem]?
    @State private var quickLookURL: URL?
    @State private var isFetchingPreview = false
    @State private var isDropTargeted = false
    @State private var toast: LocalizedStringKey?
    @AppStorage("showsInspector") private var showsInspector = false
    @AppStorage("browserViewMode") private var viewMode = BrowserViewMode.list

    private var operations: FileOperations {
        FileOperations(tab: tab, transfers: transfers, conflicts: model.conflicts, pool: pool, store: store)
    }

    private var canPaste: Bool {
        tab.canWriteHere && clipboard.current != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            PathBar(tab: tab)
            Divider()
            files
                .nameClickMonitor(for: tab)
                .overlay { overlay }
                .onDrop(of: [.fileURL, RemoteDragPayload.contentType], isTargeted: $isDropTargeted, perform: drop)
                .overlay {
                    if isDropTargeted {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.accentColor, lineWidth: 3)
                            .padding(2)
                            .allowsHitTesting(false)
                    }
                }
            Divider()
            statusBar
        }
        .navigationTitle(tab.title)
        .searchable(text: $tab.filterText, placement: .toolbar, prompt: Text("Filter"))
        .toolbar { toolbar }
        .quickLookPreview($quickLookURL)
        .onChange(of: tab.pendingAction) { _, action in
            guard let action else { return }
            tab.pendingAction = nil
            handle(action)
        }
        .confirmationDialog(deletionTitle, isPresented: $pendingDeletion.isPresent(), presenting: pendingDeletion) { items in
            Button("Delete", role: .destructive) { tab.delete(items) }
        } message: { items in
            if items.contains(where: \.isContainer) {
                Text("Folders are deleted with everything inside them. This can’t be undone.")
            } else {
                Text("This can’t be undone.")
            }
        }
        .alert(tab.error?.title ?? "", isPresented: $tab.error.isPresent(), presenting: tab.error) { error in
            if error.category == .authentication, let profile = tab.profile {
                Button("Edit Connection…") { editorRequest = .edit(profile) }
            }
            if error.category == .network {
                Button("Retry") { tab.refresh() }
            }
            Button("OK", role: .cancel) {}
        } message: { error in
            Text(error.message)
        }
        .sheet(item: Binding(get: { permissionsTarget.map(PermissionsTarget.init) }, set: { permissionsTarget = $0?.items })) { target in
            PermissionsEditor(items: target.items) { permissions in
                tab.setPermissions(permissions, for: target.items)
            }
        }
    }

    // MARK: Subviews

    @ViewBuilder
    private var files: some View {
        switch viewMode {
        case .icons: FileGridView(tab: tab, canPaste: canPaste, perform: perform)
        case .list: FileTableView(tab: tab, canPaste: canPaste, perform: perform)
        case .columns: FileColumnView(tab: tab, canPaste: canPaste, perform: perform)
        }
    }

    @ViewBuilder
    private var overlay: some View {
        if tab.displayedItems.isEmpty {
            if tab.isLoading {
                ProgressView()
            } else if !tab.filterText.isEmpty {
                ContentUnavailableView.search(text: tab.filterText)
            } else if tab.error != nil {
                ContentUnavailableView("Can’t Load Folder", systemImage: "exclamationmark.triangle")
            }
        }
        if let toast {
            Text(toast)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 16)
                .transition(.opacity)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if tab.selection.isEmpty {
                Text("\(tab.visibleItems.count) items")
            } else {
                Text("\(tab.selection.count) of \(tab.visibleItems.count) selected")
            }
            Spacer()
            if tab.isLoading || isFetchingPreview {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 24)
        .accessibilityElement(children: .combine)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            ControlGroup {
                Button { tab.goBack() } label: { Label("Back", systemImage: "chevron.left") }
                    .disabled(!tab.canGoBack)
                Button { tab.goForward() } label: { Label("Forward", systemImage: "chevron.right") }
                    .disabled(!tab.canGoForward)
            }
            .controlGroupStyle(.navigation)
        }
        ToolbarItem {
            Picker("View", selection: $viewMode) {
                Label("as Icons", systemImage: "square.grid.2x2").tag(BrowserViewMode.icons)
                Label("as List", systemImage: "list.bullet").tag(BrowserViewMode.list)
                Label("as Columns", systemImage: "rectangle.split.3x1").tag(BrowserViewMode.columns)
            }
            .pickerStyle(.segmented)
        }
        ToolbarGroupSpacer()
        ToolbarItemGroup {
            Button { handle(.newFolder) } label: { Label("New Folder", systemImage: "folder.badge.plus") }
                .disabled(!tab.canWriteHere)
            Button { handle(.delete) } label: { Label("Delete", systemImage: "trash") }
                .disabled(tab.selection.isEmpty)
        }
        ToolbarGroupSpacer()
        ToolbarItemGroup {
            Button { handle(.upload) } label: { Label("Upload", systemImage: "arrow.up.doc") }
                .disabled(!tab.canWriteHere)
            Button { handle(.download) } label: { Label("Download", systemImage: "arrow.down.doc") }
                .disabled(tab.selection.isEmpty)
            Button { tab.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
        }
        ToolbarGroupSpacer()
        ToolbarItem {
            Button {
                showsInspector.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .disabled(tab.selection.isEmpty)
        }
    }

    private var deletionTitle: String {
        guard let items = pendingDeletion else { return "" }
        return items.count == 1
            ? String(localized: "Delete “\(items[0].name)”?")
            : String(localized: "Delete \(items.count) items?")
    }

    // MARK: Actions

    private func handle(_ action: BrowserAction) {
        let selected = tab.selectedItems
        switch action {
        case .open: perform(.open, selected)
        case .newFolder: perform(.newFolder, [])
        case .upload: perform(.upload, [])
        case .download: perform(.download, selected)
        case .delete: perform(.delete, selected)
        case .rename: perform(.rename, selected)
        case .quickLook: perform(.quickLook, selected)
        }
    }

    private func perform(_ command: ItemCommand, _ items: [RemoteItem]) {
        tab.cancelRenameOnClick()
        switch command {
        case .open:
            if let item = items.first, items.count == 1 {
                if item.isContainer {
                    tab.navigate(to: item.path)
                } else {
                    edit(item)
                }
            }
        case .quickLook:
            if let item = items.first, !item.isContainer {
                quickLook(item)
            }
        case .download:
            chooseDownloadFolder(for: items)
        case .copy, .cut:
            if let id = tab.profile?.id, !items.isEmpty {
                _ = clipboard.set(items, from: id, isCut: { if case .cut = command { true } else { false } }())
                let text = items.map(\.path.string).joined(separator: "\n")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        case .paste:
            if let contents = clipboard.current, tab.canWriteHere {
                Task { await operations.paste(contents, clipboard: clipboard) }
            }
        case .rename:
            if let item = items.first, items.count == 1 {
                tab.beginRenaming(item)
            }
        case .delete:
            if !items.isEmpty {
                pendingDeletion = items
            }
        case .copyPath:
            copyToPasteboard(items.map(\.path.string).joined(separator: "\n"))
        case .copyURL:
            let urls = items.compactMap { tab.provider?.url(for: $0.path)?.absoluteString }
            copyToPasteboard(urls.joined(separator: "\n"))
        case .presign(let duration):
            if let item = items.first {
                presign(item, duration: duration)
            }
        case .permissions:
            if !items.isEmpty {
                permissionsTarget = items
            }
        case .newFolder:
            tab.createUntitledFolder()
        case .upload:
            chooseUploadItems()
        }
    }

    private func quickLook(_ item: RemoteItem) {
        guard let provider = tab.provider, let id = tab.profile?.id else { return }
        isFetchingPreview = true
        Task {
            defer { isFetchingPreview = false }
            do {
                quickLookURL = try await FileOperations.previewCopy(of: item, connectionID: id, provider: provider)
            } catch {
                tab.error = PresentableError(error)
            }
        }
    }

    /// Opens the file in its default app; saves there upload back to the same location.
    private func edit(_ item: RemoteItem) {
        guard let provider = tab.provider, let id = tab.profile?.id else { return }
        isFetchingPreview = true
        Task {
            defer { isFetchingPreview = false }
            do {
                try await editor.open(item, connectionID: id, provider: provider, transfers: transfers)
            } catch {
                tab.error = PresentableError(error)
            }
        }
    }

    private func presign(_ item: RemoteItem, duration: Duration) {
        guard let provider = tab.provider else { return }
        Task {
            do {
                let url = try await provider.presignedURL(for: item.path, expiresIn: duration)
                copyToPasteboard(url.absoluteString)
            } catch {
                tab.error = PresentableError(error)
            }
        }
    }

    private func copyToPasteboard(_ text: String) {
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showToast("Copied")
    }

    private func showToast(_ text: LocalizedStringKey) {
        withAnimation { toast = text }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation { toast = nil }
        }
    }

    private func chooseUploadItems() {
        guard tab.canWriteHere else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Upload")
        Task {
            guard await panel.begin() == .OK else { return }
            await operations.upload(panel.urls)
        }
    }

    private func chooseDownloadFolder(for items: [RemoteItem]) {
        guard !items.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = .downloadsDirectory
        panel.prompt = String(localized: "Download")
        Task {
            guard await panel.begin() == .OK, let folder = panel.url else { return }
            await operations.download(items, to: folder)
        }
    }

    /// Finder files are uploaded; remote items from another tab or window are copied here.
    private func drop(_ providers: [NSItemProvider]) -> Bool {
        guard tab.canWriteHere else { return false }
        Task {
            var urls: [URL] = []
            for provider in providers {
                if provider.hasItemConformingToTypeIdentifier(RemoteDragPayload.typeIdentifier),
                   let payload = await RemoteDragPayload.load(from: provider) {
                    let sameDirectory = payload.connectionID == tab.profile?.id
                        && payload.items.allSatisfy { $0.path.parent == tab.path }
                    guard !sameDirectory else { continue }
                    let contents = RemoteClipboard.Contents(connectionID: payload.connectionID, items: payload.items,
                                                            isCut: false, text: "")
                    await operations.paste(contents, clipboard: clipboard)
                } else if let url = await RemoteDragPayload.loadFileURL(from: provider) {
                    urls.append(url)
                }
            }
            await operations.upload(urls)
        }
        return true
    }
}

/// Separates toolbar groups; earlier systems have no shared group backgrounds to separate.
private struct ToolbarGroupSpacer: ToolbarContent {
    var body: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed)
        }
    }
}

private struct PermissionsTarget: Identifiable {
    let items: [RemoteItem]
    var id: String { items.map(\.path.string).joined() }
}
