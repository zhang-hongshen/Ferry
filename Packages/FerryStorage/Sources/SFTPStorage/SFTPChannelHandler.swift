import NIOCore
import NIOSSH

/// Messages written into the SFTP child channel.
enum SFTPOutbound: Sendable {
    /// Requests the `sftp` subsystem and waits for the server's reply.
    case startSubsystem(EventLoopPromise<Void>)
    /// Sends `SSH_FXP_INIT` and returns the server's version and extensions.
    case initialize(EventLoopPromise<SFTPServerVersion>)
    case request(SFTPRequest, EventLoopPromise<SFTPResponse>)
}

struct SFTPServerVersion: Sendable {
    var version: UInt32
    var extensions: [String: String]
}

/// Frames SFTP packets over an SSH session channel and matches responses to requests by ID.
final class SFTPChannelHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = Never
    typealias OutboundIn = SFTPOutbound
    typealias OutboundOut = SSHChannelData

    private var inbound = ByteBuffer()
    private var nextRequestID: UInt32 = 1
    private var pending: [UInt32: EventLoopPromise<SFTPResponse>] = [:]
    private var versionPromise: EventLoopPromise<SFTPServerVersion>?
    private var subsystemPromise: EventLoopPromise<Void>?

    func handlerAdded(context: ChannelHandlerContext) {
        inbound = context.channel.allocator.buffer(capacity: 64 * 1024)
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        switch unwrapOutboundIn(data) {
        case .startSubsystem(let reply):
            subsystemPromise = reply
            let request = SSHChannelRequestEvent.SubsystemRequest(subsystem: "sftp", wantReply: true)
            context.triggerUserOutboundEvent(request, promise: nil)
            promise?.succeed(())

        case .initialize(let reply):
            versionPromise = reply
            var packet = context.channel.allocator.buffer(capacity: 9)
            packet.writeInteger(UInt32(5))
            packet.writeInteger(SFTPPacketType.initialize.rawValue)
            packet.writeInteger(UInt32(3))
            context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(packet))), promise: promise)

        case .request(let request, let reply):
            let id = nextRequestID
            nextRequestID &+= 1
            pending[id] = reply
            var packet = context.channel.allocator.buffer(capacity: 9 + request.payload.readableBytes)
            packet.writeInteger(UInt32(5 + request.payload.readableBytes))
            packet.writeInteger(request.type.rawValue)
            packet.writeInteger(id)
            packet.writeImmutableBuffer(request.payload)
            context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(packet))), promise: promise)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard message.type == .channel, case .byteBuffer(var bytes) = message.data else { return }
        inbound.writeBuffer(&bytes)
        do {
            try processPackets()
        } catch {
            failAll(error)
            context.close(promise: nil)
        }
    }

    private func processPackets() throws {
        while let length = inbound.getInteger(at: inbound.readerIndex, as: UInt32.self),
              inbound.readableBytes >= 4 + Int(length) {
            inbound.moveReaderIndex(forwardBy: 4)
            guard var packet = inbound.readSlice(length: Int(length)) else { throw SFTPProtocolError.truncatedPacket }
            let type = try packet.readSFTPInteger(as: UInt8.self)
            if type == SFTPPacketType.version.rawValue {
                let version = try packet.readSFTPInteger(as: UInt32.self)
                var extensions: [String: String] = [:]
                while packet.readableBytes > 0 {
                    extensions[try packet.readSFTPString()] = try packet.readSFTPString()
                }
                versionPromise?.succeed(SFTPServerVersion(version: version, extensions: extensions))
                versionPromise = nil
                continue
            }
            let id = try packet.readSFTPInteger(as: UInt32.self)
            let response = try SFTPResponse.read(type: type, from: &packet)
            pending.removeValue(forKey: id)?.succeed(response)
        }
        inbound.discardReadBytes()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelSuccessEvent:
            subsystemPromise?.succeed(())
            subsystemPromise = nil
        case is ChannelFailureEvent:
            subsystemPromise?.fail(SFTPProtocolError.subsystemRejected)
            subsystemPromise = nil
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        failAll(SFTPProtocolError.channelClosed)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        failAll(error)
        context.close(promise: nil)
    }

    private func failAll(_ error: any Error) {
        let promises = pending.values
        pending.removeAll()
        promises.forEach { $0.fail(error) }
        versionPromise?.fail(error)
        versionPromise = nil
        subsystemPromise?.fail(error)
        subsystemPromise = nil
    }
}
