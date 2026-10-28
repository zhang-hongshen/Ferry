import Foundation
import NIOCore
import NIOSSH
import StorageCore

/// SFTP (SSH File Transfer Protocol v3) over swift-nio-ssh.
///
/// One SSH connection is shared by all operations of a provider and re-established automatically
/// when it drops. Reads and writes are pipelined with several requests in flight.
public final class SFTPProvider: StorageProvider {
    public let capabilities: StorageCapabilities = [
        .permissions, .posixAttributes, .resumableUpload, .resumableDownload, .atomicMove,
    ]

    let chunkSize: UInt32 = 32 * 1024
    let maximumRequestsInFlight = 32

    private let configuration: SFTPConfiguration
    private let sessions: SFTPSessionManager

    public init(configuration: SFTPConfiguration) throws {
        guard !configuration.host.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw StorageError.invalidConfiguration("A host is required.")
        }
        guard !configuration.username.isEmpty else {
            throw StorageError.invalidConfiguration("A username is required.")
        }
        self.configuration = configuration
        sessions = SFTPSessionManager(configuration: configuration)
    }

    // MARK: Session

    public func connect() async throws {
        _ = try await sessions.current()
    }

    public func disconnect() async {
        await sessions.close()
    }

    public func homePath() async throws -> RemotePath {
        RemotePath(try await sessions.current().realPath("."))
    }

    public func url(for path: RemotePath) -> URL? {
        var components = URLComponents()
        components.scheme = "sftp"
        components.user = configuration.username
        components.host = configuration.host
        components.port = configuration.port == 22 ? nil : configuration.port
        components.path = path.string
        return components.url
    }

    // MARK: Listing

    public func list(_ path: RemotePath) -> AsyncThrowingStream<[RemoteItem], any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let session = try await sessions.current()
                    let handle = try await session.openDirectory(path.string)
                    do {
                        while let names = try await session.readDirectory(handle, path: path.string) {
                            try Task.checkCancellation()
                            var items: [RemoteItem] = []
                            for name in names where name.filename != "." && name.filename != ".." {
                                items.append(await item(for: name, in: path, session: session))
                            }
                            continuation.yield(items)
                        }
                        await session.close(handle)
                    } catch {
                        await session.close(handle)
                        throw error
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: SFTPSession.map(error, path: path.string))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func item(at path: RemotePath) async throws -> RemoteItem {
        let session = try await sessions.current()
        let attributes = try await session.attributes(path.string, followLinks: false)
        var item = Self.item(path: path, attributes: attributes, owner: nil)
        if attributes.isSymbolicLink, let target = try? await session.attributes(path.string), target.isDirectory {
            item.kind = .directory
        }
        return item
    }

    /// Symbolic links to directories are listed as directories so they can be opened.
    private func item(for name: SFTPName, in directory: RemotePath, session: SFTPSession) async -> RemoteItem {
        let path = directory.appending(components: [name.filename])
        var item = Self.item(path: path, attributes: name.attributes, owner: name.ownerAndGroup)
        if name.attributes.isSymbolicLink, let target = try? await session.attributes(path.string), target.isDirectory {
            item.kind = .directory
        }
        return item
    }

    static func item(path: RemotePath, attributes: SFTPAttributes, owner: (String, String)?) -> RemoteItem {
        let kind: RemoteItem.Kind = attributes.isDirectory ? .directory
            : attributes.isSymbolicLink ? .symbolicLink : .file
        return RemoteItem(
            path: path,
            kind: kind,
            size: kind == .file ? attributes.size.map(Int64.init) : nil,
            modificationDate: attributes.modificationTime.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            permissions: attributes.permissions.map { UInt16($0 & 0o7777) },
            owner: owner?.0 ?? attributes.uid.map(String.init),
            group: owner?.1 ?? attributes.gid.map(String.init)
        )
    }

    private func names(in path: String, session: SFTPSession) async throws -> [SFTPName] {
        let handle = try await session.openDirectory(path)
        var result: [SFTPName] = []
        do {
            while let names = try await session.readDirectory(handle, path: path) {
                result += names.filter { $0.filename != "." && $0.filename != ".." }
            }
        } catch {
            await session.close(handle)
            throw error
        }
        await session.close(handle)
        return result
    }

    // MARK: Changes

    public func createDirectory(at path: RemotePath) async throws {
        let session = try await sessions.current()
        do {
            try await session.makeDirectory(path.string)
        } catch let error as StorageError {
            // Servers report an existing directory as a generic failure.
            if case .server = error, let existing = try? await session.attributes(path.string), existing.isDirectory {
                throw StorageError.alreadyExists(path)
            }
            throw error
        }
    }

    public func delete(_ item: RemoteItem) async throws {
        let session = try await sessions.current()
        let attributes = try await session.attributes(item.path.string, followLinks: false)
        if attributes.isDirectory {
            try await deleteDirectory(item.path.string, session: session)
        } else {
            try await session.removeFile(item.path.string)
        }
    }

    private func deleteDirectory(_ path: String, session: SFTPSession) async throws {
        for name in try await names(in: path, session: session) {
            try Task.checkCancellation()
            let child = path == "/" ? "/\(name.filename)" : "\(path)/\(name.filename)"
            if name.attributes.isDirectory {
                try await deleteDirectory(child, session: session)
            } else {
                try await session.removeFile(child)
            }
        }
        try await session.removeDirectory(path)
    }

    public func move(_ item: RemoteItem, to destination: RemotePath) async throws {
        try await sessions.current().rename(item.path.string, to: destination.string)
    }

    /// SFTP v3 has no server-side copy, so data streams through the client within one session.
    public func copy(_ item: RemoteItem, to destination: RemotePath) async throws {
        let session = try await sessions.current()
        try await copy(item.path.string, to: destination.string, session: session)
    }

    private func copy(_ source: String, to destination: String, session: SFTPSession) async throws {
        let attributes = try await session.attributes(source)
        guard attributes.isDirectory else {
            try await copyFile(source, to: destination, attributes: attributes, session: session)
            return
        }
        do {
            try await session.makeDirectory(destination)
        } catch {
            guard let existing = try? await session.attributes(destination), existing.isDirectory else { throw error }
        }
        for name in try await names(in: source, session: session) {
            try Task.checkCancellation()
            try await copy("\(source)/\(name.filename)", to: "\(destination)/\(name.filename)", session: session)
        }
    }

    private func copyFile(_ source: String, to destination: String, attributes: SFTPAttributes,
                          session: SFTPSession) async throws {
        let input = try await session.open(source, flags: .read)
        var permissions = SFTPAttributes()
        permissions.permissions = attributes.permissions.map { $0 & 0o7777 }
        let output: ByteBuffer
        do {
            output = try await session.open(destination, flags: [.write, .create, .truncate], attributes: permissions)
        } catch {
            await session.close(input)
            throw error
        }
        do {
            var offset: UInt64 = 0
            var writes: [EventLoopFuture<Void>] = []
            while let data = try await session.read(input, offset: offset, length: chunkSize).get(),
                  data.readableBytes > 0 {
                try Task.checkCancellation()
                writes.append(session.write(output, offset: offset, data: data))
                offset += UInt64(data.readableBytes)
                if writes.count >= maximumRequestsInFlight {
                    try await writes.removeFirst().get()
                }
            }
            for write in writes {
                try await write.get()
            }
        } catch {
            await session.close(input)
            await session.close(output)
            throw SFTPSession.map(error, path: destination)
        }
        await session.close(input)
        await session.close(output)
    }

    public func setPermissions(_ permissions: UInt16, at path: RemotePath) async throws {
        var attributes = SFTPAttributes()
        attributes.permissions = UInt32(permissions & 0o7777)
        try await sessions.current().setAttributes(attributes, at: path.string)
    }

    // MARK: Transfers

    /// Resuming continues from the remote file's size, minus one pipeline window: pipelined writes
    /// may land out of order, so bytes before that point are the only ones known to be contiguous.
    public func upload(from localURL: URL, to path: RemotePath, options: TransferOptions,
                       reporter: TransferReporter) async throws {
        let session = try await sessions.current()
        let size = try LocalFile.size(of: localURL)
        reporter.setTotal(size)

        var offset: Int64 = 0
        var flags: SFTPOpenFlags = [.write, .create, .truncate]
        if options.resume, let remote = try? await session.attributes(path.string), let remoteSize = remote.size,
           Int64(remoteSize) <= size {
            let window = Int64(chunkSize) * Int64(maximumRequestsInFlight)
            offset = max(0, Int64(remoteSize) - window)
            flags = [.write, .create]
        }
        reporter.setCompleted(offset)

        let handle = try await session.open(path.string, flags: flags)
        do {
            let file = try FileHandle(forReadingFrom: localURL)
            defer { try? file.close() }
            try file.seek(toOffset: UInt64(offset))
            var inFlight: [(length: Int, future: EventLoopFuture<Void>)] = []
            while offset < size || !inFlight.isEmpty {
                while inFlight.count < maximumRequestsInFlight, offset < size {
                    let length = Int(min(Int64(chunkSize), size - offset))
                    try await reporter.throttle(length)
                    guard let data = try file.read(upToCount: length), !data.isEmpty else {
                        throw StorageError.localFile("\(localURL.lastPathComponent) changed during the upload.")
                    }
                    inFlight.append((data.count, session.write(handle, offset: UInt64(offset),
                                                               data: ByteBuffer(bytes: data))))
                    offset += Int64(data.count)
                }
                let first = inFlight.removeFirst()
                try await first.future.get()
                reporter.record(Int64(first.length))
            }
        } catch {
            await session.close(handle)
            throw SFTPSession.map(error, path: path.string)
        }
        await session.close(handle)
    }

    /// The resume token is the remote size and modification time; a changed file restarts.
    public func download(_ path: RemotePath, to localURL: URL, options: TransferOptions,
                         reporter: TransferReporter) async throws {
        let session = try await sessions.current()
        let attributes = try await session.attributes(path.string)
        guard !attributes.isDirectory else {
            throw StorageError.unsupported("\(path.name) is a folder.")
        }
        let size = Int64(attributes.size ?? 0)
        let token = "\(size):\(attributes.modificationTime ?? 0)"
        reporter.setTotal(size)

        var (file, offset) = try LocalFile.openForAppending(localURL, resume: options.resume && options.resumeToken == token)
        if offset > size {
            try? file.close()
            (file, offset) = try LocalFile.openForAppending(localURL, resume: false)
        }
        defer { try? file.close() }
        reporter.updateResumeToken(token)
        reporter.setCompleted(offset)

        let handle = try await session.open(path.string, flags: .read)
        do {
            var nextOffset = offset
            var inFlight: [(offset: Int64, length: UInt32, future: EventLoopFuture<ByteBuffer?>)] = []
            func fillPipeline() async throws {
                while inFlight.count < maximumRequestsInFlight, nextOffset < size {
                    let length = UInt32(min(Int64(chunkSize), size - nextOffset))
                    try await reporter.throttle(Int(length))
                    inFlight.append((nextOffset, length, session.read(handle, offset: UInt64(nextOffset), length: length)))
                    nextOffset += Int64(length)
                }
            }

            try await fillPipeline()
            while !inFlight.isEmpty {
                let request = inFlight.removeFirst()
                var received: Int64 = 0
                var data = try await request.future.get()
                // Servers may return less than requested; fetch the rest of this chunk before moving on.
                while let chunk = data {
                    try chunk.withUnsafeReadableBytes { try file.write(contentsOf: Data($0)) }
                    received += Int64(chunk.readableBytes)
                    reporter.record(Int64(chunk.readableBytes))
                    guard received < Int64(request.length) else { break }
                    data = try await session.read(handle, offset: UInt64(request.offset + received),
                                                  length: request.length - UInt32(received)).get()
                }
                guard received == Int64(request.length) else {
                    throw StorageError.invalidResponse("\(path.name) changed during the download.")
                }
                try Task.checkCancellation()
                try await fillPipeline()
            }
        } catch {
            await session.close(handle)
            throw SFTPSession.map(error, path: path.string)
        }
        await session.close(handle)
    }
}

/// Keeps one connected session, reconnecting when the previous one closed.
actor SFTPSessionManager {
    private let configuration: SFTPConfiguration
    private var session: SFTPSession?
    private var connecting: Task<SFTPSession, any Error>?
    /// Parsed once, because decrypting a private key with bcrypt is deliberately slow.
    private var offer: NIOSSHUserAuthenticationOffer.Offer?

    init(configuration: SFTPConfiguration) {
        self.configuration = configuration
    }

    func current() async throws -> SFTPSession {
        if let session, session.isActive {
            return session
        }
        if let connecting {
            return try await connecting.value
        }
        let configuration = configuration
        let offer = try self.offer ?? SFTPSession.makeOffer(configuration)
        self.offer = offer
        let task = Task { try await SFTPSession.connect(configuration, offer: offer) }
        connecting = task
        defer { connecting = nil }
        let session = try await task.value
        self.session = session
        return session
    }

    func close() async {
        await session?.close()
        session = nil
    }
}
