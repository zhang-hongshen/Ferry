import AppKit
import CryptoKit
import Foundation
import Observation
import StorageCore

/// Opens remote files in their default app and uploads every save back, so a remote file is edited
/// like a local one.
@Observable
final class RemoteFileEditor {
    /// Watches of open local copies, keyed by remote location.
    @ObservationIgnored private var watches: [String: Task<Void, Never>] = [:]

    /// Downloads the file, opens it, and uploads the local copy whenever it changes. A file that is
    /// already open is reopened as it is, keeping unsaved uploads.
    func open(_ item: RemoteItem, connectionID: UUID, provider: any StorageProvider,
              transfers: TransferQueue) async throws {
        let key = "\(connectionID.uuidString)\(item.path.string)"
        let url = Self.localURL(for: item, connectionID: connectionID)
        if watches[key] == nil || !FileManager.default.fileExists(atPath: url.path) {
            watches.removeValue(forKey: key)?.cancel()
            try? FileManager.default.removeItem(at: url)
            try await provider.download(item.path, to: url, options: TransferOptions(), reporter: TransferReporter())
            watches[key] = watch(url, uploadingTo: item.path, connectionID: connectionID, transfers: transfers)
        }
        guard NSWorkspace.shared.open(url) else {
            throw StorageError.localFile(String(localized: "No app can open “\(item.name)”."))
        }
    }

    /// Polls the modification date, which also catches apps that save by replacing the file.
    private func watch(_ url: URL, uploadingTo path: RemotePath, connectionID: UUID,
                       transfers: TransferQueue) -> Task<Void, Never> {
        Task {
            var uploadedDate = Self.modificationDate(of: url)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let date = Self.modificationDate(of: url), date != uploadedDate else { continue }
                uploadedDate = date
                var record = TransferRecord(kind: .upload, name: url.lastPathComponent)
                record.destinationConnection = connectionID
                record.destinationPath = path
                record.localFile = LocalFileReference(root: url, bookmark: nil)
                record.totalBytes = try? LocalFile.size(of: url)
                transfers.enqueue([record])
            }
        }
    }

    private static func modificationDate(of url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private static func localURL(for item: RemoteItem, connectionID: UUID) -> URL {
        let digest = SHA256.hash(data: Data(item.path.string.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return AppDirectories.caches
            .appending(path: "Editing/\(connectionID.uuidString)/\(digest)", directoryHint: .isDirectory)
            .appending(path: item.name)
    }
}
