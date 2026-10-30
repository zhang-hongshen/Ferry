import AppKit
import Observation
import StorageCore
import UniformTypeIdentifiers

/// Requests from menu commands that the browser view performs with its own UI.
enum BrowserAction: Hashable {
    case open
    case newFolder
    case upload
    case download
    case delete
    case rename
    case quickLook
}

/// How the browser lays out the current directory.
enum BrowserViewMode: String {
    case icons
    case list
    case columns
}

/// One browser tab: a connection, the current directory, its listing, and navigation history.
@Observable
final class BrowserTab: Identifiable {
    let id = UUID()
    private(set) var profile: ConnectionProfile?
    private(set) var provider: (any StorageProvider)?
    private(set) var path = RemotePath.root
    private(set) var items: [RemoteItem] = [] {
        didSet { updateVisibleItems() }
    }
    /// `items` filtered by `filterText` and sorted, with containers first.
    private(set) var visibleItems: [RemoteItem] = []
    private(set) var isLoading = false
    var error: PresentableError?
    var selection = Set<RemotePath>() {
        didSet {
            if selection != oldValue {
                selectionChangedAt = .now
                cancelRenameOnClick()
            }
        }
    }
    var sortOrder = [KeyPathComparator(\RemoteItem.name, comparator: .localizedStandard)] {
        didSet {
            updateVisibleItems()
            childItems = childItems.mapValues(arranged)
            columnItems = columnItems.mapValues(arranged)
        }
    }
    var filterText = "" {
        didSet { updateVisibleItems() }
    }
    var pendingAction: BrowserAction?
    /// The item whose name is being edited in place.
    private(set) var renamingPath: RemotePath?
    /// Folders expanded in place in the list view.
    private(set) var expandedFolders = Set<RemotePath>()
    /// Sorted listings of expanded folders, keyed by folder.
    private(set) var childItems: [RemotePath: [RemoteItem]] = [:]
    /// Sorted listings of the folders above `path` shown in the column view, keyed by folder.
    private(set) var columnItems: [RemotePath: [RemoteItem]] = [:]

    @ObservationIgnored private var backStack: [RemotePath] = []
    @ObservationIgnored private var forwardStack: [RemotePath] = []
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var childTasks: [RemotePath: Task<Void, Never>] = [:]
    @ObservationIgnored private var columnTasks: [RemotePath: Task<Void, Never>] = [:]
    @ObservationIgnored private var selectionChangedAt = Date.distantPast
    @ObservationIgnored private var renameOnClickTask: Task<Void, Never>?
    /// The item whose name is under the pointer, for click-to-rename.
    @ObservationIgnored var hoveredNamePath: RemotePath?
    @ObservationIgnored private let pool: ConnectionPool
    @ObservationIgnored let transfers: TransferQueue
    @ObservationIgnored private var uploadObserver: (any NSObjectProtocol)?
    /// Uploads that finished recently, kept until a listing started after them includes them.
    @ObservationIgnored private var finishedUploads: [RemotePath: (item: RemoteItem, date: Date)] = [:]

