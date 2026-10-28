import Foundation

/// A file, directory, link, or bucket on a remote storage, as returned by listings.
public struct RemoteItem: Identifiable, Hashable, Sendable, Codable {
    public enum Kind: String, Sendable, Codable {
        case file
        case directory
        case symbolicLink
        case bucket
    }

    public var path: RemotePath
    public var kind: Kind
    public var size: Int64?
    public var creationDate: Date?
    public var modificationDate: Date?
    /// POSIX mode bits (for example `0o755`), when the protocol exposes them.
    public var permissions: UInt16?
    public var owner: String?
    public var group: String?
    public var eTag: String?
    public var storageClass: String?
    public var symbolicLinkTarget: String?

    public init(
        path: RemotePath,
        kind: Kind,
        size: Int64? = nil,
        creationDate: Date? = nil,
        modificationDate: Date? = nil,
        permissions: UInt16? = nil,
        owner: String? = nil,
        group: String? = nil,
        eTag: String? = nil,
        storageClass: String? = nil,
        symbolicLinkTarget: String? = nil
    ) {
        self.path = path
        self.kind = kind
        self.size = size
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.permissions = permissions
        self.owner = owner
        self.group = group
        self.eTag = eTag
        self.storageClass = storageClass
        self.symbolicLinkTarget = symbolicLinkTarget
    }

    public var id: RemotePath { path }
    public var name: String { path.name }

    /// Whether the item can be listed like a directory.
    public var isContainer: Bool { kind == .directory || kind == .bucket }
}

/// Object metadata for protocols that support it (S3). Header-backed fields are editable.
public struct RemoteMetadata: Hashable, Sendable {
    public var contentType: String?
    public var cacheControl: String?
    public var contentDisposition: String?
    public var contentEncoding: String?
    public var eTag: String?
    public var storageClass: String?
    public var versionID: String?
    /// User-defined metadata without the protocol prefix (for S3, without `x-amz-meta-`).
    public var custom: [String: String]

    public init(
        contentType: String? = nil,
        cacheControl: String? = nil,
        contentDisposition: String? = nil,
        contentEncoding: String? = nil,
        eTag: String? = nil,
        storageClass: String? = nil,
        versionID: String? = nil,
        custom: [String: String] = [:]
    ) {
        self.contentType = contentType
        self.cacheControl = cacheControl
        self.contentDisposition = contentDisposition
        self.contentEncoding = contentEncoding
        self.eTag = eTag
        self.storageClass = storageClass
        self.versionID = versionID
        self.custom = custom
    }
}
