import Foundation
import StorageCore

/// Connection settings for AWS S3 and S3-compatible services such as MinIO, R2, or OSS.
public struct S3Configuration: Sendable, Hashable {
    /// Host with optional port, for example `localhost:9000`. Empty means AWS S3.
    public var endpoint: String
    public var region: String
    public var useHTTPS: Bool
    /// Address buckets as `host/bucket` instead of `bucket.host`.
    public var usePathStyle: Bool
    public var accessKeyID: String
    public var secretAccessKey: String
    public var sessionToken: String?

    public init(
        endpoint: String,
        region: String,
        useHTTPS: Bool = true,
        usePathStyle: Bool = false,
        accessKeyID: String,
        secretAccessKey: String,
        sessionToken: String? = nil
    ) {
        self.endpoint = endpoint
        self.region = region
        self.useHTTPS = useHTTPS
        self.usePathStyle = usePathStyle
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
        self.sessionToken = sessionToken
    }
}

/// The parsed endpoint host and port.
struct S3Endpoint: Sendable, Hashable {
    var scheme: String
    var host: String?
    var port: Int?
    var isAWS: Bool

    init(configuration: S3Configuration) throws {
        scheme = configuration.useHTTPS ? "https" : "http"
        var text = configuration.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = text.range(of: "://") {
            text = String(text[range.upperBound...])
        }
        text = text.split(separator: "/").first.map(String.init) ?? ""
        guard !text.isEmpty else {
            host = nil
            port = nil
            isAWS = true
            return
        }
        guard let components = URLComponents(string: "\(scheme)://\(text)"), let parsedHost = components.host,
              !parsedHost.isEmpty else {
            throw StorageError.invalidConfiguration("The endpoint \(configuration.endpoint) is not a valid host.")
        }
        host = parsedHost.lowercased()
        let defaultPort = configuration.useHTTPS ? 443 : 80
        port = components.port == defaultPort ? nil : components.port
        isAWS = parsedHost.hasSuffix("amazonaws.com")
    }

    func host(forRegion region: String) -> String {
        if let host {
            return host
        }
        return region == "us-east-1" ? "s3.amazonaws.com" : "s3.\(region).amazonaws.com"
    }
}
