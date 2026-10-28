import Foundation
import NIOCore

/// SFTP protocol version 3 (draft-ietf-secsh-filexfer-02), the version OpenSSH implements.
enum SFTPPacketType: UInt8 {
    case initialize = 1
    case version = 2
    case open = 3
    case close = 4
    case read = 5
    case write = 6
    case lstat = 7
    case fstat = 8
    case setstat = 9
    case fsetstat = 10
    case opendir = 11
    case readdir = 12
    case remove = 13
    case mkdir = 14
    case rmdir = 15
    case realpath = 16
    case stat = 17
    case rename = 18
    case readlink = 19
    case symlink = 20
    case status = 101
    case handle = 102
    case data = 103
    case name = 104
    case attributes = 105
    case extended = 200
    case extendedReply = 201
}

struct SFTPOpenFlags: OptionSet, Sendable {
    let rawValue: UInt32

    static let read = SFTPOpenFlags(rawValue: 0x01)
    static let write = SFTPOpenFlags(rawValue: 0x02)
    static let append = SFTPOpenFlags(rawValue: 0x04)
    static let create = SFTPOpenFlags(rawValue: 0x08)
    static let truncate = SFTPOpenFlags(rawValue: 0x10)
    static let exclusive = SFTPOpenFlags(rawValue: 0x20)
}

enum SFTPStatusCode: UInt32, Sendable {
    case ok = 0
    case endOfFile = 1
    case noSuchFile = 2
    case permissionDenied = 3
    case failure = 4
    case badMessage = 5
    case noConnection = 6
    case connectionLost = 7
    case unsupported = 8
}

/// File attributes; absent fields are `nil`.
struct SFTPAttributes: Sendable, Equatable {
    var size: UInt64?
    var uid: UInt32?
    var gid: UInt32?
    var permissions: UInt32?
    var accessTime: UInt32?
    var modificationTime: UInt32?

    private enum Flag {
        static let size: UInt32 = 0x01
        static let uidGid: UInt32 = 0x02
        static let permissions: UInt32 = 0x04
        static let accessModificationTime: UInt32 = 0x08
        static let extended: UInt32 = 0x8000_0000
    }

    /// POSIX file type bits (`S_IFMT`).
    var isDirectory: Bool { permissions.map { $0 & 0o170000 == 0o040000 } ?? false }
    var isSymbolicLink: Bool { permissions.map { $0 & 0o170000 == 0o120000 } ?? false }

    static func read(from buffer: inout ByteBuffer) throws -> SFTPAttributes {
        let flags = try buffer.readSFTPInteger(as: UInt32.self)
        var attributes = SFTPAttributes()
        if flags & Flag.size != 0 {
            attributes.size = try buffer.readSFTPInteger(as: UInt64.self)
        }
        if flags & Flag.uidGid != 0 {
            attributes.uid = try buffer.readSFTPInteger(as: UInt32.self)
            attributes.gid = try buffer.readSFTPInteger(as: UInt32.self)
        }
        if flags & Flag.permissions != 0 {
            attributes.permissions = try buffer.readSFTPInteger(as: UInt32.self)
        }
        if flags & Flag.accessModificationTime != 0 {
            attributes.accessTime = try buffer.readSFTPInteger(as: UInt32.self)
            attributes.modificationTime = try buffer.readSFTPInteger(as: UInt32.self)
        }
        if flags & Flag.extended != 0 {
            let count = try buffer.readSFTPInteger(as: UInt32.self)
            for _ in 0..<count {
                _ = try buffer.readSFTPString()
                _ = try buffer.readSFTPString()
            }
        }
        return attributes
    }

    func write(to buffer: inout ByteBuffer) {
        var flags: UInt32 = 0
        if size != nil { flags |= Flag.size }
        if uid != nil, gid != nil { flags |= Flag.uidGid }
        if permissions != nil { flags |= Flag.permissions }
        if accessTime != nil, modificationTime != nil { flags |= Flag.accessModificationTime }
        buffer.writeInteger(flags)
        if let size { buffer.writeInteger(size) }
        if let uid, let gid {
            buffer.writeInteger(uid)
            buffer.writeInteger(gid)
        }
        if let permissions { buffer.writeInteger(permissions) }
        if let accessTime, let modificationTime {
            buffer.writeInteger(accessTime)
            buffer.writeInteger(modificationTime)
        }
    }
}

