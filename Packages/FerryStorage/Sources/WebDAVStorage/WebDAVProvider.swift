import Foundation
import StorageCore
import Synchronization
import UniformTypeIdentifiers

/// WebDAV (RFC 4918) over URLSession: PROPFIND listings, server-side COPY and MOVE, streamed uploads,
/// and ranged, resumable downloads.
public final class WebDAVProvider: StorageProvider {
    public let capabilities: StorageCapabilities = [.serverSideCopy, .atomicMove, .resumableDownload]

    let downloadChunkSize: Int64
    let uploadChunkSize = 64 * 1024
    let client: WebDAVClient

    static let propfindBody = Data("""
    <?xml version="1.0" encoding="utf-8"?>
    <d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getcontentlength/><d:creationdate/>\
    <d:getlastmodified/><d:getetag/><d:getcontenttype/></d:prop></d:propfind>
    """.utf8)

    public convenience init(configuration: WebDAVConfiguration) {
        self.init(configuration: configuration, sessionConfiguration: .ephemeral, downloadChunkSize: 8 * 1024 * 1024)
    }

    /// Tests replace the session configuration (to install a mock URLProtocol) and the chunk size.
    init(configuration: WebDAVConfiguration, sessionConfiguration: URLSessionConfiguration, downloadChunkSize: Int64) {
        client = WebDAVClient(configuration: configuration, sessionConfiguration: sessionConfiguration)
        self.downloadChunkSize = downloadChunkSize
    }

    public func connect() async throws {
        _ = try await propfind(.root, depth: "0", isCollection: true)
    }

    public func url(for path: RemotePath) -> URL? {
        client.url(for: path, isCollection: false)
    }

    // MARK: Listing

    func propfind(_ path: RemotePath, depth: String, isCollection: Bool) async throws -> [WebDAVResource] {
        let (data, _) = try await client.send(
            "PROPFIND", path, isCollection: isCollection,
            headers: ["Depth": depth, "Content-Type": "application/xml; charset=utf-8"],
            body: Self.propfindBody
        )
        return try WebDAVMultistatusParser.parse(data)
    }

