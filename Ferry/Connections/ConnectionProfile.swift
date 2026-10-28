import Foundation
import StorageCore

enum ConnectionKind: String, Codable, CaseIterable, Identifiable {
    case s3
    case sftp
    case ftp
    case webDAV = "webdav"
    case smb

    var id: String { rawValue }

    var title: String {
        switch self {
        case .s3: "S3"
        case .sftp: "SFTP"
        case .ftp: "FTP / FTPS"
        case .webDAV: "WebDAV"
        case .smb: "SMB"
        }
    }

    var systemImage: String {
        switch self {
        case .s3: "shippingbox"
        case .sftp: "lock.shield"
        case .ftp: "server.rack"
        case .webDAV: "globe"
        case .smb: "externaldrive.connected.to.line.below"
        }
    }
}

enum SFTPAuthentication: String, Codable, CaseIterable, Identifiable {
    case password
    case privateKey

    var id: String { rawValue }
}

enum FTPEncryption: String, Codable, CaseIterable, Identifiable {
    case none
    case explicitTLS
    case implicitTLS

    var id: String { rawValue }
}

enum FTPTransferMode: String, Codable, CaseIterable, Identifiable {
    case passive
    case active

    var id: String { rawValue }
}

struct S3Settings: Codable, Hashable {
    var endpoint = ""
    var region = "us-east-1"
    var useHTTPS = true
    var usePathStyle = false
    var accessKeyID = ""
}

struct SFTPSettings: Codable, Hashable {
    var host = ""
    var port = 22
    var username = ""
    var authentication = SFTPAuthentication.password
    /// File name of the imported private key, for display. The key itself lives in the Keychain.
    var privateKeyName = ""
}

struct FTPSettings: Codable, Hashable {
    var host = ""
    var port = 21
    var username = ""
    var encryption = FTPEncryption.none
    var mode = FTPTransferMode.passive
}

struct WebDAVSettings: Codable, Hashable {
    var url = ""
    var username = ""
}

struct SMBSettings: Codable, Hashable {
    var server = ""
    var share = ""
    var username = ""
    var domain = ""
}

/// A saved connection. Secrets are not part of the profile; they are stored in the Keychain.
struct ConnectionProfile: Identifiable, Hashable {
    var id = UUID()
    var name = ""
    var kind: ConnectionKind
    var group = ""
    var isFavorite = false
    var initialPath = ""
    var s3 = S3Settings()
    var sftp = SFTPSettings()
    var ftp = FTPSettings()
    var webDAV = WebDAVSettings()
    var smb = SMBSettings()

    var initialRemotePath: RemotePath { RemotePath(initialPath) }

    /// The name shown in the sidebar, falling back to the host.
    var displayName: String {
        if !name.trimmingCharacters(in: .whitespaces).isEmpty {
            return name
        }
        let host = switch kind {
        case .s3: s3.endpoint.isEmpty ? "Amazon S3" : s3.endpoint
        case .sftp: sftp.host
        case .ftp: ftp.host
        case .webDAV: webDAV.url
        case .smb: smb.share.isEmpty ? smb.server : "\(smb.server)/\(smb.share)"
        }
        return host.isEmpty ? kind.title : host
    }
}

extension ConnectionProfile: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, kind, group, isFavorite, initialPath, settings
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        kind = try container.decode(ConnectionKind.self, forKey: .kind)
        group = try container.decodeIfPresent(String.self, forKey: .group) ?? ""
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        initialPath = try container.decodeIfPresent(String.self, forKey: .initialPath) ?? ""
        switch kind {
        case .s3: s3 = try container.decode(S3Settings.self, forKey: .settings)
        case .sftp: sftp = try container.decode(SFTPSettings.self, forKey: .settings)
        case .ftp: ftp = try container.decode(FTPSettings.self, forKey: .settings)
        case .webDAV: webDAV = try container.decode(WebDAVSettings.self, forKey: .settings)
        case .smb: smb = try container.decode(SMBSettings.self, forKey: .settings)
        }
    }

    /// Encodes only the settings of the active protocol.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(kind, forKey: .kind)
        try container.encode(group, forKey: .group)
        try container.encode(isFavorite, forKey: .isFavorite)
        try container.encode(initialPath, forKey: .initialPath)
        switch kind {
        case .s3: try container.encode(s3, forKey: .settings)
        case .sftp: try container.encode(sftp, forKey: .settings)
        case .ftp: try container.encode(ftp, forKey: .settings)
        case .webDAV: try container.encode(webDAV, forKey: .settings)
        case .smb: try container.encode(smb, forKey: .settings)
        }
    }
}

/// Credentials of one connection, held only in memory and in the Keychain.
struct ConnectionSecrets: Hashable {
    var password = ""
    var secretKey = ""
    var privateKey = ""
    var passphrase = ""
}
