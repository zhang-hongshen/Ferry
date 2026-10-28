import Foundation
import StorageCore
import Synchronization
import UniformTypeIdentifiers

extension S3Provider {
    // MARK: Upload

    /// Small files use one PUT. Large files use concurrent multipart upload; the upload ID is the
    /// resume token, so a resumed upload skips parts the server already has.
    public func upload(from localURL: URL, to path: RemotePath, options: TransferOptions,
                       reporter: TransferReporter) async throws {
        let location = try S3Location.object(path)
        guard !location.key.isEmpty else {
            throw StorageError.unsupported("Files must be uploaded into a bucket.")
        }
        let size = try LocalFile.size(of: localURL)
        let contentType = UTType(filenameExtension: localURL.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
        reporter.setTotal(size)
        do {
            if size < multipartThreshold {
                try await putObject(localURL, size: size, to: location, contentType: contentType, reporter: reporter)
            } else {
                try await multipartUpload(localURL, size: size, to: location, contentType: contentType,
                                          options: options, reporter: reporter)
            }
        } catch {
            throw StorageError.wrapping(error)
        }
    }

    private func putObject(_ localURL: URL, size: Int64, to location: S3Location, contentType: String,
                           reporter: TransferReporter) async throws {
        let body = try LocalFile.read(localURL, offset: 0, length: Int(size))
        try await reporter.throttle(body.count)
        let sent = Mutex<Int64>(0)
        let delegate = UploadProgressDelegate { bytes in
            sent.withLock { $0 += bytes }
            reporter.record(bytes)
        }
        do {
            var request = S3Request(method: "PUT", bucket: location.bucket, key: location.key, body: body)
            request.headers["Content-Type"] = contentType
            try await client.send(request, retries: 0, delegate: delegate)
        } catch {
            reporter.record(-sent.withLock { $0 })
            throw error
        }
    }

    func partSize(for size: Int64) -> Int64 {
        let mebibyte: Int64 = 1024 * 1024
        let needed = (size + maximumPartCount - 1) / maximumPartCount
        let rounded = (needed + mebibyte - 1) / mebibyte * mebibyte
        return max(minimumPartSize, rounded)
    }

    private func multipartUpload(_ localURL: URL, size: Int64, to location: S3Location, contentType: String,
                                 options: TransferOptions, reporter: TransferReporter) async throws {
        let partSize = partSize(for: size)
        let partCount = Int((size + partSize - 1) / partSize)
        @Sendable func length(ofPart number: Int) -> Int64 {
            min(partSize, size - Int64(number - 1) * partSize)
        }

        var uploadID: String?
        var completed: [Int: String] = [:]
        if options.resume, let token = options.resumeToken {
            do {
                for part in try await listParts(location, uploadID: token)
                where part.number <= partCount && part.size == length(ofPart: part.number) {
                    completed[part.number] = part.eTag
                }
                uploadID = token
            } catch StorageError.notFound {
                completed = [:]
            }
        }
        let activeUploadID: String
        if let uploadID {
            activeUploadID = uploadID
        } else {
            activeUploadID = try await createMultipartUpload(location, contentType: contentType)
            reporter.updateResumeToken(activeUploadID)
        }
        reporter.setCompleted(completed.keys.reduce(0) { $0 + length(ofPart: $1) })

        let remaining = (1...partCount).filter { completed[$0] == nil }
        let results = Mutex(completed)
        try await forEachConcurrently(remaining, limit: partConcurrency) { number in
            let eTag = try await self.uploadPart(
                number, of: localURL, offset: Int64(number - 1) * partSize, length: Int(length(ofPart: number)),
                to: location, uploadID: activeUploadID, reporter: reporter
            )
            results.withLock { $0[number] = eTag }
        }
        try await completeMultipartUpload(location, uploadID: activeUploadID, parts: results.withLock { $0 })
        reporter.updateResumeToken(nil)
    }

    private func uploadPart(_ number: Int, of localURL: URL, offset: Int64, length: Int, to location: S3Location,
                            uploadID: String, reporter: TransferReporter) async throws -> String {
        let body = try LocalFile.read(localURL, offset: offset, length: length)
        let maximumAttempts = 3
        for attempt in 1...maximumAttempts {
            try await reporter.throttle(body.count)
            let sent = Mutex<Int64>(0)
            let delegate = UploadProgressDelegate { bytes in
                sent.withLock { $0 += bytes }
                reporter.record(bytes)
            }
            do {
                let request = S3Request(method: "PUT", bucket: location.bucket, key: location.key,
                                        query: ["partNumber": "\(number)", "uploadId": uploadID], body: body)
                let (_, response) = try await client.send(request, retries: 0, delegate: delegate)
                guard let eTag = response.value(forHTTPHeaderField: "ETag") else {
                    throw StorageError.invalidResponse("UploadPart returned no ETag.")
                }
                return eTag
            } catch {
                reporter.record(-sent.withLock { $0 })
                let mapped = StorageError.wrapping(error)
                guard attempt < maximumAttempts, (mapped as? StorageError)?.isTransient == true else { throw mapped }
                try await Task.sleep(for: .seconds(attempt))
            }
        }
        throw StorageError.invalidResponse("UploadPart failed.")
    }

    func createMultipartUpload(_ location: S3Location, contentType: String?) async throws -> String {
        var request = S3Request(method: "POST", bucket: location.bucket, key: location.key, query: ["uploads": ""])
        request.headers["Content-Type"] = contentType
        let (data, _) = try await client.send(request)
        guard let uploadID = try S3XMLElement.parse(data).value("UploadId") else {
            throw StorageError.invalidResponse("CreateMultipartUpload returned no upload ID.")
        }
        return uploadID
    }

    func completeMultipartUpload(_ location: S3Location, uploadID: String, parts: [Int: String]) async throws {
        let body = parts.sorted { $0.key < $1.key }
            .map { "<Part><PartNumber>\($0.key)</PartNumber><ETag>\(S3XMLWriter.escape($0.value))</ETag></Part>" }
            .joined()
        let request = S3Request(method: "POST", bucket: location.bucket, key: location.key,
                                query: ["uploadId": uploadID],
                                headers: ["Content-Type": "application/xml"],
                                body: Data("<CompleteMultipartUpload>\(body)</CompleteMultipartUpload>".utf8))
        let (data, _) = try await client.send(request)
        try S3Client.checkEmbeddedError(data, bucket: location.bucket, key: location.key)
    }

    func abortMultipartUpload(_ location: S3Location, uploadID: String) async {
        let request = S3Request(method: "DELETE", bucket: location.bucket, key: location.key,
                                query: ["uploadId": uploadID])
        _ = try? await client.send(request)
    }

    public func discardPartialUpload(to path: RemotePath, resumeToken: String) async {
        guard let location = S3Location(path), !location.key.isEmpty else { return }
        await abortMultipartUpload(location, uploadID: resumeToken)
    }

    struct UploadedPart: Sendable {
        var number: Int
        var eTag: String
        var size: Int64
    }

    func listParts(_ location: S3Location, uploadID: String) async throws -> [UploadedPart] {
        var parts: [UploadedPart] = []
        var marker: String?
        repeat {
            var request = S3Request(bucket: location.bucket, key: location.key, query: ["uploadId": uploadID])
            request.query["part-number-marker"] = marker
            let (data, _) = try await client.send(request)
            let root = try S3XMLElement.parse(data)
            parts += root.children("Part").compactMap { part in
                guard let number = Int(part.value("PartNumber") ?? ""), let eTag = part.value("ETag") else { return nil }
                return UploadedPart(number: number, eTag: eTag, size: Int64(part.value("Size") ?? "") ?? 0)
            }
            marker = root.value("IsTruncated") == "true" ? root.value("NextPartNumberMarker") : nil
        } while marker != nil
        return parts
    }

    // MARK: Download

    /// Downloads in ranged chunks so progress, throttling, and resuming work at chunk granularity.
    /// The ETag is the resume token; a changed object restarts from the beginning.
    public func download(_ path: RemotePath, to localURL: URL, options: TransferOptions,
                         reporter: TransferReporter) async throws {
        let location = try S3Location.object(path)
        do {
            let head = try await headObject(location)
            reporter.setTotal(head.size)
            let canResume = options.resume && options.resumeToken != nil && options.resumeToken == head.eTag
            var (handle, offset) = try LocalFile.openForAppending(localURL, resume: canResume)
            if offset > head.size {
                try? handle.close()
                (handle, offset) = try LocalFile.openForAppending(localURL, resume: false)
            }
            defer { try? handle.close() }
            reporter.updateResumeToken(head.eTag)
            reporter.setCompleted(offset)

            while offset < head.size {
                let length = min(downloadChunkSize, head.size - offset)
                try await reporter.throttle(Int(length))
                var request = S3Request(bucket: location.bucket, key: location.key)
                request.headers["Range"] = "bytes=\(offset)-\(offset + length - 1)"
                if let eTag = head.eTag {
                    request.headers["If-Match"] = "\"\(eTag)\""
                }
                let (data, _) = try await client.send(request)
                guard !data.isEmpty else {
                    throw StorageError.invalidResponse("The server returned an empty range.")
                }
                try handle.write(contentsOf: data)
                offset += Int64(data.count)
                reporter.record(Int64(data.count))
            }
        } catch {
            throw StorageError.wrapping(error)
        }
    }
}
