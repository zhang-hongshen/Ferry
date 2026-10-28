import Foundation
import StorageCore

/// A user-facing title and message for any error, with storage errors mapped to clear wording.
struct PresentableError: Identifiable, Error {
    enum Category {
        case network
        case authentication
        case permission
        case other
    }

    let id = UUID()
    let title: String
    let message: String
    let category: Category

    init(title: String, message: String, category: Category = .other) {
        self.title = title
        self.message = message
        self.category = category
    }

    init(_ error: any Error) {
        if let presentable = error as? PresentableError {
            self = presentable
            return
        }
        switch StorageError.wrapping(error) as? StorageError {
        case .network(let detail):
            self.init(title: String(localized: "Network Error"), message: detail, category: .network)
        case .connectionLost:
            self.init(title: String(localized: "Connection Lost"),
                      message: String(localized: "The connection to the server was lost."), category: .network)
        case .authenticationFailed(let detail):
            self.init(title: String(localized: "Authentication Failed"),
                      message: detail ?? String(localized: "Check the credentials of this connection."),
                      category: .authentication)
        case .permissionDenied(let path):
            self.init(title: String(localized: "Permission Denied"),
                      message: path.map { String(localized: "You don’t have permission to access \($0.string).") }
                          ?? String(localized: "You don’t have permission to perform this operation."),
                      category: .permission)
        case .notFound(let path):
            self.init(title: String(localized: "Not Found"),
                      message: String(localized: "\(path.string) doesn’t exist."))
        case .alreadyExists(let path):
            self.init(title: String(localized: "Already Exists"),
                      message: String(localized: "\(path.string) already exists."))
        case .directoryNotEmpty(let path):
            self.init(title: String(localized: "Not Empty"),
                      message: String(localized: "\(path.string) isn’t empty."))
        case .unsupported(let detail):
            self.init(title: String(localized: "Not Supported"), message: detail)
        case .invalidConfiguration(let detail):
            self.init(title: String(localized: "Invalid Settings"), message: detail)
        case .server(let code, let message):
            self.init(title: String(localized: "Server Error"), message: code.map { "\($0): \(message)" } ?? message)
        case .invalidResponse(let detail):
            self.init(title: String(localized: "Unexpected Response"), message: detail)
        case .localFile(let detail):
            self.init(title: String(localized: "File Error"), message: detail)
        case nil:
            self.init(title: String(localized: "Error"), message: error.localizedDescription)
        }
    }

    /// Errors after which reconnecting and retrying once is worthwhile.
    static func isConnectionFailure(_ error: any Error) -> Bool {
        switch StorageError.wrapping(error) as? StorageError {
        case .connectionLost, .network: true
        default: false
        }
    }
}