    func item(for resource: WebDAVResource) -> RemoteItem? {
        guard let path = client.remotePath(forHrefPath: resource.hrefPath) else { return nil }
        return RemoteItem(
            path: path,
            kind: resource.isCollection ? .directory : .file,
            size: resource.isCollection ? nil : resource.contentLength,
            creationDate: resource.creationDate,
            modificationDate: resource.lastModified,
            eTag: resource.eTag.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "W/\"")) }
        )
    }

    public func list(_ path: RemotePath) -> AsyncThrowingStream<[RemoteItem], any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let resources = try await propfind(path, depth: "1", isCollection: true)
                    continuation.yield(resources.compactMap(item(for:)).filter { $0.path != path })
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func item(at path: RemotePath) async throws -> RemoteItem {
        guard let resource = try await propfind(path, depth: "0", isCollection: path.isRoot).first,
              var item = item(for: resource) else {
            throw StorageError.notFound(path)
        }
        item.path = path
        return item
    }

    // MARK: Changes

    public func createDirectory(at path: RemotePath) async throws {
        try await client.send("MKCOL", path, isCollection: true)
    }

    public func delete(_ item: RemoteItem) async throws {
        let (_, response) = try await client.send("DELETE", item.path, isCollection: item.isContainer)
        // 207 means some members could not be deleted.
        if response.statusCode == 207 {
            throw StorageError.server(code: "207", message: "Some items in \(item.name) could not be deleted.")
        }
    }

    public func move(_ item: RemoteItem, to destination: RemotePath) async throws {
        try await client.send("MOVE", item.path, isCollection: item.isContainer, headers: [
            "Destination": client.url(for: destination, isCollection: item.isContainer).absoluteString,
            "Overwrite": "T",
        ])
    }

    public func copy(_ item: RemoteItem, to destination: RemotePath) async throws {
        let (_, response) = try await client.send("COPY", item.path, isCollection: item.isContainer, headers: [
            "Destination": client.url(for: destination, isCollection: item.isContainer).absoluteString,
            "Overwrite": "T",
            "Depth": "infinity",
        ])
        if response.statusCode == 207 {
            throw StorageError.server(code: "207", message: "Some items in \(item.name) could not be copied.")
        }
    }

    // MARK: Upload

    /// Streams the file through a bound stream pair so the bandwidth limit applies while sending. When the
    /// server answers with an authentication challenge that needs the body again (Digest over HTTP), the
    /// upload is retried from the file without throttling.
    public func upload(from localURL: URL, to path: RemotePath, options: TransferOptions,
                       reporter: TransferReporter) async throws {
        let size = try LocalFile.size(of: localURL)
        reporter.setTotal(size)
        reporter.setCompleted(0)
        let contentType = UTType(filenameExtension: localURL.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
        var request = client.makeRequest("PUT", url: client.url(for: path, isCollection: false), headers: [
            "Content-Type": contentType,
            "Content-Length": "\(size)",
        ])
        do {
            try await streamedUpload(localURL, request: &request, path: path, reporter: reporter)
        } catch is BodyStreamRequested {
            reporter.setCompleted(0)
            try await fileUpload(localURL, request: request, path: path, reporter: reporter)
        }
    }

    private struct BodyStreamRequested: Error {}

    private func streamedUpload(_ localURL: URL, request: inout URLRequest, path: RemotePath,
                                reporter: TransferReporter) async throws {
        var input: InputStream?
        var output: OutputStream?
        Stream.getBoundStreams(withBufferSize: 256 * 1024, inputStream: &input, outputStream: &output)
        guard let input, let output else { throw StorageError.localFile("Cannot create an upload stream.") }
        request.httpBodyStream = input
        let writer = BodyStreamWriter(output: output)
        let chunkSize = uploadChunkSize
        let writing = Task.detached { try await writer.write(localURL, chunkSize: chunkSize, reporter: reporter) }
        let delegate = StreamTaskDelegate()
        do {
            let (_, response) = try await client.session.data(for: request, delegate: delegate)
            try await writing.value
            try check(response, method: "PUT", path: path)
        } catch {
            writing.cancel()
            writer.close()
            if delegate.requestedNewBodyStream {
                throw BodyStreamRequested()
            }
            // A local read error explains the failure better than the truncated request it caused.
            if case .failure(let writeError) = await writing.result, !(writeError is CancellationError) {
                throw StorageError.wrapping(writeError)
            }
            throw StorageError.wrapping(error)
        }
    }

    private func fileUpload(_ localURL: URL, request: URLRequest, path: RemotePath,
                            reporter: TransferReporter) async throws {
        var request = request
        request.httpBodyStream = nil
        let delegate = StreamTaskDelegate(onSent: { reporter.record($0) })
        do {
            let (_, response) = try await client.session.upload(for: request, fromFile: localURL, delegate: delegate)
            try check(response, method: "PUT", path: path)
        } catch {
            throw StorageError.wrapping(error)
        }
    }

    private func check(_ response: URLResponse, method: String, path: RemotePath) throws {
        guard let http = response as? HTTPURLResponse else {
            throw StorageError.invalidResponse("Not an HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw WebDAVClient.error(status: http.statusCode, method: method, path: path)
        }
    }

    // MARK: Download

    /// Downloads in ranged chunks, streaming each response straight into the destination file. The ETag
    /// (or size and date) is the resume token. Servers that ignore `Range` send the whole file once.
    public func download(_ path: RemotePath, to localURL: URL, options: TransferOptions,
                         reporter: TransferReporter) async throws {
        let item = try await item(at: path)
        guard !item.isContainer else { throw StorageError.unsupported("\(path.name) is a folder.") }
        let size = item.size
        let token = item.eTag ?? "\(size ?? -1):\(item.modificationDate?.timeIntervalSince1970 ?? 0)"
        reporter.setTotal(size)

        var (file, offset) = try LocalFile.openForAppending(localURL, resume: options.resume && options.resumeToken == token)
        if let size, offset > size {
            try? file.close()
            (file, offset) = try LocalFile.openForAppending(localURL, resume: false)
        }
        defer { try? file.close() }
        reporter.updateResumeToken(token)
        reporter.setCompleted(offset)

        do {
            while size.map({ offset < $0 }) ?? true {
                try await reporter.throttle(Int(downloadChunkSize))
                let end = offset + downloadChunkSize - 1
                let request = client.makeRequest("GET", url: client.url(for: path, isCollection: false),
                                                 headers: ["Range": "bytes=\(offset)-\(end)"])
                let (bytes, response) = try await client.session.bytes(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw StorageError.invalidResponse("Not an HTTP response.")
                }
                switch http.statusCode {
                case 206:
                    let written = try await Self.write(bytes, to: file, reporter: reporter)
                    offset += written
                    if written == 0 || (size == nil && written < downloadChunkSize) {
                        return
                    }
                case 200:
                    // The server ignored the range and sends the whole file.
                    try file.truncate(atOffset: 0)
                    reporter.setCompleted(0)
                    _ = try await Self.write(bytes, to: file, reporter: reporter)
                    return
                case 416:
                    return
                default:
                    throw WebDAVClient.error(status: http.statusCode, method: "GET", path: path)
                }
            }
        } catch {
            throw StorageError.wrapping(error)
        }
    }

    /// Copies a response body to the file in 256 KiB blocks and returns the number of bytes written.
    static func write(_ bytes: URLSession.AsyncBytes, to file: FileHandle, reporter: TransferReporter) async throws -> Int64 {
        let blockSize = 256 * 1024
        var block = [UInt8]()
        block.reserveCapacity(blockSize)
        var total: Int64 = 0
        func flush() throws {
            guard !block.isEmpty else { return }
            try file.write(contentsOf: block)
            total += Int64(block.count)
            reporter.record(Int64(block.count))
            block.removeAll(keepingCapacity: true)
        }
        for try await byte in bytes {
            block.append(byte)
            if block.count == blockSize {
                try flush()
            }
        }
        try flush()
        return total
    }
}

/// Feeds a file into the writing end of a bound stream pair, throttled chunk by chunk.
private final class BodyStreamWriter: @unchecked Sendable {
    // The output stream is used only by the writing task and `close()`, which runs after it is cancelled.
    private let output: OutputStream
    private let closed = Mutex(false)

    init(output: OutputStream) {
        self.output = output
    }

    func write(_ url: URL, chunkSize: Int, reporter: TransferReporter) async throws {
        let file = try FileHandle(forReadingFrom: url)
        defer {
            try? file.close()
            close()
        }
        output.open()
        while let data = try file.read(upToCount: chunkSize), !data.isEmpty {
            try await reporter.throttle(data.count)
            var offset = 0
            while offset < data.count {
                try Task.checkCancellation()
                if output.streamStatus == .error || output.streamStatus == .closed {
                    throw StorageError.network(output.streamError?.localizedDescription ?? "The upload stream closed.")
                }
                guard output.hasSpaceAvailable else {
                    try await Task.sleep(for: .milliseconds(2))
                    continue
                }
                let written = data.withUnsafeBytes { raw -> Int in
                    guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                    return output.write(base.advanced(by: offset), maxLength: data.count - offset)
                }
                guard written >= 0 else {
                    throw StorageError.network(output.streamError?.localizedDescription ?? "Writing the upload failed.")
                }
                offset += written
            }
            reporter.record(Int64(data.count))
        }
    }

    func close() {
        let alreadyClosed = closed.withLock { closed in
            defer { closed = true }
            return closed
        }
        if !alreadyClosed {
            output.close()
        }
    }
}

/// Records whether URLSession asked for the body again, and forwards upload progress.
private final class StreamTaskDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private let requested = Mutex(false)
    private let onSent: (@Sendable (Int64) -> Void)?

    init(onSent: (@Sendable (Int64) -> Void)? = nil) {
        self.onSent = onSent
    }

    var requestedNewBodyStream: Bool { requested.withLock { $0 } }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    needNewBodyStream completionHandler: @escaping @Sendable (InputStream?) -> Void) {
        requested.withLock { $0 = true }
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        onSent?(bytesSent)
    }
}
