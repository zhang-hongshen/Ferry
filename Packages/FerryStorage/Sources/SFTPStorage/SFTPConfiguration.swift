import CryptoKit
import Foundation
import NIOSSH

/// Connection settings for SFTP.
public struct SFTPConfiguration: Sendable {
    public enum Authentication: Sendable {
        case password(String)
        /// An OpenSSH or PEM private key, with its passphrase when it is encrypted.
        case privateKey(String, passphrase: String?)
    }

    public var host: String
    public var port: Int
    public var username: String
    public var authentication: Authentication
    /// Decides whether to trust the server's host key. Throw to reject it.
    public var validateHostKey: @Sendable (SFTPHostKey) async throws -> Void

    public init(
        host: String,
        port: Int = 22,
        username: String,
        authentication: Authentication,
        validateHostKey: @escaping @Sendable (SFTPHostKey) async throws -> Void
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.authentication = authentication
        self.validateHostKey = validateHostKey
    }
}

/// A server's host key, as shown to the user and stored for later verification.
public struct SFTPHostKey: Sendable, Hashable {
    public let host: String
    public let port: Int
    /// For example `ssh-ed25519`.
    public let algorithm: String
    /// The key in OpenSSH `authorized_keys` format.
    public let openSSHRepresentation: String

    /// `SHA256:` followed by the unpadded base64 digest, as printed by `ssh-keygen -l`.
    public var fingerprint: String {
        let blob = openSSHRepresentation.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        let digest = SHA256.hash(data: Data(base64Encoded: blob) ?? Data())
        return "SHA256:" + Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    init(host: String, port: Int, key: NIOSSHPublicKey) {
        self.host = host
        self.port = port
        openSSHRepresentation = String(openSSHPublicKey: key)
        algorithm = openSSHRepresentation.split(separator: " ").first.map(String.init) ?? ""
    }
}
