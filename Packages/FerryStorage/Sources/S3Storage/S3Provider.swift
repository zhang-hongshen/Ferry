import CryptoKit
import Foundation
import StorageCore

/// S3 and S3-compatible storage. The root lists buckets; below a bucket, "/" in keys is
/// treated as a directory separator so the browser behaves like a file system.
public final class S3Provider: StorageProvider {
    public let capabilities: StorageCapabilities = [
        .presignedURLs, .serverSideCopy, .multipartUpload, .resumableUpload, .resumableDownload,
        .buckets, .metadataEditing,
    ]

    /// Files at least this large use multipart upload.
    let multipartThreshold: Int64 = 16 * 1024 * 1024
    let minimumPartSize: Int64 = 8 * 1024 * 1024
    let maximumPartCount: Int64 = 10_000
    let partConcurrency = 4
    let downloadChunkSize: Int64 = 8 * 1024 * 1024
    /// CopyObject handles objects up to 5 GiB; larger objects need UploadPartCopy.
    let maximumSingleCopySize: Int64 = 5 * 1024 * 1024 * 1024
    let copyPartSize: Int64 = 512 * 1024 * 1024
    let directoryConcurrency = 8

    let client: S3Client

    public init(configuration: S3Configuration) throws {
        client = try S3Client(configuration: configuration)
    }

    // MARK: Session

    public func connect() async throws {
        _ = try await listBuckets()
    }

    public func url(for path: RemotePath) -> URL? {
        guard let location = S3Location(path) else {
            return try? client.url(bucket: nil, key: nil)
        }
        return try? client.url(bucket: location.bucket, key: location.key)
    }

    // MARK: Listing

