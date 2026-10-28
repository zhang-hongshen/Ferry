import CommonCrypto
import CryptoKit
import Foundation
import NIOSSH
import StorageCore

/// Reads OpenSSH private keys (`BEGIN OPENSSH PRIVATE KEY`, optionally passphrase-protected) and
/// PEM/PKCS#8 EC keys. Supports the key types NIOSSH can sign with: Ed25519 and ECDSA P-256/384/521.
enum SSHPrivateKeyParser {
    enum ParseError: Error, Equatable {
        case unrecognizedFormat
        case passphraseRequired
        case wrongPassphrase
        case unsupportedKeyType(String)
        case unsupportedCipher(String)
        case malformed
    }

    static func parse(_ text: String, passphrase: String?) throws -> NIOSSHPrivateKey {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("BEGIN OPENSSH PRIVATE KEY") {
            return try parseOpenSSH(trimmed, passphrase: passphrase)
        }
        if trimmed.contains("BEGIN RSA PRIVATE KEY") {
            throw ParseError.unsupportedKeyType("ssh-rsa")
        }
        if trimmed.contains("ENCRYPTED") {
            throw ParseError.unsupportedCipher("PEM encryption")
        }
        if let key = try? P256.Signing.PrivateKey(pemRepresentation: trimmed) {
            return NIOSSHPrivateKey(p256Key: key)
        }
        if let key = try? P384.Signing.PrivateKey(pemRepresentation: trimmed) {
            return NIOSSHPrivateKey(p384Key: key)
        }
        if let key = try? P521.Signing.PrivateKey(pemRepresentation: trimmed) {
            return NIOSSHPrivateKey(p521Key: key)
        }
        if trimmed.contains("BEGIN EC PRIVATE KEY") {
            return try parseSEC1(trimmed)
        }
        throw ParseError.unrecognizedFormat
    }

    /// `ssh-keygen -m PEM` writes SEC1 keys with explicit curve parameters, which CryptoKit rejects.
    /// The private scalar is the OCTET STRING after the version: SEQUENCE { INTEGER 1, OCTET STRING d, … }.
    private static func parseSEC1(_ pem: String) throws -> NIOSSHPrivateKey {
        let base64 = pem.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("-----") }.joined()
        guard let der = Data(base64Encoded: base64) else { throw ParseError.malformed }
        var reader = DERReader([UInt8](der))
        var sequence = DERReader(try reader.read(tag: 0x30))
        _ = try sequence.read(tag: 0x02)
        let scalar = Data(try sequence.read(tag: 0x04))
        switch scalar.count {
        case 32: return NIOSSHPrivateKey(p256Key: try P256.Signing.PrivateKey(rawRepresentation: scalar))
        case 48: return NIOSSHPrivateKey(p384Key: try P384.Signing.PrivateKey(rawRepresentation: scalar))
        case 66: return NIOSSHPrivateKey(p521Key: try P521.Signing.PrivateKey(rawRepresentation: scalar))
        default: throw ParseError.malformed
        }
    }

    // MARK: openssh-key-v1

    private static func parseOpenSSH(_ text: String, passphrase: String?) throws -> NIOSSHPrivateKey {
        let base64 = text.split(whereSeparator: \.isNewline)
            .filter { !$0.hasPrefix("-----") }
            .joined()
        guard let data = Data(base64Encoded: base64) else { throw ParseError.malformed }
        var reader = SSHWireReader(data)
        let magic = Data("openssh-key-v1\0".utf8)
        guard try reader.readBytes(magic.count) == magic else { throw ParseError.unrecognizedFormat }
        let cipher = try reader.readString()
        let kdf = try reader.readString()
        var kdfOptions = SSHWireReader(try reader.readData())
        guard try reader.readUInt32() == 1 else { throw ParseError.malformed }
        _ = try reader.readData()
        var privateSection = try reader.readData()

        if cipher != "none" {
            guard let passphrase, !passphrase.isEmpty else { throw ParseError.passphraseRequired }
            guard kdf == "bcrypt" else { throw ParseError.unsupportedCipher(kdf) }
            let salt = try kdfOptions.readData()
            let rounds = Int(try kdfOptions.readUInt32())
            privateSection = try decrypt(privateSection, cipher: cipher, passphrase: passphrase, salt: salt,
                                         rounds: rounds)
        }

        var section = SSHWireReader(privateSection)
        let check1 = try section.readUInt32()
        let check2 = try section.readUInt32()
        guard check1 == check2 else {
            throw cipher == "none" ? ParseError.malformed : ParseError.wrongPassphrase
        }
        let type = try section.readString()
        switch type {
        case "ssh-ed25519":
            _ = try section.readData()
            let secret = try section.readData()
            guard secret.count == 64 else { throw ParseError.malformed }
            return NIOSSHPrivateKey(ed25519Key: try Curve25519.Signing.PrivateKey(rawRepresentation: secret.prefix(32)))
        case "ecdsa-sha2-nistp256":
            _ = try section.readString()
            _ = try section.readData()
            let scalar = try fixedLength(section.readData(), 32)
            return NIOSSHPrivateKey(p256Key: try P256.Signing.PrivateKey(rawRepresentation: scalar))
        case "ecdsa-sha2-nistp384":
            _ = try section.readString()
            _ = try section.readData()
            let scalar = try fixedLength(section.readData(), 48)
            return NIOSSHPrivateKey(p384Key: try P384.Signing.PrivateKey(rawRepresentation: scalar))
        case "ecdsa-sha2-nistp521":
            _ = try section.readString()
            _ = try section.readData()
            let scalar = try fixedLength(section.readData(), 66)
            return NIOSSHPrivateKey(p521Key: try P521.Signing.PrivateKey(rawRepresentation: scalar))
        default:
            throw ParseError.unsupportedKeyType(type)
        }
    }

    /// Strips the sign byte of an SSH mpint and left-pads it to the curve size.
    private static func fixedLength(_ mpint: Data, _ length: Int) throws -> Data {
        var bytes = mpint.drop { $0 == 0 }
        guard bytes.count <= length else { throw ParseError.malformed }
        bytes = Data(repeating: 0, count: length - bytes.count) + bytes
        return Data(bytes)
    }

    private static func decrypt(_ data: Data, cipher: String, passphrase: String, salt: Data,
                                rounds: Int) throws -> Data {
        let mode: CCMode
        let keyLength: Int
        switch cipher {
        case "aes256-ctr": (mode, keyLength) = (CCMode(kCCModeCTR), 32)
        case "aes192-ctr": (mode, keyLength) = (CCMode(kCCModeCTR), 24)
        case "aes128-ctr": (mode, keyLength) = (CCMode(kCCModeCTR), 16)
        case "aes256-cbc": (mode, keyLength) = (CCMode(kCCModeCBC), 32)
        case "aes128-cbc": (mode, keyLength) = (CCMode(kCCModeCBC), 16)
        default: throw ParseError.unsupportedCipher(cipher)
        }
        let derived = BCryptPBKDF.deriveKey(password: Data(passphrase.utf8), salt: salt, rounds: rounds,
                                            length: keyLength + kCCBlockSizeAES128)
        let key = [UInt8](derived.prefix(keyLength))
        let iv = [UInt8](derived.suffix(kCCBlockSizeAES128))
        guard data.count % kCCBlockSizeAES128 == 0 else { throw ParseError.malformed }

        var cryptor: CCCryptorRef?
        let options = mode == CCMode(kCCModeCTR) ? CCModeOptions(kCCModeOptionCTR_BE) : 0
        var status = CCCryptorCreateWithMode(CCOperation(kCCDecrypt), mode, CCAlgorithm(kCCAlgorithmAES),
                                             CCPadding(ccNoPadding), iv, key, key.count, nil, 0, 0, options,
                                             &cryptor)
        guard status == kCCSuccess, let cryptor else { throw ParseError.malformed }
        defer { CCCryptorRelease(cryptor) }
        var output = [UInt8](repeating: 0, count: data.count)
        var moved = 0
        status = data.withUnsafeBytes { input in
            CCCryptorUpdate(cryptor, input.baseAddress, data.count, &output, output.count, &moved)
        }
        guard status == kCCSuccess else { throw ParseError.malformed }
        return Data(output.prefix(moved))
    }
}

