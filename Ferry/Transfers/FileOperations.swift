import CryptoKit
import Foundation
import StorageCore

/// Turns user actions (upload, download, paste) into directory creation and transfer jobs,
/// resolving name conflicts first.
struct FileOperations {
    let tab: BrowserTab
    let transfers: TransferQueue
    let conflicts: ConflictResolver
    let pool: ConnectionPool
    let store: ConnectionStore

    // MARK: Upload

    /// Uploads files and folders into the current directory. Folders keep their structure.
    func upload(_ urls: [URL]) async {
        guard let profile = tab.profile, let provider = tab.provider, tab.canWriteHere, !urls.isEmpty else { return }
        let directory = tab.path
        let resolved = await conflicts.resolve(urls.map(\.lastPathComponent), existing: Set(tab.items.map(\.name)))
        do {
            var records: [TransferRecord] = []
            var directories: [RemotePath] = []
            for url in urls {
                guard let entry = resolved[url.lastPathComponent], let target = entry else { continue }
                let bookmark = LocalFileReference.bookmark(for: url)
                let destination = directory.appending(components: [target])
                guard Self.isDirectory(url) else {
                    records.append(uploadRecord(url, root: url, bookmark: bookmark, relativePath: "",
                                                to: destination, connection: profile.id))
                    continue
                }
                directories.append(destination)
                for (fileURL, relativePath, isDirectory) in try Self.enumerate(url) {
                    let remotePath = destination.appending(relativePath)
                    if isDirectory {
                        directories.append(remotePath)
                    } else {
                        records.append(uploadRecord(fileURL, root: url, bookmark: bookmark, relativePath: relativePath,
                                                    to: remotePath, connection: profile.id))
                    }
                }
            }
            try await createRemoteDirectories(directories, with: provider)
            transfers.enqueue(records)
        } catch {
            tab.error = PresentableError(error)
        }
        tab.refresh()
    }

    private func uploadRecord(_ fileURL: URL, root: URL, bookmark: Data?, relativePath: String, to path: RemotePath,
                              connection: UUID) -> TransferRecord {
        var record = TransferRecord(kind: .upload, name: fileURL.lastPathComponent)
        record.destinationConnection = connection
        record.destinationPath = path
        record.localFile = LocalFileReference(root: root, bookmark: bookmark, relativePath: relativePath)
        record.totalBytes = try? LocalFile.size(of: fileURL)
        return record
    }

    private func createRemoteDirectories(_ paths: [RemotePath], with provider: any StorageProvider) async throws {
        for path in paths {
            do {
                try await provider.createDirectory(at: path)
            } catch StorageError.alreadyExists {
                continue
            }
        }
    }

    // MARK: Download

    /// Downloads items into a local folder; directories are downloaded recursively.
    func download(_ items: [RemoteItem], to folder: URL) async {
        guard let profile = tab.profile, let provider = tab.provider, !items.isEmpty else { return }
        let didAccess = folder.startAccessingSecurityScopedResource()
        defer {
            if didAccess { folder.stopAccessingSecurityScopedResource() }
        }
        let existing = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
        let resolved = await conflicts.resolve(items.map(\.name), existing: existing)
        let bookmark = LocalFileReference.bookmark(for: folder)
        do {
            var records: [TransferRecord] = []
            for item in items {
                guard let entry = resolved[item.name], let target = entry else { continue }
                guard item.isContainer else {
                    records.append(downloadRecord(item, to: folder, bookmark: bookmark, relativePath: target,
                                                  connection: profile.id))
                    continue
                }
                let localRoot = folder.appending(path: target, directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: localRoot, withIntermediateDirectories: true)
                for try await page in provider.listRecursively(item.path) {
                    for child in page {
                        guard let components = child.path.relativeComponents(to: item.path), !components.isEmpty else {
                            continue
                        }
                        let relativePath = ([target] + components).joined(separator: "/")
                        if child.isContainer {
                            try FileManager.default.createDirectory(at: folder.appending(path: relativePath),
                                                                    withIntermediateDirectories: true)
                        } else {
                            try FileManager.default.createDirectory(
                                at: folder.appending(path: relativePath).deletingLastPathComponent(),
                                withIntermediateDirectories: true
                            )
                            records.append(downloadRecord(child, to: folder, bookmark: bookmark,
                                                          relativePath: relativePath, connection: profile.id))
                        }
                    }
                }
            }
            transfers.enqueue(records)
        } catch {
            tab.error = PresentableError(error)
        }
    }

