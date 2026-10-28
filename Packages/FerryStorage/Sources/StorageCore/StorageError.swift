import Foundation

/// Errors every provider maps its protocol-specific failures onto.
public enum StorageError: Error, Sendable, Equatable {
    /// The server could not be reached or the connection dropped.
    case network(String)
    /// The connection was closed and needs to be re-established.
    case connectionLost
    case authenticationFailed(String?)
    case permissionDenied(RemotePath?)
    case notFound(RemotePath)
    case alreadyExists(RemotePath)
    case directoryNotEmpty(RemotePath)
    case unsupported(String)
    case invalidConfiguration(String)
    /// The server rejected the request with a protocol-level error.
    case server(code: String?, message: String)
    case invalidResponse(String)
    case localFile(String)

    /// Whether repeating the same operation may succeed.
    public var isTransient: Bool {
        switch self {
        case .network, .connectionLost:
            true
        case .server(let code, _):
            ["InternalError", "ServiceUnavailable", "SlowDown", "RequestTimeout"].contains(code ?? "")
        default:
            false
        }
    }
}

extension StorageError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .network(let detail): "Network error: \(detail)"
        case .connectionLost: "The connection was lost."
        case .authenticationFailed(let detail): detail ?? "Authentication failed."
        case .permissionDenied(let path): "Permission denied\(path.map { ": \($0)" } ?? "")."
        case .notFound(let path): "\(path) was not found."
        case .alreadyExists(let path): "\(path) already exists."
        case .directoryNotEmpty(let path): "\(path) is not empty."
        case .unsupported(let detail): detail
        case .invalidConfiguration(let detail): detail
        case .server(let code, let message): code.map { "\($0): \(message)" } ?? message
        case .invalidResponse(let detail): "Unexpected server response: \(detail)"
        case .localFile(let detail): detail
        }
    }
}

extension StorageError {
    /// Maps `URLError` and other Foundation errors onto storage errors. Cancellation is preserved.
    public static func wrapping(_ error: any Error) -> any Error {
        if error is StorageError || error is CancellationError {
            return error
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled:
                return CancellationError()
            case .networkConnectionLost:
                return StorageError.connectionLost
            case .userAuthenticationRequired:
                return StorageError.authenticationFailed(nil)
            case .appTransportSecurityRequiresSecureConnection:
                return StorageError.invalidConfiguration(
                    "Plain HTTP is only allowed for local network hosts. Turn on HTTPS.")
            case .noPermissionsToReadFile, .cannotOpenFile, .cannotCreateFile, .cannotWriteToFile, .fileDoesNotExist:
                return StorageError.localFile(urlError.localizedDescription)
            default:
                return StorageError.network(urlError.localizedDescription)
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            return StorageError.localFile(nsError.localizedDescription)
        }
        return error
    }
}
