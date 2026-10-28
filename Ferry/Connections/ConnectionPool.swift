import Foundation
import Observation
import S3Storage
import SFTPStorage
import StorageCore
import WebDAVStorage

/// Creates providers from profiles and keeps one live provider per connection.
@Observable
final class ConnectionPool {
    @ObservationIgnored private var providers: [UUID: any StorageProvider] = [:]
    /// Bucket names per S3 connection, shown under the connection in the sidebar.
    private(set) var buckets: [UUID: [String]] = [:]
    private(set) var bucketErrors: [UUID: String] = [:]
    let knownHosts: KnownHostsStore

    init(knownHosts: KnownHostsStore = KnownHostsStore()) {
        self.knownHosts = knownHosts
    }

    func makeProvider(for profile: ConnectionProfile, secrets: ConnectionSecrets) throws -> any StorageProvider {
        switch profile.kind {
        case .s3:
            return try S3Provider(configuration: S3Configuration(
                endpoint: profile.s3.endpoint,
                region: profile.s3.region.trimmingCharacters(in: .whitespaces),
                useHTTPS: profile.s3.useHTTPS,
                usePathStyle: profile.s3.usePathStyle,
                accessKeyID: profile.s3.accessKeyID.trimmingCharacters(in: .whitespaces),
                secretAccessKey: secrets.secretKey
            ))
        case .sftp:
            let settings = profile.sftp
            let authentication: SFTPConfiguration.Authentication = switch settings.authentication {
            case .password: .password(secrets.password)
            case .privateKey: .privateKey(secrets.privateKey, passphrase: secrets.passphrase.isEmpty ? nil : secrets.passphrase)
            }
            let knownHosts = knownHosts
            return try SFTPProvider(configuration: SFTPConfiguration(
                host: settings.host.trimmingCharacters(in: .whitespaces),
                port: settings.port,
                username: settings.username.trimmingCharacters(in: .whitespaces),
                authentication: authentication,
                validateHostKey: { key in try await knownHosts.validate(key) }
            ))
        case .webDAV:
            return WebDAVProvider(configuration: try WebDAVConfiguration(
                url: profile.webDAV.url,
                username: profile.webDAV.username.trimmingCharacters(in: .whitespaces),
                password: secrets.password
            ))
        case .ftp, .smb:
            throw StorageError.unsupported(String(localized: "\(profile.kind.title) connections are not available yet."))
        }
    }

    func provider(for profile: ConnectionProfile) throws -> any StorageProvider {
        if let provider = providers[profile.id] {
            return provider
        }
        let provider = try makeProvider(for: profile, secrets: try KeychainStore.secrets(for: profile.id))
        providers[profile.id] = provider
        return provider
    }

    /// Drops the cached provider, for example after the profile was edited.
    func invalidate(_ id: UUID) {
        guard let provider = providers.removeValue(forKey: id) else { return }
        buckets[id] = nil
        Task { await provider.disconnect() }
    }

    /// Replaces the provider with a freshly connected one after the connection dropped.
    func reconnect(_ profile: ConnectionProfile) async throws -> any StorageProvider {
        invalidate(profile.id)
        let provider = try provider(for: profile)
        try await provider.connect()
        return provider
    }

    func loadBuckets(for profile: ConnectionProfile) async {
        do {
            let provider = try provider(for: profile)
            guard provider.capabilities.contains(.buckets) else { return }
            let items = try await provider.listAll(.root)
            buckets[profile.id] = items.map(\.name).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            bucketErrors[profile.id] = nil
        } catch {
            bucketErrors[profile.id] = PresentableError(error).message
        }
    }
}