struct SFTPName: Sendable {
    var filename: String
    /// `ls -l` style line; the only place SFTP v3 exposes owner and group names.
    var longName: String
    var attributes: SFTPAttributes

    /// Owner and group names parsed from `longName` ("-rw-r--r-- 1 alice staff 42 …").
    var ownerAndGroup: (String, String)? {
        let fields = longName.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 4 else { return nil }
        return (String(fields[2]), String(fields[3]))
    }
}

/// A request body; the handler adds the length, type, and request ID.
struct SFTPRequest: Sendable {
    var type: SFTPPacketType
    var payload: ByteBuffer

    static func path(_ type: SFTPPacketType, _ path: String) -> SFTPRequest {
        var buffer = ByteBuffer()
        buffer.writeSFTPString(path)
        return SFTPRequest(type: type, payload: buffer)
    }

    static func handle(_ type: SFTPPacketType, _ handle: ByteBuffer) -> SFTPRequest {
        var buffer = ByteBuffer()
        buffer.writeSFTPString(handle)
        return SFTPRequest(type: type, payload: buffer)
    }
}

enum SFTPResponse: Sendable {
    case status(SFTPStatusCode?, code: UInt32, message: String)
    case handle(ByteBuffer)
    case data(ByteBuffer)
    case name([SFTPName])
    case attributes(SFTPAttributes)
    case extendedReply(ByteBuffer)

    static func read(type: UInt8, from buffer: inout ByteBuffer) throws -> SFTPResponse {
        switch SFTPPacketType(rawValue: type) {
        case .status:
            let code = try buffer.readSFTPInteger(as: UInt32.self)
            let message = buffer.readableBytes >= 4 ? (try? buffer.readSFTPString()) ?? "" : ""
            return .status(SFTPStatusCode(rawValue: code), code: code, message: message)
        case .handle:
            return .handle(try buffer.readSFTPBytes())
        case .data:
            return .data(try buffer.readSFTPBytes())
        case .name:
            let count = try buffer.readSFTPInteger(as: UInt32.self)
            var names: [SFTPName] = []
            names.reserveCapacity(Int(min(count, 4096)))
            for _ in 0..<count {
                let filename = try buffer.readSFTPString()
                let longName = try buffer.readSFTPString()
                names.append(SFTPName(filename: filename, longName: longName,
                                      attributes: try SFTPAttributes.read(from: &buffer)))
            }
            return .name(names)
        case .attributes:
            return .attributes(try SFTPAttributes.read(from: &buffer))
        case .extendedReply:
            return .extendedReply(buffer.readSlice(length: buffer.readableBytes) ?? ByteBuffer())
        default:
            throw SFTPProtocolError.unexpectedPacket(type)
        }
    }
}

enum SFTPProtocolError: Error, Sendable {
    case unexpectedPacket(UInt8)
    case truncatedPacket
    case unexpectedResponse
    case subsystemRejected
    case channelClosed
}

extension ByteBuffer {
    mutating func readSFTPInteger<T: FixedWidthInteger>(as type: T.Type) throws -> T {
        guard let value = readInteger(as: T.self) else { throw SFTPProtocolError.truncatedPacket }
        return value
    }

    mutating func readSFTPBytes() throws -> ByteBuffer {
        let length = try readSFTPInteger(as: UInt32.self)
        guard let slice = readSlice(length: Int(length)) else { throw SFTPProtocolError.truncatedPacket }
        return slice
    }

    mutating func readSFTPString() throws -> String {
        var bytes = try readSFTPBytes()
        return bytes.readString(length: bytes.readableBytes) ?? ""
    }

    mutating func writeSFTPString(_ string: String) {
        writeInteger(UInt32(string.utf8.count))
        writeString(string)
    }

    mutating func writeSFTPString(_ bytes: ByteBuffer) {
        writeInteger(UInt32(bytes.readableBytes))
        writeImmutableBuffer(bytes)
    }
}
