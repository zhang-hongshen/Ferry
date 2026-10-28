import Foundation
import StorageCore

/// Connection settings for WebDAV over HTTP or HTTPS.
public struct WebDAVConfiguration: Sendable {
    /// The collection the connection is rooted at, always ending in "/".
    public let baseURL: URL
    public var username: String
    public var password: String

    public init(url: String, username: String, password: String) throws {
        var text = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.hasSuffix("/") {
            text += "/"
        }
        guard let parsed = URL(string: text), let scheme = parsed.scheme?.lowercased(),
              scheme == "http" || scheme == "https", parsed.host() != nil else {
            throw StorageError.invalidConfiguration("Enter a WebDAV URL starting with https:// or http://.")
        }
        baseURL = parsed
        self.username = username
        self.password = password
    }
}
