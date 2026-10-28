import Foundation
import NIOCore
import NIOEmbedded
import NIOSSH
import Testing
@testable import SFTPStorage
@testable import StorageCore

struct SSHPrivateKeyParserTests {
    @Test(arguments: [
        KeyFixtures.ed25519plain, KeyFixtures.ed25519enc, KeyFixtures.p256enc,
        KeyFixtures.p384plain, KeyFixtures.p521enc, KeyFixtures.p256pem,
    ])
    func derivesTheSamePublicKeyAsSSHKeygen(_ fixture: Fixture) throws {
        let key = try SSHPrivateKeyParser.parse(fixture.privateKey, passphrase: fixture.passphrase)
        #expect(String(openSSHPublicKey: key.publicKey) == fixture.publicKey)
    }

    @Test func rejectsWrongOrMissingPassphrase() {
        #expect(throws: SSHPrivateKeyParser.ParseError.wrongPassphrase) {
            try SSHPrivateKeyParser.parse(KeyFixtures.ed25519enc.privateKey, passphrase: "wrong")
        }
        #expect(throws: SSHPrivateKeyParser.ParseError.passphraseRequired) {
            try SSHPrivateKeyParser.parse(KeyFixtures.p256enc.privateKey, passphrase: nil)
        }
    }

    @Test func reportsRSAAsUnsupported() {
        #expect(throws: SSHPrivateKeyParser.ParseError.unsupportedKeyType("ssh-rsa")) {
            try SSHPrivateKeyParser.parse(KeyFixtures.rsaplain.privateKey, passphrase: nil)
        }
    }
}

struct SFTPMessageTests {
    @Test func roundTripsAttributes() throws {
        let attributes = SFTPAttributes(size: 1234, uid: 501, gid: 20, permissions: 0o100644,
                                        accessTime: 10, modificationTime: 20)
        var buffer = ByteBuffer()
        attributes.write(to: &buffer)
        #expect(try SFTPAttributes.read(from: &buffer) == attributes)
        #expect(!attributes.isDirectory)
    }

    @Test func mapsAttributesToItems() {
        let attributes = SFTPAttributes(size: 42, permissions: 0o040755, modificationTime: 0)
        let name = SFTPName(filename: "docs", longName: "drwxr-xr-x    2 alice    staff    64 Jan  1 00:00 docs",
                            attributes: attributes)
        let item = SFTPProvider.item(path: RemotePath("/home/docs"), attributes: attributes, owner: name.ownerAndGroup)
        #expect(item.kind == .directory)
        #expect(item.size == nil)
        #expect(item.permissions == 0o755)
        #expect(item.owner == "alice" && item.group == "staff")
        #expect(item.permissionsDescriptionForTest == "rwxr-xr-x")
    }
}

/// Drives the channel handler with an embedded channel: framing, request IDs, and partial packets.
struct SFTPChannelHandlerTests {
    @Test func framesRequestsAndMatchesResponses() throws {
        let channel = EmbeddedChannel(handler: SFTPChannelHandler())
        let first = channel.eventLoop.makePromise(of: SFTPResponse.self)
        let second = channel.eventLoop.makePromise(of: SFTPResponse.self)
        try channel.writeOutbound(SFTPOutbound.request(.path(.stat, "/a"), first))
        try channel.writeOutbound(SFTPOutbound.request(.path(.realpath, "."), second))

        var packet = try #require(try channel.readOutbound(as: SSHChannelData.self))
        guard case .byteBuffer(var bytes) = packet.data else { Issue.record("Not a buffer"); return }
        #expect(bytes.readInteger(as: UInt32.self) == UInt32(11))
        #expect(bytes.readInteger(as: UInt8.self) == SFTPPacketType.stat.rawValue)
        #expect(bytes.readInteger(as: UInt32.self) == 1)
        packet = try #require(try channel.readOutbound(as: SSHChannelData.self))

        // The response to request 2 arrives first and split across two reads.
        var reply = ByteBuffer()
        reply.writeInteger(UInt32(26)) // type, id, count, "/home", "", attribute flags
        reply.writeInteger(SFTPPacketType.name.rawValue)
        reply.writeInteger(UInt32(2))
        reply.writeInteger(UInt32(1))
        reply.writeSFTPString("/home")
        reply.writeSFTPString("")
        reply.writeInteger(UInt32(0))
        var status = ByteBuffer()
        status.writeInteger(UInt32(19)) // type, id, code, "no", ""
        status.writeInteger(SFTPPacketType.status.rawValue)
        status.writeInteger(UInt32(1))
        status.writeInteger(SFTPStatusCode.noSuchFile.rawValue)
        status.writeSFTPString("no")
        status.writeSFTPString("")
        var combined = reply
        combined.writeBuffer(&status)
        let head = combined.readSlice(length: 7)!
        try channel.writeInbound(SSHChannelData(type: .channel, data: .byteBuffer(head)))
        try channel.writeInbound(SSHChannelData(type: .channel, data: .byteBuffer(combined)))

        guard case .name(let names) = try second.futureResult.wait() else { Issue.record("Expected NAME"); return }
        #expect(names.map(\.filename) == ["/home"])
        guard case .status(let code, _, let message) = try first.futureResult.wait() else {
            Issue.record("Expected STATUS")
            return
        }
        #expect(code == .noSuchFile && message == "no")
        _ = try channel.finish()
    }

    @Test func failsPendingRequestsWhenTheChannelCloses() throws {
        let channel = EmbeddedChannel(handler: SFTPChannelHandler())
        let promise = channel.eventLoop.makePromise(of: SFTPResponse.self)
        try channel.writeOutbound(SFTPOutbound.request(.path(.stat, "/a"), promise))
        _ = try channel.finish(acceptAlreadyClosed: true)
        #expect(throws: (any Error).self) { try promise.futureResult.wait() }
        #expect(SFTPSession.map(SFTPProtocolError.channelClosed, path: nil) as? StorageError == .connectionLost)
    }

    @Test func formatsHostKeyFingerprints() throws {
        let key = try NIOSSHPublicKey(openSSHPublicKey: KeyFixtures.ed25519plain.publicKey)
        let hostKey = SFTPHostKey(host: "example.com", port: 22, key: key)
        #expect(hostKey.algorithm == "ssh-ed25519")
        #expect(hostKey.fingerprint.hasPrefix("SHA256:"))
        #expect(!hostKey.fingerprint.hasSuffix("="))
    }
}

private extension RemoteItem {
    var permissionsDescriptionForTest: String {
        guard let permissions else { return "" }
        return (0..<9).map { bit -> String in
            permissions & (UInt16(1) << UInt16(8 - bit)) != 0 ? ["r", "w", "x"][bit % 3] : "-"
        }.joined()
    }
}