    init(pool: ConnectionPool, transfers: TransferQueue) {
        self.pool = pool
        self.transfers = transfers
        uploadObserver = NotificationCenter.default.addObserver(forName: TransferQueue.uploadDidFinish, object: nil,
                                                                queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let job = notification.object as? TransferJob else { return }
                self?.uploadDidFinish(job)
            }
        }
    }

    var title: String {
        guard let profile else { return String(localized: "New Tab") }
        return path.isRoot ? profile.displayName : path.name
    }

    var capabilities: StorageCapabilities { provider?.capabilities ?? [] }
    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var canGoUp: Bool { path != topPath }

    /// The highest path the path bar and Enclosing Folder reach: the bucket inside a bucket, else the root.
    var topPath: RemotePath {
        guard capabilities.contains(.buckets), let bucket = path.components.first else { return .root }
        return RemotePath(components: [bucket])
    }

    /// Whether the current directory accepts files (the S3 root lists buckets only).
    var canWriteHere: Bool {
        provider != nil && !(capabilities.contains(.buckets) && path.isRoot)
    }

    private func updateVisibleItems() {
        let query = filterText.trimmingCharacters(in: .whitespaces)
        let filtered = query.isEmpty ? items : items.filter { $0.name.localizedStandardContains(query) }
        visibleItems = arranged(filtered)
    }

    /// The current directory as shown: `visibleItems` and the files still uploading into it.
    var displayedItems: [RemoteItem] {
        withUploads(visibleItems, in: path)
    }

    /// Sorted by `sortOrder`, with containers first.
    private func arranged(_ items: [RemoteItem]) -> [RemoteItem] {
        let sorted = items.sorted(using: sortOrder)
        return sorted.filter(\.isContainer) + sorted.filter { !$0.isContainer }
    }

    var selectedItems: [RemoteItem] {
        items(at: selection)
    }

    /// Loaded items at `paths`, including items inside expanded folders, the column view's columns,
    /// and files still uploading.
    func items(at paths: Set<RemotePath>) -> [RemoteItem] {
        guard !paths.isEmpty else { return [] }
        let nested = expandedFolders.flatMap { childItems[$0] ?? [] }
        let columns = columnItems.values.flatMap { $0 }
        let found = (items + nested + columns).filter { paths.contains($0.path) }
        let missing = paths.subtracting(found.map(\.path))
        guard !missing.isEmpty else { return found }
        let uploading = Set(missing.compactMap(\.parent)).flatMap { uploadPlaceholders(in: $0, excluding: []) }
        return found + uploading.filter { missing.contains($0.path) }
    }

    /// Dragging a selected item drags the whole selection.
    func dragProvider(for item: RemoteItem) -> NSItemProvider? {
        guard let connectionID = profile?.id else { return nil }
        let items = selection.contains(item.path) ? selectedItems : [item]
        return RemoteDragPayload(connectionID: connectionID, items: items).itemProvider()
    }

    // MARK: Expansion

    func setExpanded(_ expanded: Bool, _ folder: RemotePath) {
        if expanded {
            guard expandedFolders.insert(folder).inserted else { return }
            loadChildren(of: folder)
        } else {
            guard expandedFolders.remove(folder) != nil else { return }
            childTasks.removeValue(forKey: folder)?.cancel()
            selection = selection.filter { !$0.hasPrefix(folder) || $0 == folder }
        }
    }

    private func collapseAll() {
        childTasks.values.forEach { $0.cancel() }
        childTasks = [:]
        expandedFolders = []
        childItems = [:]
    }

    private func loadChildren(of folder: RemotePath) {
        guard let provider else { return }
        childTasks[folder]?.cancel()
        childTasks[folder] = Task {
            let start = Date.now
            var loaded: [RemoteItem] = []
            do {
                for try await page in provider.list(folder) {
                    guard !Task.isCancelled else { return }
                    loaded.append(contentsOf: page)
                    childItems[folder] = arranged(addingFinishedUploads(to: loaded, in: folder, listedSince: start))
                }
                childItems[folder] = arranged(addingFinishedUploads(to: loaded, in: folder, listedSince: start))
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                expandedFolders.remove(folder)
                self.error = PresentableError(error)
            }
            childTasks[folder] = nil
        }
    }

    // MARK: Columns

    /// The folders shown as columns, from `topPath` down to the current directory.
    var columnPaths: [RemotePath] {
        Array(path.ancestors.dropFirst(topPath.components.count))
    }

    /// The listing of one column: the current directory or a folder above it.
    func columnContents(of folder: RemotePath) -> [RemoteItem] {
        folder == path ? displayedItems : withUploads(columnItems[folder] ?? [], in: folder)
    }

    /// Loads the folders above the current directory that the column view has not listed yet.
    func loadColumns() {
        guard let provider else { return }
        for folder in columnPaths.dropLast() where columnItems[folder] == nil && columnTasks[folder] == nil {
            loadColumn(folder, provider: provider)
        }
    }

    private func loadColumn(_ folder: RemotePath, provider: any StorageProvider) {
        columnTasks[folder]?.cancel()
        columnTasks[folder] = Task {
            let start = Date.now
            var loaded: [RemoteItem] = []
            do {
                for try await page in provider.list(folder) {
                    guard !Task.isCancelled else { return }
                    loaded.append(contentsOf: page)
                }
                columnItems[folder] = arranged(addingFinishedUploads(to: loaded, in: folder, listedSince: start))
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                self.error = PresentableError(error)
            }
            columnTasks[folder] = nil
        }
    }

    /// Applies a selection made in the column of `folder`, as Finder does: a single folder opens as the
    /// next column, anything else becomes the selection inside `folder`.
    func selectInColumn(_ paths: Set<RemotePath>, of folder: RemotePath) {
        let selected = items(at: paths)
        if selected.count == 1, let item = selected.first, item.isContainer {
            navigate(to: item.path)
        } else if folder == path {
            selection = paths
        } else {
            navigate(to: folder, selecting: paths)
        }
    }

    // MARK: Navigation

    func open(_ profile: ConnectionProfile, at path: RemotePath? = nil) {
        do {
            provider = try pool.provider(for: profile)
            self.profile = profile
            finishedUploads = [:]
            backStack = []
            forwardStack = []
            collapseAll()
            columnTasks.values.forEach { $0.cancel() }
            columnTasks = [:]
            columnItems = [:]
            if let path {
                self.path = path
                load()
            } else if profile.initialPath.trimmingCharacters(in: .whitespaces).isEmpty {
                openHomeDirectory()
            } else {
                self.path = profile.initialRemotePath
                load()
            }
        } catch {
            self.profile = profile
            provider = nil
            items = []
            self.error = PresentableError(error)
        }
    }

    /// Opens the provider's home directory (the login directory for SFTP, the bucket list for S3).
    private func openHomeDirectory() {
        guard let provider else { return }
        path = .root
        items = []
        isLoading = true
        loadTask?.cancel()
        loadTask = Task {
            do {
                let home = try await provider.homePath()
                guard !Task.isCancelled else { return }
                path = home
                load()
            } catch is CancellationError {
            } catch {
                self.error = PresentableError(error)
                isLoading = false
            }
        }
    }

    /// Re-reads the profile after it was edited, keeping the current location.
    func profileDidChange(_ profile: ConnectionProfile) {
        guard profile.id == self.profile?.id else { return }
        open(profile, at: path)
    }

    func navigate(to newPath: RemotePath, selecting paths: Set<RemotePath> = []) {
        guard newPath != path else {
            selection = paths
            return
        }
        backStack.append(path)
        forwardStack = []
        move(to: newPath, selecting: paths)
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(path)
        move(to: previous)
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(path)
        move(to: next)
    }

    /// Changes the directory, keeping the listings of folders above it for the column view.
    private func move(to newPath: RemotePath, selecting paths: Set<RemotePath> = []) {
        if !isLoading, error == nil {
            columnItems[path] = arranged(items)
        }
        let cached = columnItems[newPath]
        for folder in columnItems.keys where !(newPath.hasPrefix(folder) && folder != newPath) {
            columnItems[folder] = nil
            columnTasks.removeValue(forKey: folder)?.cancel()
        }
        path = newPath
        selectionChangedAt = .now
        collapseAll()
        load(showing: cached ?? [], selecting: paths)
    }

    /// Goes to the parent folder with the folder just left selected.
    func goUp() {
        guard canGoUp, let parent = path.parent else { return }
        navigate(to: parent, selecting: [path])
    }

    /// Reloads the directory, every expanded folder, and the column view's columns.
    func refresh() {
        load(showing: items)
        for folder in expandedFolders {
            loadChildren(of: folder)
        }
        if let provider {
            for folder in columnItems.keys {
                loadColumn(folder, provider: provider)
            }
        }
    }

    /// Streams the listing so large directories appear page by page, replacing `cached` (an earlier
    /// listing shown meanwhile) with the first page. A dropped connection is re-established once
    /// before the error is shown.
    private func load(showing cached: [RemoteItem] = [], selecting paths: Set<RemotePath> = [],
                      allowReconnect: Bool = true) {
        loadTask?.cancel()
        guard let provider else { return }
        let path = path
        items = cached
        selection = paths
        renamingPath = nil
        isLoading = true
        error = nil
        loadTask = Task {
            let start = Date.now
            do {
                var loaded: [RemoteItem] = []
                for try await page in provider.list(path) {
                    guard !Task.isCancelled, self.path == path else { return }
                    loaded.append(contentsOf: page)
                    items = addingFinishedUploads(to: loaded, in: path, listedSince: start)
                }
                items = addingFinishedUploads(to: loaded, in: path, listedSince: start)
                isLoading = false
                if let profile {
                    await pool.reloadBucketsIfFailed(for: profile)
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                if allowReconnect, PresentableError.isConnectionFailure(error), let profile {
                    do {
                        self.provider = try await pool.reconnect(profile)
                        load(selecting: paths, allowReconnect: false)
                        return
                    } catch {
                        self.error = PresentableError(error)
                    }
                } else {
                    self.error = PresentableError(error)
                }
                isLoading = false
            }
        }
    }

    // MARK: Operations

    /// Runs a provider operation, shows its error, and refreshes the listing afterwards.
    /// `completion` runs after a successful operation, once the refresh has started.
    func perform(_ operation: @escaping (any StorageProvider) async throws -> Void,
                 completion: (() -> Void)? = nil) {
        guard let provider else { return }
        Task {
            var succeeded = false
            do {
                try await operation(provider)
                succeeded = true
            } catch is CancellationError {
            } catch {
                self.error = PresentableError(error)
            }
            refresh()
            if succeeded {
                completion?()
            }
        }
    }

    /// Creates "untitled folder" (numbered when taken) and edits its name in place, as Finder does.
    func createUntitledFolder() {
        guard canWriteHere else { return }
        let base = String(localized: "untitled folder")
        let taken = Set(items.map(\.name))
        let name = taken.contains(base)
            ? (2...).lazy.map { "\(base) \($0)" }.first { !taken.contains($0) } ?? base
            : base
        let target = path.appending(name)
        perform { try await $0.createDirectory(at: target) } completion: { [weak self] in
            self?.selection = [target]
            self?.renamingPath = target
        }
    }

    /// Deletes items and everything inside folders. Items inside another selected folder go with it.
    func delete(_ items: [RemoteItem]) {
        let paths = Set(items.map(\.path))
        let topLevel = items.filter { item in
            !paths.contains { $0 != item.path && item.path.hasPrefix($0) }
        }
        for folder in expandedFolders where paths.contains(where: { folder.hasPrefix($0) }) {
            setExpanded(false, folder)
        }
        // Deleting a folder the column view has open leaves it for the folder above.
        if let open = topLevel.first(where: { path.hasPrefix($0.path) }), let parent = open.path.parent {
            navigate(to: parent)
        }
        perform { provider in
            for item in topLevel {
                try await provider.delete(item)
            }
        }
    }

    // MARK: Uploads

    /// Unfinished uploads into `path` or anywhere below it.
    func uploads(at path: RemotePath) -> [TransferJob] {
        guard let id = profile?.id else { return [] }
        return transfers.uploads(at: path, connection: id)
    }

    /// A sorted listing of `folder` with placeholders for the files still uploading into it.
    func withUploads(_ listed: [RemoteItem], in folder: RemotePath) -> [RemoteItem] {
        let placeholders = uploadPlaceholders(in: folder, excluding: listed)
        return placeholders.isEmpty ? listed : arranged(listed + placeholders)
    }

    private func uploadPlaceholders(in folder: RemotePath, excluding listed: [RemoteItem]) -> [RemoteItem] {
        let query = folder == path ? filterText.trimmingCharacters(in: .whitespaces) : ""
        var taken = Set(listed.map(\.path))
        return uploads(at: folder).compactMap { job in
            guard let destination = job.destinationPath, destination.parent == folder,
                  query.isEmpty || destination.name.localizedStandardContains(query),
                  taken.insert(destination).inserted else { return nil }
            return RemoteItem(path: destination, kind: .file)
        }
    }

    /// Shows a finished upload at once, without reloading the folder it went into.
    private func uploadDidFinish(_ job: TransferJob) {
        guard job.destinationConnection == profile?.id, let destination = job.destinationPath,
              let folder = destination.parent else { return }
        let uploaded = RemoteItem(path: destination, kind: .file, size: job.record.totalBytes, modificationDate: .now)
        finishedUploads[destination] = (uploaded, .now)
        func adding(to listed: [RemoteItem]) -> [RemoteItem] {
            var listed = listed
            if let index = listed.firstIndex(where: { $0.path == destination }) {
                listed[index].size = uploaded.size
                listed[index].modificationDate = uploaded.modificationDate
            } else {
                listed.append(uploaded)
            }
            return listed
        }
        if folder == path {
            items = adding(to: items)
        }
        if let children = childItems[folder] {
            childItems[folder] = arranged(adding(to: children))
        }
        if let column = columnItems[folder] {
            columnItems[folder] = arranged(adding(to: column))
        }
    }

    /// A listing started at `start` may predate uploads into `folder` that finished since; those are
    /// added. Uploads that finished before `start` are in the listing and are forgotten.
    private func addingFinishedUploads(to loaded: [RemoteItem], in folder: RemotePath,
                                       listedSince start: Date) -> [RemoteItem] {
        finishedUploads = finishedUploads.filter { $0.key.parent != folder || $0.value.date >= start }
        let listed = Set(loaded.map(\.path))
        let missing = finishedUploads.values.map(\.item).filter { $0.path.parent == folder && !listed.contains($0.path) }
        return loaded + missing
    }

    // MARK: Renaming

    /// Turns the item's name into an editable field. Buckets cannot be renamed.
    func beginRenaming(_ item: RemoteItem) {
        guard item.kind != .bucket, provider != nil else { return }
        // The current directory is renamed where the column view highlights it, without selecting it.
        if item.path != path {
            selection = [item.path]
        }
        renamingPath = item.path
    }

    func cancelRenaming() {
        renamingPath = nil
    }

    /// Ends in-place editing. An empty or unchanged name keeps the old one.
    func commitRenaming(_ item: RemoteItem, to newName: String) {
        guard renamingPath == item.path else { return }
        renamingPath = nil
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != item.name, let parent = item.path.parent else { return }
        guard !name.contains("/") else {
            error = PresentableError(title: String(localized: "Can’t Rename “\(item.name)”"),
                                     message: String(localized: "Names can’t contain “/”."))
            return
        }
        let siblings = parent == path ? items : childItems[parent] ?? columnItems[parent] ?? []
        guard !siblings.contains(where: { $0.name == name }) else {
            error = PresentableError(
                title: String(localized: "Can’t Rename “\(item.name)”"),
                message: String(localized: "The name “\(name)” is already taken. Please choose a different name.")
            )
            return
        }
        let destination = parent.appending(name)
        perform { try await $0.move(item, to: destination) } completion: { [weak self] in
            guard let self else { return }
            // Renaming a folder the column view has open keeps it open under its new name.
            if let below = path.relativeComponents(to: item.path) {
                navigate(to: destination.appending(components: below))
            } else {
                selection = [destination]
            }
        }
    }

    /// Clicking the name of the only selected item renames it once the double-click interval passes,
    /// as in Finder. Another click, a selection change, or any command cancels it.
    func nameClicked(_ item: RemotePath, clickCount: Int) {
        cancelRenameOnClick()
        guard clickCount == 1, isOnlySelected(item), renamingPath == nil,
              Date.now.timeIntervalSince(selectionChangedAt) > NSEvent.doubleClickInterval,
              let target = items(at: [item]).first else { return }
        renameOnClickTask = Task {
            try? await Task.sleep(for: .seconds(NSEvent.doubleClickInterval))
            guard !Task.isCancelled, isOnlySelected(item) else { return }
            beginRenaming(target)
        }
    }

    /// The column view shows the current directory selected in its parent's column.
    private func isOnlySelected(_ item: RemotePath) -> Bool {
        selection == [item] || (selection.isEmpty && item == path)
    }

    func cancelRenameOnClick() {
        renameOnClickTask?.cancel()
        renameOnClickTask = nil
    }

    func setPermissions(_ permissions: UInt16, for items: [RemoteItem]) {
        perform { provider in
            for item in items {
                try await provider.setPermissions(permissions, at: item.path)
            }
        }
    }
}

