import Foundation
import Observation
import StorageCore

enum TransferKind: String, Codable {
    case upload
    case download
    /// Between two connections, through a local temporary copy.
    case remoteCopy
}

enum TransferStatus: Codable, Hashable {
    case queued
    case running
    /// Saved by earlier versions; restored as queued.
    case paused
    case completed
    case failed(String)
    case cancelled

    var isUnfinished: Bool {
        switch self {
        case .queued, .running, .paused, .failed: true
        case .completed, .cancelled: false
        }
    }
}

/// A local file or folder chosen by the user, kept accessible across launches with a
/// security-scoped bookmark of the chosen root.
struct LocalFileReference: Codable, Hashable {
    var rootPath: String
    var rootBookmark: Data?
    /// Path below the root; empty when the root itself is the file.
    var relativePath: String

    init(root: URL, bookmark: Data?, relativePath: String = "") {
        rootPath = root.path
        rootBookmark = bookmark
        self.relativePath = relativePath
    }

    static func bookmark(for url: URL) -> Data? {
        try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// Resolves the root and starts security-scoped access. Call `stop()` when done.
    func access() -> LocalAccess {
        var root = URL(filePath: rootPath)
        if let rootBookmark {
            var isStale = false
            if let resolved = try? URL(resolvingBookmarkData: rootBookmark, options: .withSecurityScope,
                                       bookmarkDataIsStale: &isStale) {
                root = resolved
            }
        }
        let didStart = root.startAccessingSecurityScopedResource()
        let url = relativePath.isEmpty ? root : root.appending(path: relativePath)
        return LocalAccess(url: url, scopedRoot: didStart ? root : nil)
    }
}

struct LocalAccess {
    let url: URL
    let scopedRoot: URL?

    func stop() {
        scopedRoot?.stopAccessingSecurityScopedResource()
    }
}

/// The persisted description of a transfer.
struct TransferRecord: Codable, Identifiable, Hashable {
    var id = UUID()
    var kind: TransferKind
    var name: String
    var sourceConnection: UUID?
    var sourcePath: RemotePath?
    var destinationConnection: UUID?
    var destinationPath: RemotePath?
    var localFile: LocalFileReference?
    var completedBytes: Int64 = 0
    var totalBytes: Int64?
    var status = TransferStatus.queued
    var resumeToken: String?
    /// For remote copies: the download phase is finished and the upload phase runs.
    var isUploadPhase = false
    var attempts = 0
    var createdAt = Date()
}

@Observable
final class TransferJob: Identifiable {
    var record: TransferRecord
    /// Copied from the record so finding a job's destination doesn't observe its progress.
    let destinationConnection: UUID?
    let destinationPath: RemotePath?

    init(record: TransferRecord) {
        self.record = record
        destinationConnection = record.destinationConnection
        destinationPath = record.destinationPath
    }

    var id: UUID { record.id }

    var failureMessage: String? {
        if case .failed(let message) = record.status { return message }
        return nil
    }

    func apply(_ snapshot: TransferReporter.Snapshot) {
        record.completedBytes = snapshot.completedBytes
        record.totalBytes = snapshot.totalBytes ?? record.totalBytes
    }
}
