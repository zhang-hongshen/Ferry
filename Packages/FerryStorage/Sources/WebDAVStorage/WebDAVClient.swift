import Foundation
import StorageCore

/// Builds WebDAV URLs, sends requests with credentials, and maps HTTP failures onto `StorageError`.
final class WebDAVClient: Sendable {
    let baseURL: URL
    let session: URLSession
    private let username: String
    private let password: String
    private let basePathComponents: [String]

    init(configuration: WebDAVConfiguration, sessionConfiguration: URLSessionConfiguration) {
        baseURL = configuration.baseURL
        username = configuration.username
        password = configuration.password
        basePathComponents = RemotePath(configuration.baseURL.path(percentEncoded: false)).components
        sessionConfiguration.urlCache = nil
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        sessionConfiguration.timeoutIntervalForRequest = 60
        session = URLSession(
            configuration: sessionConfiguration,
            delegate: CredentialDelegate(username: configuration.username, password: configuration.password),
            delegateQueue: nil
        )
    }

    // MARK: Paths

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    /// The URL of `path` below the base collection. Collections end in "/", as many servers require.
    func url(for path: RemotePath, isCollection: Bool) -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return baseURL }
        let encoded = path.components.map { $0.addingPercentEncoding(withAllowedCharacters: Self.unreserved) ?? $0 }
        var urlPath = components.percentEncodedPath
        if !urlPath.hasSuffix("/") {
            urlPath += "/"
        }
        urlPath += encoded.joined(separator: "/")
        if isCollection && !path.isRoot {
            urlPath += "/"
        }
        components.percentEncodedPath = urlPath
        components.query = nil
        return components.url ?? baseURL
    }

    /// The remote path of a multistatus `href`, or `nil` when it is outside the base collection.
    func remotePath(forHrefPath hrefPath: String) -> RemotePath? {
        RemotePath(hrefPath).relativeComponents(to: RemotePath(components: basePathComponents))
            .map { RemotePath(components: $0) }
    }

    // MARK: Requests

    func makeRequest(_ method: String, url: URL, headers: [String: String] = [:]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        // Basic credentials are sent up front over HTTPS so streamed uploads never need a second body.
        if !username.isEmpty, url.scheme?.lowercased() == "https" {
            let token = Data("\(username):\(password)".utf8).base64EncodedString()
            request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    /// Sends a request with an in-memory body. Transient failures are retried with backoff.
    @discardableResult
    func send(
        _ method: String,
        _ path: RemotePath,
        isCollection: Bool = false,
        headers: [String: String] = [:],
        body: Data? = nil,
        accept: Set<Int> = [],
        retries: Int = 2
    ) async throws -> (Data, HTTPURLResponse) {
        var request = makeRequest(method, url: url(for: path, isCollection: isCollection), headers: headers)
        request.httpBody = body
        var attempt = 0
        while true {
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw StorageError.invalidResponse("Not an HTTP response.")
                }
                guard (200..<300).contains(http.statusCode) || accept.contains(http.statusCode) else {
                    throw Self.error(status: http.statusCode, method: method, path: path)
                }
                return (data, http)
            } catch {
                let mapped = StorageError.wrapping(error)
                guard attempt < retries, (mapped as? StorageError)?.isTransient == true else { throw mapped }
                attempt += 1
                try await Task.sleep(for: .milliseconds(500 * (1 << attempt)))
            }
        }
    }

    static func error(status: Int, method: String, path: RemotePath) -> StorageError {
        switch status {
        case 401:
            return .authenticationFailed("The server rejected the username or password.")
        case 403:
            return .permissionDenied(path)
        case 404, 410:
            return .notFound(path)
        case 405 where method == "MKCOL":
            return .alreadyExists(path)
        case 409:
            return .notFound(path.parent ?? .root)
        case 412:
            return .alreadyExists(path)
        case 423:
            return .server(code: "423", message: "\(path) is locked.")
        case 507:
            return .server(code: "507", message: "The server has no storage space left.")
        case 500, 502, 503, 504:
            return .server(code: "ServiceUnavailable", message: HTTPURLResponse.localizedString(forStatusCode: status))
        default:
            return .server(code: "\(status)", message: HTTPURLResponse.localizedString(forStatusCode: status))
        }
    }
}

/// Answers Basic, Digest, and NTLM challenges once; a repeated challenge means the credentials are wrong.
private final class CredentialDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private let username: String
    private let password: String

    init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let method = challenge.protectionSpace.authenticationMethod
        guard [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest,
               NSURLAuthenticationMethodNTLM].contains(method) else {
            return (.performDefaultHandling, nil)
        }
        guard !username.isEmpty, challenge.previousFailureCount == 0 else {
            return (.rejectProtectionSpace, nil)
        }
        return (.useCredential, URLCredential(user: username, password: password, persistence: .forSession))
    }
}
