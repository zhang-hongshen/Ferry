import Foundation

/// An absolute, normalized, slash-separated path on a remote storage.
///
/// Every provider uses the same shape. Object stores map their key space onto it:
/// for S3 the first component is the bucket and the rest is the key split on "/".
public struct RemotePath: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let components: [String]

    public static let root = RemotePath(components: [])

    public init(components: [String]) {
        var normalized: [String] = []
        for component in components {
            switch component {
            case "", ".":
                continue
            case "..":
                _ = normalized.popLast()
            default:
                normalized.append(component)
            }
        }
        self.components = normalized
    }

    /// Parses a slash-separated string. Relative strings are treated as relative to the root.
    public init(_ string: String) {
        self.init(components: string.split(separator: "/", omittingEmptySubsequences: true).map(String.init))
    }

    public var isRoot: Bool { components.isEmpty }

    public var name: String { components.last ?? "/" }

    public var parent: RemotePath? {
        isRoot ? nil : RemotePath(components: Array(components.dropLast()))
    }

    /// The path string, always starting with "/".
    public var string: String { "/" + components.joined(separator: "/") }

    public var description: String { string }

    /// Every path from the root down to and including this one.
    public var ancestors: [RemotePath] {
        (0...components.count).map { RemotePath(components: Array(components.prefix($0))) }
    }

    /// Appends a name or a relative path such as "a/b".
    public func appending(_ relativePath: String) -> RemotePath {
        RemotePath(components: components + relativePath.split(separator: "/").map(String.init))
    }

    public func appending(components other: [String]) -> RemotePath {
        RemotePath(components: components + other)
    }

    public func hasPrefix(_ other: RemotePath) -> Bool {
        components.starts(with: other.components)
    }

    /// The components of this path below `base`, or `nil` when it is not inside `base`.
    public func relativeComponents(to base: RemotePath) -> [String]? {
        hasPrefix(base) ? Array(components.dropFirst(base.components.count)) : nil
    }

    public static func < (lhs: RemotePath, rhs: RemotePath) -> Bool {
        lhs.string < rhs.string
    }
}

extension RemotePath: Codable {
    public init(from decoder: Decoder) throws {
        self.init(try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(string)
    }
}
