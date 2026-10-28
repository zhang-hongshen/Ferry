import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import StorageCore
import Synchronization

/// One SSH connection with an SFTP channel, and the typed SFTP v3 operations.
final class SFTPSession: Sendable {
    let connection: any Channel
    let channel: any Channel
    let extensions: [String: String]

    private init(connection: any Channel, channel: any Channel, extensions: [String: String]) {
        self.connection = connection
        self.channel = channel
        self.extensions = extensions
    }

    var isActive: Bool { channel.isActive }

    /// Whether `posix-rename@openssh.com` is available, which renames over an existing file.
    var supportsPOSIXRename: Bool { extensions["posix-rename@openssh.com"] != nil }

    // MARK: Connecting

    static func connect(_ configuration: SFTPConfiguration,
                        offer: NIOSSHUserAuthenticationOffer.Offer) async throws -> SFTPSession {
        let diagnostics = ConnectionDiagnostics()
        let hostKeyDelegate = HostKeyDelegate(host: configuration.host, port: configuration.port,
                                              validate: configuration.validateHostKey, diagnostics: diagnostics)
        let bootstrap = ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connectTimeout(.seconds(15))
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let ssh = NIOSSHHandler(
                        role: .client(SSHClientConfiguration(
                            userAuthDelegate: UserAuthDelegate(username: configuration.username, offer: offer,
                                                               diagnostics: diagnostics),
                            serverAuthDelegate: hostKeyDelegate
                        )),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: nil
                    )
                    try channel.pipeline.syncOperations.addHandler(ssh)
                }
            }

        let connection: any Channel
        do {
            connection = try await bootstrap.connect(host: configuration.host, port: configuration.port).get()
        } catch {
            throw StorageError.network(String(describing: error))
        }

        do {
            let channel = try await openChannel(on: connection)
            let subsystem = channel.eventLoop.makePromise(of: Void.self)
            try await channel.writeAndFlush(SFTPOutbound.startSubsystem(subsystem))
            try await subsystem.futureResult.get()
            let version = channel.eventLoop.makePromise(of: SFTPServerVersion.self)
            try await channel.writeAndFlush(SFTPOutbound.initialize(version))
            let serverVersion = try await version.futureResult.get()
            guard serverVersion.version >= 3 else {
                throw StorageError.unsupported("The server speaks SFTP version \(serverVersion.version); version 3 is required.")
            }
            return SFTPSession(connection: connection, channel: channel, extensions: serverVersion.extensions)
        } catch {
            try? await connection.close()
            if let hostKeyError = diagnostics.hostKeyError.withLock({ $0 }) {
                throw hostKeyError
            }
            if diagnostics.authenticationRejected.withLock({ $0 }) {
                throw StorageError.authenticationFailed("The server rejected the username or credentials.")
            }
            if case SFTPProtocolError.subsystemRejected = error {
                throw StorageError.unsupported("The server does not provide the SFTP subsystem.")
            }
            throw Self.map(error, path: nil)
        }
    }

    /// Creates the session channel once authentication completes. Fails if the connection closes first.
    private static func openChannel(on connection: any Channel) async throws -> any Channel {
        let promise = connection.eventLoop.makePromise(of: (any Channel).self)
        connection.closeFuture.whenComplete { _ in
            promise.fail(SFTPProtocolError.channelClosed)
        }
        connection.eventLoop.execute {
            do {
                let ssh = try connection.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
                ssh.createChannel(promise, channelType: .session) { child, _ in
                    child.eventLoop.makeCompletedFuture {
                        try child.pipeline.syncOperations.addHandler(SFTPChannelHandler())
                    }
                }
            } catch {
                promise.fail(error)
            }
        }
        return try await promise.futureResult.get()
    }

    static func makeOffer(_ configuration: SFTPConfiguration) throws -> NIOSSHUserAuthenticationOffer.Offer {
        switch configuration.authentication {
        case .password(let password):
            return .password(.init(password: password))
        case .privateKey(let text, let passphrase):
            do {
                return .privateKey(.init(privateKey: try SSHPrivateKeyParser.parse(text, passphrase: passphrase)))
            } catch let error as SSHPrivateKeyParser.ParseError {
                throw error.storageError
            }
        }
    }

    func close() async {
        try? await channel.close()
        try? await connection.close()
    }

    // MARK: Requests

    func send(_ request: SFTPRequest) -> EventLoopFuture<SFTPResponse> {
        let promise = channel.eventLoop.makePromise(of: SFTPResponse.self)
        channel.writeAndFlush(SFTPOutbound.request(request, promise)).whenFailure { promise.fail($0) }
        return promise.futureResult
    }

    func request(_ request: SFTPRequest, path: String?) async throws -> SFTPResponse {
        do {
            return try await send(request).get()
        } catch {
            throw Self.map(error, path: path)
        }
    }

    /// Expects a status response; throws unless it is OK.
    func perform(_ request: SFTPRequest, path: String) async throws {
        try Self.checkStatus(await self.request(request, path: path), path: path)
    }

    static func checkStatus(_ response: SFTPResponse, path: String?) throws {
        guard case .status(let code, let raw, let message) = response else {
            throw StorageError.invalidResponse("Expected a status reply.")
        }
        guard code != .ok else { return }
        throw statusError(code, raw: raw, message: message, path: path)
    }

    static func statusError(_ code: SFTPStatusCode?, raw: UInt32, message: String, path: String?) -> StorageError {
        let remotePath = path.map { RemotePath($0) }
        switch code {
        case .noSuchFile: return .notFound(remotePath ?? .root)
        case .permissionDenied: return .permissionDenied(remotePath)
        case .noConnection, .connectionLost: return .connectionLost
        case .unsupported: return .unsupported(message.isEmpty ? "The server does not support this operation." : message)
        default: return .server(code: "SFTP \(raw)", message: message.isEmpty ? "The operation failed." : message)
        }
    }

    static func map(_ error: any Error, path: String?) -> any Error {
        switch error {
        case is StorageError, is CancellationError:
            return error
        case SFTPProtocolError.channelClosed, is ChannelError:
            return StorageError.connectionLost
        case let error as SFTPProtocolError:
            return StorageError.invalidResponse(String(describing: error))
        case let error as NIOSSHError:
            return StorageError.network(String(describing: error))
        case let error as IOError:
            return StorageError.network(error.description)
        default:
            return StorageError.wrapping(error)
        }
    }

    // MARK: Operations

    func realPath(_ path: String) async throws -> String {
        guard case .name(let names) = try await request(.path(.realpath, path), path: path),
              let name = names.first else {
            throw StorageError.invalidResponse("REALPATH returned no name.")
        }
        return name.filename
    }

    func attributes(_ path: String, followLinks: Bool = true) async throws -> SFTPAttributes {
        let response = try await request(.path(followLinks ? .stat : .lstat, path), path: path)
        if case .attributes(let attributes) = response {
            return attributes
        }
        try Self.checkStatus(response, path: path)
        throw StorageError.invalidResponse("STAT returned no attributes.")
    }

    func openDirectory(_ path: String) async throws -> ByteBuffer {
        try await handle(from: request(.path(.opendir, path), path: path), path: path)
    }

    /// The next batch of directory entries, or `nil` at the end.
    func readDirectory(_ handle: ByteBuffer, path: String) async throws -> [SFTPName]? {
        let response = try await request(.handle(.readdir, handle), path: path)
        switch response {
        case .name(let names):
            return names
        case .status(.endOfFile, _, _):
            return nil
        default:
            try Self.checkStatus(response, path: path)
            return nil
        }
    }

    func open(_ path: String, flags: SFTPOpenFlags, attributes: SFTPAttributes = SFTPAttributes()) async throws -> ByteBuffer {
        var payload = ByteBuffer()
        payload.writeSFTPString(path)
        payload.writeInteger(flags.rawValue)
        attributes.write(to: &payload)
        return try await handle(from: request(SFTPRequest(type: .open, payload: payload), path: path), path: path)
    }

    func close(_ handle: ByteBuffer) async {
        _ = try? await send(.handle(.close, handle)).get()
    }

    /// Starts a read; the future yields `nil` at end of file. Shorter reads than requested are possible.
    func read(_ handle: ByteBuffer, offset: UInt64, length: UInt32) -> EventLoopFuture<ByteBuffer?> {
        var payload = ByteBuffer()
        payload.writeSFTPString(handle)
        payload.writeInteger(offset)
        payload.writeInteger(length)
        return send(SFTPRequest(type: .read, payload: payload)).flatMapThrowing { response in
            switch response {
            case .data(let data): return data
            case .status(.endOfFile, _, _): return nil
            default:
                try Self.checkStatus(response, path: nil)
                throw StorageError.invalidResponse("READ returned no data.")
            }
        }
    }

    func write(_ handle: ByteBuffer, offset: UInt64, data: ByteBuffer) -> EventLoopFuture<Void> {
        var payload = ByteBuffer()
        payload.reserveCapacity(data.readableBytes + handle.readableBytes + 16)
        payload.writeSFTPString(handle)
        payload.writeInteger(offset)
        payload.writeSFTPString(data)
        return send(SFTPRequest(type: .write, payload: payload)).flatMapThrowing { response in
            try Self.checkStatus(response, path: nil)
        }
    }

    func makeDirectory(_ path: String) async throws {
        var payload = ByteBuffer()
        payload.writeSFTPString(path)
        SFTPAttributes().write(to: &payload)
        try await perform(SFTPRequest(type: .mkdir, payload: payload), path: path)
    }

    func removeFile(_ path: String) async throws {
        try await perform(.path(.remove, path), path: path)
    }

    func removeDirectory(_ path: String) async throws {
        try await perform(.path(.rmdir, path), path: path)
    }

    /// Renames, replacing an existing destination when the server supports POSIX rename.
    func rename(_ source: String, to destination: String) async throws {
        var payload = ByteBuffer()
        if supportsPOSIXRename {
            payload.writeSFTPString("posix-rename@openssh.com")
            payload.writeSFTPString(source)
            payload.writeSFTPString(destination)
            try await perform(SFTPRequest(type: .extended, payload: payload), path: source)
        } else {
            payload.writeSFTPString(source)
            payload.writeSFTPString(destination)
            try await perform(SFTPRequest(type: .rename, payload: payload), path: source)
        }
    }

    func setAttributes(_ attributes: SFTPAttributes, at path: String) async throws {
        var payload = ByteBuffer()
        payload.writeSFTPString(path)
        attributes.write(to: &payload)
        try await perform(SFTPRequest(type: .setstat, payload: payload), path: path)
    }

    private func handle(from response: SFTPResponse, path: String) throws -> ByteBuffer {
        if case .handle(let handle) = response {
            return handle
        }
        try Self.checkStatus(response, path: path)
        throw StorageError.invalidResponse("Expected a handle.")
    }
}

