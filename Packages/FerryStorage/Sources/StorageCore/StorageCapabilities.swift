/// Optional features a provider supports. The UI shows or hides functionality based on these.
public struct StorageCapabilities: OptionSet, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Time-limited, credential-free download links.
    public static let presignedURLs = StorageCapabilities(rawValue: 1 << 0)
    /// Changing POSIX permissions (chmod).
    public static let permissions = StorageCapabilities(rawValue: 1 << 1)
    /// Listings include POSIX permissions and owner, so the UI shows those columns.
    public static let posixAttributes = StorageCapabilities(rawValue: 1 << 2)
    /// Copies happen on the server without transferring data through the client.
    public static let serverSideCopy = StorageCapabilities(rawValue: 1 << 3)
    /// Large uploads are split into parts uploaded concurrently.
    public static let multipartUpload = StorageCapabilities(rawValue: 1 << 4)
    /// Interrupted uploads continue where they stopped.
    public static let resumableUpload = StorageCapabilities(rawValue: 1 << 5)
    /// Interrupted downloads continue where they stopped.
    public static let resumableDownload = StorageCapabilities(rawValue: 1 << 6)
    /// The root lists buckets, which can be created and deleted.
    public static let buckets = StorageCapabilities(rawValue: 1 << 7)
    /// Object metadata (content type, custom metadata) can be read and edited.
    public static let metadataEditing = StorageCapabilities(rawValue: 1 << 8)
    /// Renames and moves are atomic on the server.
    public static let atomicMove = StorageCapabilities(rawValue: 1 << 9)
}
