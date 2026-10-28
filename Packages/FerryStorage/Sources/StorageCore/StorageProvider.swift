import Foundation

/// The unified interface every protocol module implements. The UI talks only to this protocol.
///
/// Paths are absolute `RemotePath`s. Directory-like containers (directories, S3 prefixes, buckets)
/// are listed with `list(_:)`. Optional operations have default implementations that throw
/// `StorageError.unsupported`; check `capabilities` before offering them.
public protocol StorageProvider: AnyObject, Sendable {
    var capabilities: StorageCapabilities { get }

    /// Establishes a session, or validates credentials for stateless protocols.
    func connect() async throws
    func disconnect() async
    /// Where a connection without an initial path opens, such as the user's home directory.
    func homePath() async throws -> RemotePath

    /// Lists a container, yielding pages as they arrive so large directories render progressively.
    func list(_ path: RemotePath) -> AsyncThrowingStream<[RemoteItem], any Error>
    /// Lists every item below a container, files and directories, depth-first or flat.
    func listRecursively(_ path: RemotePath) -> AsyncThrowingStream<[RemoteItem], any Error>
    func item(at path: RemotePath) async throws -> RemoteItem

    /// Uploads a local file to `path`, replacing any existing file.
    func upload(from localURL: URL, to path: RemotePath, options: TransferOptions, reporter: TransferReporter) async throws
    /// Downloads `path` into `localURL`. With `options.resume`, appends to an existing partial file.
    func download(_ path: RemotePath, to localURL: URL, options: TransferOptions, reporter: TransferReporter) async throws
    /// Releases server-side state of an abandoned upload (for example S3 multipart parts).
    func discardPartialUpload(to path: RemotePath, resumeToken: String) async

    /// Deletes a file, or a directory and everything inside it.
    func delete(_ item: RemoteItem) async throws
    func move(_ item: RemoteItem, to destination: RemotePath) async throws
    func copy(_ item: RemoteItem, to destination: RemotePath) async throws
    func createDirectory(at path: RemotePath) async throws

    func setPermissions(_ permissions: UInt16, at path: RemotePath) async throws
    func presignedURL(for path: RemotePath, expiresIn: Duration) async throws -> URL
    func metadata(for path: RemotePath) async throws -> RemoteMetadata
    func updateMetadata(_ metadata: RemoteMetadata, for path: RemotePath) async throws
    func createBucket(named name: String) async throws
    /// Deletes a bucket. Without `force`, fails with `directoryNotEmpty` when it has objects.
    func deleteBucket(named name: String, force: Bool) async throws

    /// A protocol URL that identifies the item, without credentials.
    func url(for path: RemotePath) -> URL?
}

extension StorageProvider {
    public func disconnect() async {}

    public func homePath() async throws -> RemotePath { .root }

    public func listRecursively(_ path: RemotePath) -> AsyncThrowingStream<[RemoteItem], any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var pending = [path]
                    while let directory = pending.popLast() {
                        for try await page in list(directory) {
                            try Task.checkCancellation()
                            continuation.yield(page)
                            pending.append(contentsOf: page.filter(\.isContainer).map(\.path))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func discardPartialUpload(to path: RemotePath, resumeToken: String) async {}

    public func setPermissions(_ permissions: UInt16, at path: RemotePath) async throws {
        throw StorageError.unsupported("Changing permissions is not supported.")
    }

    public func presignedURL(for path: RemotePath, expiresIn: Duration) async throws -> URL {
        throw StorageError.unsupported("Presigned links are not supported.")
    }

    public func metadata(for path: RemotePath) async throws -> RemoteMetadata {
        throw StorageError.unsupported("Object metadata is not supported.")
    }

    public func updateMetadata(_ metadata: RemoteMetadata, for path: RemotePath) async throws {
        throw StorageError.unsupported("Object metadata is not supported.")
    }

    public func createBucket(named name: String) async throws {
        throw StorageError.unsupported("Buckets are not supported.")
    }

    public func deleteBucket(named name: String, force: Bool) async throws {
        throw StorageError.unsupported("Buckets are not supported.")
    }

    public func url(for path: RemotePath) -> URL? { nil }

    /// Collects all pages of a listing.
    public func listAll(_ path: RemotePath) async throws -> [RemoteItem] {
        var items: [RemoteItem] = []
        for try await page in list(path) {
            items.append(contentsOf: page)
        }
        return items
    }

    /// Whether an item exists at `path`.
    public func exists(_ path: RemotePath) async throws -> Bool {
        do {
            _ = try await item(at: path)
            return true
        } catch StorageError.notFound {
            return false
        }
    }
}