    private func downloadRecord(_ item: RemoteItem, to folder: URL, bookmark: Data?, relativePath: String,
                                connection: UUID) -> TransferRecord {
        var record = TransferRecord(kind: .download, name: item.name)
        record.sourceConnection = connection
        record.sourcePath = item.path
        record.localFile = LocalFileReference(root: folder, bookmark: bookmark, relativePath: relativePath)
        record.totalBytes = item.size
        return record
    }

    // MARK: Paste

    /// Pastes copied or cut items into the current directory. Within one connection this uses
    /// server-side copy or move; across connections it queues copies through a local temporary file.
    func paste(_ contents: RemoteClipboard.Contents, clipboard: RemoteClipboard) async {
        guard let profile = tab.profile, let provider = tab.provider, tab.canWriteHere else { return }
        let directory = tab.path
        let items = contents.items.filter { !directory.hasPrefix($0.path) }
        let resolved = await conflicts.resolve(items.map(\.name), existing: Set(tab.items.map(\.name)))

        if contents.connectionID == profile.id {
            let isCut = contents.isCut
            tab.perform { provider in
                for item in items {
                    guard let entry = resolved[item.name], let target = entry else { continue }
                    let destination = directory.appending(components: [target])
                    guard destination != item.path else { continue }
                    if isCut {
                        try await provider.move(item, to: destination)
                    } else {
                        try await provider.copy(item, to: destination)
                    }
                }
            }
            if isCut {
                clipboard.clear()
            }
            return
        }

        guard let sourceProfile = store.profile(id: contents.connectionID) else { return }
        do {
            let sourceProvider = try pool.provider(for: sourceProfile)
            var records: [TransferRecord] = []
            var directories: [RemotePath] = []
            for item in items {
                guard let entry = resolved[item.name], let target = entry else { continue }
                let destination = directory.appending(components: [target])
                guard item.isContainer else {
                    records.append(copyRecord(item, from: sourceProfile.id, to: destination, connection: profile.id))
                    continue
                }
                directories.append(destination)
                for try await page in sourceProvider.listRecursively(item.path) {
                    for child in page {
                        guard let components = child.path.relativeComponents(to: item.path), !components.isEmpty else {
                            continue
                        }
                        let childDestination = destination.appending(components: components)
                        if child.isContainer {
                            directories.append(childDestination)
                        } else {
                            records.append(copyRecord(child, from: sourceProfile.id, to: childDestination,
                                                      connection: profile.id))
                        }
                    }
                }
            }
            try await createRemoteDirectories(directories, with: provider)
            transfers.enqueue(records)
        } catch {
            tab.error = PresentableError(error)
        }
        tab.refresh()
    }

    private func copyRecord(_ item: RemoteItem, from source: UUID, to destination: RemotePath,
                            connection: UUID) -> TransferRecord {
        var record = TransferRecord(kind: .remoteCopy, name: item.name)
        record.sourceConnection = source
        record.sourcePath = item.path
        record.destinationConnection = connection
        record.destinationPath = destination
        record.totalBytes = item.size
        return record
    }

    // MARK: Local copies

    /// Downloads a file into the preview cache, reusing an earlier copy of the same size.
    static func previewCopy(of item: RemoteItem, connectionID: UUID,
                            provider: any StorageProvider) async throws -> URL {
        let digest = SHA256.hash(data: Data(item.path.string.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        let url = AppDirectories.caches
            .appending(path: "Previews/\(connectionID.uuidString)/\(digest)", directoryHint: .isDirectory)
            .appending(path: item.name)
        if let size = try? LocalFile.size(of: url), size == item.size {
            return url
        }
        try await provider.download(item.path, to: url, options: TransferOptions(), reporter: TransferReporter())
        return url
    }

    // MARK: Local files

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    /// Every item below a local folder with its slash-separated relative path.
    private static func enumerate(_ folder: URL) throws -> [(URL, String, Bool)] {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey])
        else {
            throw StorageError.localFile(String(localized: "Cannot read \(folder.lastPathComponent)."))
        }
        let rootComponents = folder.standardizedFileURL.pathComponents
        var entries: [(URL, String, Bool)] = []
        for case let url as URL in enumerator where url.lastPathComponent != ".DS_Store" {
            let relative = url.standardizedFileURL.pathComponents.dropFirst(rootComponents.count).joined(separator: "/")
            entries.append((url, relative, isDirectory(url)))
        }
        return entries
    }
}
