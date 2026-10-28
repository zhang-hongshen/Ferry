import Foundation

enum AppDirectories {
    /// The app's Application Support folder (inside the sandbox container).
    static var applicationSupport: URL {
        URL.applicationSupportDirectory.appending(path: "Ferry", directoryHint: .isDirectory)
    }

    /// Local copies used for previews, Quick Look, and cross-connection transfers.
    static var caches: URL {
        URL.cachesDirectory.appending(path: "Ferry", directoryHint: .isDirectory)
    }
}
