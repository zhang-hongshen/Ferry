import CryptoKit
import Foundation

/// AWS Signature Version 4 for S3, for both header-signed requests and presigned URLs.
struct S3Signer: Sendable {
    static let emptyPayloadHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    static let unsignedPayload = "UNSIGNED-PAYLOAD"
    private static let algorithm = "AWS4-HMAC-SHA256"
    private static let service = "s3"

    let accessKeyID: String
    let secretAccessKey: String
    let sessionToken: String?

    /// Adds `x-amz-date`, `x-amz-content-sha256`, and `Authorization` headers.
    /// Signs `host`, `content-type`, `content-md5`, `range`, and every `x-amz-*` header.
    func sign(_ request: inout URLRequest, region: String, payloadHash: String, date: Date = Date()) {
        let (amzDate, dateStamp) = Self.timestamps(for: date)
        request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
        if let sessionToken {
            request.setValue(sessionToken, forHTTPHeaderField: "x-amz-security-token")
        }
        guard let url = request.url else { return }

        var headers: [(String, String)] = [("host", Self.hostHeader(for: url))]
        for (name, value) in request.allHTTPHeaderFields ?? [:] {
            let lowercased = name.lowercased()
            if lowercased.hasPrefix("x-amz-") || ["content-type", "content-md5", "range"].contains(lowercased) {
                headers.append((lowercased, Self.normalizeHeaderValue(value)))
            }
        }
        headers.sort { $0.0 < $1.0 }
        let canonicalHeaders = headers.map { "\($0.0):\($0.1)\n" }.joined()
        let signedHeaders = headers.map(\.0).joined(separator: ";")

        let canonicalRequest = [
            request.httpMethod ?? "GET",
            Self.canonicalURI(for: url),
            Self.canonicalQuery(for: url),
            canonicalHeaders,
            signedHeaders,
            payloadHash,
        ].joined(separator: "\n")

        let scope = "\(dateStamp)/\(region)/\(Self.service)/aws4_request"
        let signature = signature(canonicalRequest: canonicalRequest, amzDate: amzDate, scope: scope,
                                  dateStamp: dateStamp, region: region)
        request.setValue(
            "\(Self.algorithm) Credential=\(accessKeyID)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)",
            forHTTPHeaderField: "Authorization"
        )
    }

    /// Returns `url` with query-string authentication valid for `expires` seconds.
    func presign(_ url: URL, method: String = "GET", region: String, expires: Int, date: Date = Date()) -> URL {
        let (amzDate, dateStamp) = Self.timestamps(for: date)
        let scope = "\(dateStamp)/\(region)/\(Self.service)/aws4_request"
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }

        var query = components.percentEncodedQuery.map { [$0] } ?? []
        query.append("X-Amz-Algorithm=\(Self.algorithm)")
        query.append("X-Amz-Credential=\(S3Encoding.encode("\(accessKeyID)/\(scope)"))")
        query.append("X-Amz-Date=\(amzDate)")
        query.append("X-Amz-Expires=\(expires)")
        if let sessionToken {
            query.append("X-Amz-Security-Token=\(S3Encoding.encode(sessionToken))")
        }
        query.append("X-Amz-SignedHeaders=host")
        components.percentEncodedQuery = query.joined(separator: "&")
        guard let unsignedURL = components.url else { return url }

        let canonicalRequest = [
            method,
            Self.canonicalURI(for: unsignedURL),
            Self.canonicalQuery(for: unsignedURL),
            "host:\(Self.hostHeader(for: unsignedURL))\n",
            "host",
            Self.unsignedPayload,
        ].joined(separator: "\n")
        let signature = signature(canonicalRequest: canonicalRequest, amzDate: amzDate, scope: scope,
                                  dateStamp: dateStamp, region: region)
        components.percentEncodedQuery = (components.percentEncodedQuery ?? "") + "&X-Amz-Signature=\(signature)"
        return components.url ?? url
    }

    private func signature(canonicalRequest: String, amzDate: String, scope: String, dateStamp: String,
                           region: String) -> String {
        let stringToSign = [
            Self.algorithm,
            amzDate,
            scope,
            Self.sha256Hex(Data(canonicalRequest.utf8)),
        ].joined(separator: "\n")

        var key = SymmetricKey(data: Data("AWS4\(secretAccessKey)".utf8))
        for component in [dateStamp, region, Self.service, "aws4_request"] {
            key = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(component.utf8), using: key)))
        }
        let code = HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: key)
        return Data(code).hexString
    }

    static func sha256Hex(_ data: Data) -> String {
        Data(SHA256.hash(data: data)).hexString
    }

    static func hostHeader(for url: URL) -> String {
        let host = url.host(percentEncoded: false) ?? ""
        return url.port.map { "\(host):\($0)" } ?? host
    }

    private static func canonicalURI(for url: URL) -> String {
        let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? ""
        return path.isEmpty ? "/" : path
    }

    /// Query items are already strictly encoded when the URL is built, so they only need sorting.
    private static func canonicalQuery(for url: URL) -> String {
        guard let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery,
              !query.isEmpty else { return "" }
        let pairs = query.split(separator: "&").map { item -> (String, String) in
            let parts = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            return (String(parts[0]), parts.count > 1 ? String(parts[1]) : "")
        }
        return pairs.sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
            .map { "\($0.0)=\($0.1)" }
            .joined(separator: "&")
    }

    private static func normalizeHeaderValue(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func timestamps(for date: Date) -> (amzDate: String, dateStamp: String) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let amzDate = formatter.string(from: date)
        return (amzDate, String(amzDate.prefix(8)))
    }
}

/// Strict URI encoding as required by SigV4: only unreserved characters stay literal.
enum S3Encoding {
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    static func encode(_ string: String) -> String {
        string.addingPercentEncoding(withAllowedCharacters: unreserved) ?? string
    }

    /// Encodes each segment of an object key, keeping "/" separators.
    static func encodeKey(_ key: String) -> String {
        key.split(separator: "/", omittingEmptySubsequences: false).map { encode(String($0)) }.joined(separator: "/")
    }
}

extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
