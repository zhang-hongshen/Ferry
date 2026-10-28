import Foundation
import StorageCore
import Synchronization

/// One S3 REST call. `key` is the object key without a leading slash.
struct S3Request: Sendable {
    var method = "GET"
    var bucket: String?
    var key: String?
    /// Query parameters; an empty value produces a bare flag such as `?uploads=`.
    var query: [String: String] = [:]
    var headers: [String: String] = [:]
    var body: Data?
    /// Overrides the payload hash, for example `UNSIGNED-PAYLOAD`.
    var payloadHash: String?
}

/// Builds, signs, and sends S3 requests, and maps failures onto `StorageError`.
final class S3Client: Sendable {
    let configuration: S3Configuration
    let endpoint: S3Endpoint
    let signer: S3Signer
    let session: URLSession
    /// Regions learned from redirects, keyed by bucket.
    private let bucketRegions = Mutex<[String: String]>([:])

    init(configuration: S3Configuration) throws {
        guard !configuration.accessKeyID.isEmpty, !configuration.secretAccessKey.isEmpty else {
            throw StorageError.invalidConfiguration("An access key and secret key are required.")
        }
        self.configuration = configuration
        endpoint = try S3Endpoint(configuration: configuration)
        signer = S3Signer(
            accessKeyID: configuration.accessKeyID,
            secretAccessKey: configuration.secretAccessKey,
            sessionToken: configuration.sessionToken
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.urlCache = nil
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        sessionConfiguration.timeoutIntervalForRequest = 60
        sessionConfiguration.httpMaximumConnectionsPerHost = 8
        session = URLSession(configuration: sessionConfiguration)
    }

    func region(for bucket: String?) -> String {
        let fallback = configuration.region.isEmpty ? "us-east-1" : configuration.region
        guard let bucket else { return fallback }
        return bucketRegions.withLock { $0[bucket] } ?? fallback
    }

    func url(bucket: String?, key: String?, query: [String: String] = [:]) throws -> URL {
        let region = region(for: bucket)
        var host = endpoint.host(forRegion: region)
        var path = ""
        if let bucket {
            if configuration.usePathStyle || !Self.isVirtualHostCompatible(bucket, https: configuration.useHTTPS) {
                path = "/" + S3Encoding.encode(bucket)
            } else {
                host = "\(bucket).\(host)"
            }
        }
        if let key, !key.isEmpty {
            path += "/" + S3Encoding.encodeKey(key)
        }
        var components = URLComponents()
        components.scheme = endpoint.scheme
        components.host = host
        components.port = endpoint.port
        components.percentEncodedPath = path.isEmpty ? "/" : path
        if !query.isEmpty {
            components.percentEncodedQuery = query
                .sorted { $0.key < $1.key }
                .map { "\(S3Encoding.encode($0.key))=\(S3Encoding.encode($0.value))" }
                .joined(separator: "&")
        }
        guard let url = components.url else {
            throw StorageError.invalidConfiguration("Cannot build a URL for host \(host).")
        }
        return url
    }

    func presign(bucket: String, key: String, expires: Int) throws -> URL {
        let url = try url(bucket: bucket, key: key)
        return signer.presign(url, region: region(for: bucket), expires: expires)
    }

    /// Sends a request. Transient failures are retried `retries` times with exponential backoff.
    /// A `delegate` receives upload progress; requests with a delegate should not retry internally.
    @discardableResult
    func send(
        _ request: S3Request,
        retries: Int = 2,
        delegate: (any URLSessionTaskDelegate)? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0
        var regionRetried = false
        while true {
            do {
                return try await sendOnce(request, delegate: delegate)
            } catch let redirect as RegionRedirect where !regionRetried {
                regionRetried = true
                if let bucket = request.bucket {
                    bucketRegions.withLock { $0[bucket] = redirect.region }
                }
            } catch {
                let mapped = StorageError.wrapping(error)
                guard attempt < retries, let storageError = mapped as? StorageError, storageError.isTransient else {
                    throw mapped
                }
                attempt += 1
                try await Task.sleep(for: .milliseconds(500 * (1 << attempt)))
            }
        }
    }

    private struct RegionRedirect: Error {
        let region: String
    }

    private func sendOnce(
        _ request: S3Request,
        delegate: (any URLSessionTaskDelegate)?
    ) async throws -> (Data, HTTPURLResponse) {
        var urlRequest = URLRequest(url: try url(bucket: request.bucket, key: request.key, query: request.query))
        urlRequest.httpMethod = request.method
        urlRequest.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        let payloadHash = request.payloadHash
            ?? request.body.map(S3Signer.sha256Hex)
            ?? S3Signer.emptyPayloadHash
        signer.sign(&urlRequest, region: region(for: request.bucket), payloadHash: payloadHash)

        let data: Data
        let response: URLResponse
        if let body = request.body {
            (data, response) = try await session.upload(for: urlRequest, from: body, delegate: delegate)
        } else {
            (data, response) = try await session.data(for: urlRequest, delegate: delegate)
        }
        guard let http = response as? HTTPURLResponse else {
            throw StorageError.invalidResponse("Not an HTTP response.")
        }
        if (200..<300).contains(http.statusCode) {
            return (data, http)
        }

        let error = Self.parseError(data)
        if let region = http.value(forHTTPHeaderField: "x-amz-bucket-region") ?? error.region,
           region != self.region(for: request.bucket),
           [301, 307, 400].contains(http.statusCode) {
            throw RegionRedirect(region: region)
        }
        throw Self.storageError(status: http.statusCode, code: error.code, message: error.message,
                                path: Self.path(bucket: request.bucket, key: request.key))
    }

    /// Some operations (CopyObject, CompleteMultipartUpload) report failures in a 200 response body.
    static func checkEmbeddedError(_ data: Data, bucket: String?, key: String?) throws {
        guard let root = try? S3XMLElement.parse(data), root.name == "Error" else { return }
        throw storageError(status: 200, code: root.value("Code"), message: root.value("Message"),
                           path: path(bucket: bucket, key: key))
    }

    static func path(bucket: String?, key: String?) -> RemotePath {
        var components = bucket.map { [$0] } ?? []
        components += (key ?? "").split(separator: "/").map(String.init)
        return RemotePath(components: components)
    }

    private static func parseError(_ data: Data) -> (code: String?, message: String?, region: String?) {
        guard !data.isEmpty, let root = try? S3XMLElement.parse(data) else { return (nil, nil, nil) }
        return (root.value("Code"), root.value("Message"), root.value("Region"))
    }

    static func storageError(status: Int, code: String?, message: String?, path: RemotePath) -> StorageError {
        switch code {
        case "InvalidAccessKeyId", "SignatureDoesNotMatch", "InvalidToken", "ExpiredToken", "AuthorizationHeaderMalformed":
            return .authenticationFailed(message)
        case "AccessDenied", "AllAccessDisabled":
            return .permissionDenied(path)
        case "NoSuchKey", "NoSuchBucket", "NoSuchUpload":
            return .notFound(path)
        case "BucketNotEmpty":
            return .directoryNotEmpty(path)
        case "BucketAlreadyExists", "BucketAlreadyOwnedByYou":
            return .alreadyExists(path)
        default:
            break
        }
        switch status {
        case 401: return .authenticationFailed(message)
        case 403: return .permissionDenied(path)
        case 404: return .notFound(path)
        case 500, 502, 503, 504:
            return .server(code: code ?? "ServiceUnavailable", message: message ?? "The service is unavailable.")
        default:
            return .server(code: code, message: message ?? HTTPURLResponse.localizedString(forStatusCode: status))
        }
    }

    static func isVirtualHostCompatible(_ bucket: String, https: Bool) -> Bool {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-.")
        guard (3...63).contains(bucket.count), bucket.allSatisfy(allowed.contains),
              bucket.first != "-", bucket.first != "." else { return false }
        return !(https && bucket.contains("."))
    }
}

/// Forwards upload progress of a single request.
final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private let onSent: @Sendable (Int64) -> Void

    init(onSent: @escaping @Sendable (Int64) -> Void) {
        self.onSent = onSent
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        onSent(bytesSent)
    }
}