// MARK: Delegates

/// Failures recorded by the delegates, so they can be reported instead of a generic channel error.
private final class ConnectionDiagnostics: Sendable {
    let hostKeyError = Mutex<(any Error)?>(nil)
    let authenticationRejected = Mutex(false)
}

/// Offers the configured credential once; a second request means the server rejected it.
private final class UserAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private let offer: NIOSSHUserAuthenticationOffer.Offer
    private let diagnostics: ConnectionDiagnostics
    private var hasOffered = false

    init(username: String, offer: NIOSSHUserAuthenticationOffer.Offer, diagnostics: ConnectionDiagnostics) {
        self.username = username
        self.offer = offer
        self.diagnostics = diagnostics
    }

    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods,
                                nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        let isAccepted = switch offer {
        case .password: availableMethods.contains(.password)
        case .privateKey: availableMethods.contains(.publicKey)
        default: false
        }
        guard !hasOffered, isAccepted else {
            diagnostics.authenticationRejected.withLock { $0 = true }
            nextChallengePromise.succeed(nil)
            return
        }
        hasOffered = true
        nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(username: username, serviceName: "", offer: offer))
    }
}

/// Asks the configured validator, which may prompt the user, whether to trust the host key.
private final class HostKeyDelegate: NIOSSHClientServerAuthenticationDelegate, Sendable {
    private let host: String
    private let port: Int
    private let validate: @Sendable (SFTPHostKey) async throws -> Void
    private let diagnostics: ConnectionDiagnostics

    init(host: String, port: Int, validate: @escaping @Sendable (SFTPHostKey) async throws -> Void,
         diagnostics: ConnectionDiagnostics) {
        self.host = host
        self.port = port
        self.validate = validate
        self.diagnostics = diagnostics
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let key = SFTPHostKey(host: host, port: port, key: hostKey)
        let validate = validate
        let diagnostics = diagnostics
        validationCompletePromise.completeWithTask {
            do {
                try await validate(key)
            } catch {
                diagnostics.hostKeyError.withLock { $0 = error }
                throw error
            }
        }
    }
}