extension SSHPrivateKeyParser.ParseError {
    var storageError: StorageError {
        switch self {
        case .passphraseRequired:
            .authenticationFailed("The private key is protected by a passphrase.")
        case .wrongPassphrase:
            .authenticationFailed("The private key passphrase is incorrect.")
        case .unsupportedKeyType(let type):
            .invalidConfiguration("\(type) keys are not supported. Use an Ed25519 or ECDSA key.")
        case .unsupportedCipher(let cipher):
            .invalidConfiguration("Private keys encrypted with \(cipher) are not supported.")
        case .unrecognizedFormat, .malformed:
            .invalidConfiguration("The private key could not be read.")
        }
    }
}

/// Reads definite-length DER elements.
struct DERReader {
    private let bytes: [UInt8]
    private var offset = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    mutating func read(tag: UInt8) throws -> [UInt8] {
        guard offset + 2 <= bytes.count, bytes[offset] == tag else { throw SSHPrivateKeyParser.ParseError.malformed }
        var length = Int(bytes[offset + 1])
        offset += 2
        if length & 0x80 != 0 {
            let count = length & 0x7F
            guard count <= 3, offset + count <= bytes.count else { throw SSHPrivateKeyParser.ParseError.malformed }
            length = bytes[offset..<offset + count].reduce(0) { ($0 << 8) | Int($1) }
            offset += count
        }
        guard offset + length <= bytes.count else { throw SSHPrivateKeyParser.ParseError.malformed }
        defer { offset += length }
        return Array(bytes[offset..<offset + length])
    }
}

/// Reads SSH wire-format values (RFC 4251): big-endian integers and length-prefixed strings.
struct SSHWireReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = Data(data)
        offset = 0
    }

    mutating func readBytes(_ count: Int) throws -> Data {
        guard count >= 0, offset + count <= data.count else { throw SSHPrivateKeyParser.ParseError.malformed }
        defer { offset += count }
        return data.subdata(in: offset..<offset + count)
    }

    mutating func readUInt32() throws -> UInt32 {
        try readBytes(4).reduce(0) { ($0 << 8) | UInt32($1) }
    }

    mutating func readData() throws -> Data {
        try readBytes(Int(readUInt32()))
    }

    mutating func readString() throws -> String {
        guard let string = String(data: try readData(), encoding: .utf8) else {
            throw SSHPrivateKeyParser.ParseError.malformed
        }
        return string
    }
}
