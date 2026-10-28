import Foundation

/// File helpers shared by providers for streaming transfers.
public enum LocalFile {
    public static func size(of url: URL) throws -> Int64 {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return (attributes[.size] as? NSNumber)?.int64Value ?? 0
        } catch {
            throw StorageError.localFile(error.localizedDescription)
        }
    }

    /// Opens `url` for appending, creating it when needed. Without `resume`, the file is truncated.
    /// Returns the handle positioned at the end and the existing length.
    public static func openForAppending(_ url: URL, resume: Bool) throws -> (FileHandle, Int64) {
        let manager = FileManager.default
        do {
            if !resume || !manager.fileExists(atPath: url.path) {
                try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                // A plain write: an atomic write would stage the file in a temporary directory first.
                try Data().write(to: url)
            }
            let handle = try FileHandle(forWritingTo: url)
            let offset = try handle.seekToEnd()
            return (handle, Int64(offset))
        } catch let error as StorageError {
            throw error
        } catch {
            throw StorageError.localFile(error.localizedDescription)
        }
    }

    /// Reads `length` bytes at `offset`.
    public static func read(_ url: URL, offset: Int64, length: Int) throws -> Data {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(offset))
            return try handle.read(upToCount: length) ?? Data()
        } catch {
            throw StorageError.localFile(error.localizedDescription)
        }
    }
}