extension RemoteItem {
    var sortSize: Int64 { size ?? -1 }
    var sortDate: Date { modificationDate ?? .distantPast }

    var contentType: UTType? {
        switch kind {
        case .directory, .bucket: .folder
        case .symbolicLink: .symbolicLink
        case .file: UTType(filenameExtension: path.name.pathExtension) ?? .data
        }
    }

    var typeDescription: String {
        switch kind {
        case .bucket: String(localized: "Bucket")
        case .directory: String(localized: "Folder")
        case .symbolicLink: String(localized: "Alias")
        case .file:
            FileKindDescriptions.description(forExtension: path.name.pathExtension)
                ?? contentType?.localizedDescription
                ?? String(localized: "Document")
        }
    }

    var permissionsDescription: String {
        guard let permissions else { return "" }
        let prefix = kind == .directory ? "d" : kind == .symbolicLink ? "l" : "-"
        let symbols = (0..<9).map { bit -> Character in
            let mask = UInt16(1) << UInt16(8 - bit)
            guard permissions & mask != 0 else { return "-" }
            return ["r", "w", "x"][bit % 3]
        }
        return prefix + String(symbols)
    }

    var ownerDescription: String {
        [owner, group].compactMap { $0 }.joined(separator: ":")
    }

    var isImage: Bool {
        contentType?.conforms(to: .image) == true
    }
}

extension String {
    var pathExtension: String {
        (self as NSString).pathExtension
    }
}