    public func list(_ path: RemotePath) -> AsyncThrowingStream<[RemoteItem], any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let location = S3Location(path) else {
                        continuation.yield(try await listBuckets())
                        continuation.finish()
                        return
                    }
                    let prefix = location.directoryPrefix
                    for try await page in objectPages(bucket: location.bucket, prefix: prefix, delimiter: "/") {
                        let items = page.prefixes.map {
                            RemoteItem(path: S3Location.path(bucket: location.bucket, key: $0), kind: .directory)
                        } + page.objects.filter { $0.key != prefix }.map { $0.item(bucket: location.bucket) }
                        continuation.yield(items.filter { $0.path != path })
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: StorageError.wrapping(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func listRecursively(_ path: RemotePath) -> AsyncThrowingStream<[RemoteItem], any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let buckets: [String]
                    let prefix: String
                    if let location = S3Location(path) {
                        buckets = [location.bucket]
                        prefix = location.directoryPrefix
                    } else {
                        let bucketItems = try await listBuckets()
                        continuation.yield(bucketItems)
                        buckets = bucketItems.map(\.name)
                        prefix = ""
                    }
                    for bucket in buckets {
                        for try await page in objectPages(bucket: bucket, prefix: prefix, delimiter: nil) {
                            let items = page.objects.filter { $0.key != prefix }.map { object in
                                object.key.hasSuffix("/")
                                    ? RemoteItem(path: S3Location.path(bucket: bucket, key: object.key), kind: .directory)
                                    : object.item(bucket: bucket)
                            }
                            continuation.yield(items)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: StorageError.wrapping(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func item(at path: RemotePath) async throws -> RemoteItem {
        guard let location = S3Location(path) else {
            return RemoteItem(path: .root, kind: .directory)
        }
        if location.key.isEmpty {
            try await client.send(S3Request(method: "HEAD", bucket: location.bucket))
            return RemoteItem(path: path, kind: .bucket)
        }
        do {
            let head = try await headObject(location)
            return RemoteItem(path: path, kind: .file, size: head.size, modificationDate: head.lastModified,
                              eTag: head.eTag, storageClass: head.metadata.storageClass)
        } catch StorageError.notFound {
            var request = S3Request(bucket: location.bucket)
            request.query = ["list-type": "2", "prefix": location.directoryPrefix, "max-keys": "1"]
            let (data, _) = try await client.send(request)
            let root = try S3XMLElement.parse(data)
            guard !root.children("Contents").isEmpty || !root.children("CommonPrefixes").isEmpty else {
                throw StorageError.notFound(path)
            }
            return RemoteItem(path: path, kind: .directory)
        }
    }

    func listBuckets() async throws -> [RemoteItem] {
        let (data, _) = try await client.send(S3Request())
        let root = try S3XMLElement.parse(data)
        return (root.child("Buckets")?.children("Bucket") ?? []).compactMap { bucket in
            guard let name = bucket.value("Name") else { return nil }
            let created = S3Dates.parseISO8601(bucket.value("CreationDate"))
            return RemoteItem(path: RemotePath(components: [name]), kind: .bucket,
                              creationDate: created, modificationDate: created)
        }
    }

    struct ObjectSummary: Sendable {
        var key: String
        var size: Int64
        var lastModified: Date?
        var eTag: String?
        var storageClass: String?

        func item(bucket: String) -> RemoteItem {
            RemoteItem(path: S3Location.path(bucket: bucket, key: key), kind: .file, size: size,
                       modificationDate: lastModified, eTag: eTag, storageClass: storageClass)
        }
    }

    struct ObjectPage: Sendable {
        var objects: [ObjectSummary]
        var prefixes: [String]
    }

    /// Pages of ListObjectsV2. Keys are requested URL-encoded so any character survives XML.
    func objectPages(bucket: String, prefix: String, delimiter: String?) -> AsyncThrowingStream<ObjectPage, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var continuationToken: String?
                    repeat {
                        var request = S3Request(bucket: bucket)
                        request.query = ["list-type": "2", "prefix": prefix, "encoding-type": "url", "max-keys": "1000"]
                        request.query["delimiter"] = delimiter
                        request.query["continuation-token"] = continuationToken
                        let (data, _) = try await client.send(request)
                        let root = try S3XMLElement.parse(data)
                        let objects = root.children("Contents").compactMap { content -> ObjectSummary? in
                            guard let key = content.value("Key").map(Self.decodeKey) else { return nil }
                            return ObjectSummary(
                                key: key,
                                size: Int64(content.value("Size") ?? "") ?? 0,
                                lastModified: S3Dates.parseISO8601(content.value("LastModified")),
                                eTag: content.value("ETag")?.unquoted,
                                storageClass: content.value("StorageClass")
                            )
                        }
                        let prefixes = root.children("CommonPrefixes").compactMap { $0.value("Prefix").map(Self.decodeKey) }
                        continuation.yield(ObjectPage(objects: objects, prefixes: prefixes))
                        let truncated = root.value("IsTruncated") == "true"
                        continuationToken = truncated ? root.value("NextContinuationToken") : nil
                    } while continuationToken != nil
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// With `encoding-type=url`, S3 encodes spaces as "+" and a literal "+" as "%2B".
    private static func decodeKey(_ key: String) -> String {
        let spaced = key.replacingOccurrences(of: "+", with: " ")
        return spaced.removingPercentEncoding ?? spaced
    }

    /// Every raw key below a prefix, including directory marker objects.
    func allKeys(bucket: String, prefix: String) async throws -> [ObjectSummary] {
        var objects: [ObjectSummary] = []
        for try await page in objectPages(bucket: bucket, prefix: prefix, delimiter: nil) {
            objects.append(contentsOf: page.objects)
        }
        return objects
    }

    // MARK: Objects

    struct ObjectHead: Sendable {
        var size: Int64
        var lastModified: Date?
        var eTag: String?
        var metadata: RemoteMetadata
    }

    func headObject(_ location: S3Location) async throws -> ObjectHead {
        let (_, response) = try await client.send(S3Request(method: "HEAD", bucket: location.bucket, key: location.key))
        var metadata = RemoteMetadata()
        for (name, value) in response.allHeaderFields {
            guard let name = (name as? String)?.lowercased(), let value = value as? String else { continue }
            switch name {
            case "content-type": metadata.contentType = value
            case "cache-control": metadata.cacheControl = value
            case "content-disposition": metadata.contentDisposition = value
            case "content-encoding": metadata.contentEncoding = value
            case "etag": metadata.eTag = value.unquoted
            case "x-amz-storage-class": metadata.storageClass = value
            case "x-amz-version-id": metadata.versionID = value
            default:
                if name.hasPrefix("x-amz-meta-") {
                    metadata.custom[String(name.dropFirst("x-amz-meta-".count))] = value
                }
            }
        }
        return ObjectHead(
            size: Int64(response.value(forHTTPHeaderField: "Content-Length") ?? "") ?? 0,
            lastModified: S3Dates.parseHTTP(response.value(forHTTPHeaderField: "Last-Modified")),
            eTag: metadata.eTag,
            metadata: metadata
        )
    }

    public func metadata(for path: RemotePath) async throws -> RemoteMetadata {
        try await headObject(try S3Location.object(path)).metadata
    }

    /// Replaces metadata by copying the object onto itself with `REPLACE`.
    public func updateMetadata(_ metadata: RemoteMetadata, for path: RemotePath) async throws {
        let location = try S3Location.object(path)
        var headers = try Self.metadataHeaders(metadata)
        headers["x-amz-metadata-directive"] = "REPLACE"
        headers["x-amz-copy-source"] = location.copySource
        let (data, _) = try await client.send(S3Request(method: "PUT", bucket: location.bucket, key: location.key,
                                                        headers: headers))
        try S3Client.checkEmbeddedError(data, bucket: location.bucket, key: location.key)
    }

    static func metadataHeaders(_ metadata: RemoteMetadata) throws -> [String: String] {
        var headers: [String: String] = [:]
        headers["Content-Type"] = metadata.contentType.nonEmpty
        headers["Cache-Control"] = metadata.cacheControl.nonEmpty
        headers["Content-Disposition"] = metadata.contentDisposition.nonEmpty
        headers["Content-Encoding"] = metadata.contentEncoding.nonEmpty
        for (name, value) in metadata.custom {
            let name = name.lowercased().trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            guard name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }),
                  value.allSatisfy(\.isASCII) else {
                throw StorageError.invalidConfiguration("Metadata names and values must be ASCII.")
            }
            headers["x-amz-meta-\(name)"] = value
        }
        return headers
    }

    public func createDirectory(at path: RemotePath) async throws {
        guard let location = S3Location(path) else {
            throw StorageError.alreadyExists(path)
        }
        if location.key.isEmpty {
            try await createBucket(named: location.bucket)
            return
        }
        try await client.send(S3Request(method: "PUT", bucket: location.bucket, key: location.directoryPrefix,
                                        body: Data()))
    }

    /// Deletes permanently, like Finder's Delete Immediately: every version and delete marker of the
    /// keys goes, and a bucket is emptied first. The parent folder stays even when it becomes empty.
    public func delete(_ item: RemoteItem) async throws {
        switch item.kind {
        case .bucket:
            try await deleteBucket(named: item.name, force: true)
        case .directory:
            let location = try S3Location.object(item.path)
            let versions = try await allVersions(bucket: location.bucket, prefix: location.directoryPrefix)
            try await deleteObjects(bucket: location.bucket, objects: versions)
            try await keepParentFolder(of: location)
        case .file, .symbolicLink:
            let location = try S3Location.object(item.path)
            let versions = try await allVersions(bucket: location.bucket, prefix: location.key)
                .filter { $0.key == location.key }
            try await deleteObjects(bucket: location.bucket, objects: versions)
            try await keepParentFolder(of: location)
        }
    }

    /// S3 folders exist only through the keys below them, so removing a folder's last item would make
    /// the folder vanish. A marker keeps it, as a file system would.
    private func keepParentFolder(of location: S3Location) async throws {
        let parentKey = location.key.split(separator: "/").dropLast().joined(separator: "/")
        guard !parentKey.isEmpty else { return }
        let parent = S3Location(bucket: location.bucket, key: parentKey)
        var request = S3Request(bucket: parent.bucket)
        request.query = ["list-type": "2", "prefix": parent.directoryPrefix, "max-keys": "1"]
        let (data, _) = try await client.send(request)
        guard try S3XMLElement.parse(data).children("Contents").isEmpty else { return }
        try await client.send(S3Request(method: "PUT", bucket: parent.bucket, key: parent.directoryPrefix, body: Data()))
    }

    /// A key and, in versioned buckets, one of its versions or delete markers.
    struct ObjectVersion: Sendable, Hashable {
        var key: String
        var versionID: String?
    }

    /// Every version and delete marker below a prefix. Services without ListObjectVersions, or
    /// credentials without access to it, fall back to the current keys.
    func allVersions(bucket: String, prefix: String) async throws -> [ObjectVersion] {
        do {
            var versions: [ObjectVersion] = []
            var keyMarker: String?
            var versionIDMarker: String?
            repeat {
                var request = S3Request(bucket: bucket)
                request.query = ["versions": "", "prefix": prefix, "encoding-type": "url", "max-keys": "1000"]
                request.query["key-marker"] = keyMarker
                request.query["version-id-marker"] = versionIDMarker
                let (data, _) = try await client.send(request)
                let root = try S3XMLElement.parse(data)
                for entry in root.children("Version") + root.children("DeleteMarker") {
                    guard let key = entry.value("Key").map(Self.decodeKey) else { continue }
                    // "null" is the version of objects written while versioning was off.
                    let versionID = entry.value("VersionId").flatMap { $0 == "null" || $0.isEmpty ? nil : $0 }
                    versions.append(ObjectVersion(key: key, versionID: versionID))
                }
                let truncated = root.value("IsTruncated") == "true"
                keyMarker = truncated ? root.value("NextKeyMarker").map(Self.decodeKey) : nil
                versionIDMarker = truncated ? root.value("NextVersionIdMarker") : nil
            } while keyMarker != nil
            return versions
        } catch let error as StorageError {
            switch error {
            case .server, .permissionDenied, .invalidResponse:
                return try await allKeys(bucket: bucket, prefix: prefix).map { ObjectVersion(key: $0.key) }
            default:
                throw error
            }
        }
    }

    /// DeleteObjects in batches of 1000. Deleting a missing key is not an error in S3.
    func deleteObjects(bucket: String, objects: [ObjectVersion]) async throws {
        let unique = Array(Set(objects))
        for start in stride(from: 0, to: unique.count, by: 1000) {
            let batch = unique[start..<min(start + 1000, unique.count)]
            let entries = batch.map { object in
                let version = object.versionID.map { "<VersionId>\(S3XMLWriter.escape($0))</VersionId>" } ?? ""
                return "<Object><Key>\(S3XMLWriter.escape(object.key))</Key>\(version)</Object>"
            }.joined()
            let body = Data("<Delete><Quiet>true</Quiet>\(entries)</Delete>".utf8)
            var request = S3Request(method: "POST", bucket: bucket, query: ["delete": ""], body: body)
            request.headers["Content-MD5"] = Data(Insecure.MD5.hash(data: body)).base64EncodedString()
            request.headers["Content-Type"] = "application/xml"
            let (data, _) = try await client.send(request)
            if let root = try? S3XMLElement.parse(data), let error = root.child("Error") {
                let key = error.value("Key")
                throw S3Client.storageError(status: 200, code: error.value("Code"), message: error.value("Message"),
                                            path: S3Client.path(bucket: bucket, key: key))
            }
        }
    }

    public func copy(_ item: RemoteItem, to destination: RemotePath) async throws {
        let source = try S3Location.object(item.path)
        let target = try S3Location.object(destination)
        switch item.kind {
        case .bucket:
            throw StorageError.unsupported("Buckets cannot be copied.")
        case .directory:
            let objects = try await allKeys(bucket: source.bucket, prefix: source.directoryPrefix)
            try await createDirectory(at: destination)
            let sourcePrefix = source.directoryPrefix
            let targetPrefix = target.directoryPrefix
            try await forEachConcurrently(objects.filter { $0.key != sourcePrefix }, limit: directoryConcurrency) { object in
                let relative = String(object.key.dropFirst(sourcePrefix.count))
                try await self.copyObject(
                    from: S3Location(bucket: source.bucket, key: object.key),
                    to: S3Location(bucket: target.bucket, key: targetPrefix + relative),
                    size: object.size
                )
            }
        case .file, .symbolicLink:
            var size = item.size
            if size == nil {
                size = try await headObject(source).size
            }
            try await copyObject(from: source, to: target, size: size ?? 0)
        }
    }

    public func move(_ item: RemoteItem, to destination: RemotePath) async throws {
        try await copy(item, to: destination)
        try await delete(item)
    }

    func copyObject(from source: S3Location, to target: S3Location, size: Int64) async throws {
        guard size > maximumSingleCopySize else {
            let request = S3Request(method: "PUT", bucket: target.bucket, key: target.key,
                                    headers: ["x-amz-copy-source": source.copySource])
            let (data, _) = try await client.send(request)
            try S3Client.checkEmbeddedError(data, bucket: target.bucket, key: target.key)
            return
        }
        let uploadID = try await createMultipartUpload(target, contentType: nil)
        do {
            let partCount = Int((size + copyPartSize - 1) / copyPartSize)
            var parts: [Int: String] = [:]
            for number in 1...partCount {
                let start = Int64(number - 1) * copyPartSize
                let end = min(start + copyPartSize, size) - 1
                var request = S3Request(method: "PUT", bucket: target.bucket, key: target.key,
                                        query: ["partNumber": "\(number)", "uploadId": uploadID])
                request.headers["x-amz-copy-source"] = source.copySource
                request.headers["x-amz-copy-source-range"] = "bytes=\(start)-\(end)"
                let (data, _) = try await client.send(request)
                try S3Client.checkEmbeddedError(data, bucket: target.bucket, key: target.key)
                guard let eTag = try S3XMLElement.parse(data).value("ETag") else {
                    throw StorageError.invalidResponse("UploadPartCopy returned no ETag.")
                }
                parts[number] = eTag
            }
            try await completeMultipartUpload(target, uploadID: uploadID, parts: parts)
        } catch {
            await abortMultipartUpload(target, uploadID: uploadID)
            throw error
        }
    }

    // MARK: Buckets

    public func createBucket(named name: String) async throws {
        var request = S3Request(method: "PUT", bucket: name)
        let region = client.region(for: nil)
        if region != "us-east-1" {
            request.body = Data("""
            <CreateBucketConfiguration><LocationConstraint>\(S3XMLWriter.escape(region))</LocationConstraint></CreateBucketConfiguration>
            """.utf8)
        }
        try await client.send(request)
    }

    public func deleteBucket(named name: String, force: Bool) async throws {
        if force {
            try await deleteObjects(bucket: name, objects: try await allVersions(bucket: name, prefix: ""))
        }
        try await client.send(S3Request(method: "DELETE", bucket: name))
    }

    // MARK: Sharing

    public func presignedURL(for path: RemotePath, expiresIn: Duration) async throws -> URL {
        let location = try S3Location.object(path)
        let seconds = Int(min(max(expiresIn.components.seconds, 1), 7 * 24 * 3600))
        return try client.presign(bucket: location.bucket, key: location.key, expires: seconds)
    }
}

/// A bucket and key. A bucket root has an empty key.
struct S3Location: Sendable, Hashable {
    var bucket: String
    var key: String

    init(bucket: String, key: String) {
        self.bucket = bucket
        self.key = key
    }

    /// `nil` for the root, which lists buckets.
    init?(_ path: RemotePath) {
        guard let bucket = path.components.first else { return nil }
        self.bucket = bucket
        key = path.components.dropFirst().joined(separator: "/")
    }

    /// A location that must be inside a bucket.
    static func object(_ path: RemotePath) throws -> S3Location {
        guard let location = S3Location(path) else {
            throw StorageError.unsupported("This operation needs a location inside a bucket.")
        }
        return location
    }

    /// The prefix that lists this location's children.
    var directoryPrefix: String {
        key.isEmpty ? "" : key + "/"
    }

    var copySource: String {
        S3Encoding.encode(bucket) + "/" + S3Encoding.encodeKey(key)
    }

    static func path(bucket: String, key: String) -> RemotePath {
        RemotePath(components: [bucket] + key.split(separator: "/").map(String.init))
    }
}

extension Optional where Wrapped == String {
    var nonEmpty: String? {
        guard let value = self?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        return value
    }
}
