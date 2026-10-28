import CryptoKit
import Foundation

/// `bcrypt_pbkdf` from OpenBSD, used by OpenSSH to derive the key that encrypts private key files.
enum BCryptPBKDF {
    static func deriveKey(password: Data, salt: Data, rounds: Int, length: Int) -> Data {
        precondition(rounds >= 1 && length > 0)
        let hashLength = 32
        let stride = (length + hashLength - 1) / hashLength
        var amount = (length + stride - 1) / stride
        let passwordHash = Data(SHA512.hash(data: password))
        var key = [UInt8](repeating: 0, count: length)
        var remaining = length
        var count: UInt32 = 1

        while remaining > 0 {
            var countSalt = salt
            countSalt.append(contentsOf: withUnsafeBytes(of: count.bigEndian, Array.init))
            var block = hash(password: passwordHash, salt: Data(SHA512.hash(data: countSalt)))
            var output = block
            for _ in 1..<rounds {
                block = hash(password: passwordHash, salt: Data(SHA512.hash(data: Data(block))))
                for index in output.indices {
                    output[index] ^= block[index]
                }
            }
            amount = min(amount, remaining)
            var written = 0
            for index in 0..<amount {
                let destination = index * stride + Int(count - 1)
                guard destination < length else { break }
                key[destination] = output[index]
                written += 1
            }
            remaining -= written
            count += 1
        }
        return Data(key)
    }

    /// `bcrypt_hash`: an expensive Blowfish key schedule followed by 64 encryptions of a constant.
    private static func hash(password: Data, salt: Data) -> [UInt8] {
        var blowfish = Blowfish()
        let passwordBytes = [UInt8](password)
        let saltBytes = [UInt8](salt)
        blowfish.expandState(data: saltBytes, key: passwordBytes)
        for _ in 0..<64 {
            blowfish.expandState(key: saltBytes)
            blowfish.expandState(key: passwordBytes)
        }
        let magic = [UInt8]("OxychromaticBlowfishSwatDynamite".utf8)
        var words = [UInt32](repeating: 0, count: 8)
        var position = 0
        for index in words.indices {
            words[index] = Blowfish.streamToWord(magic, &position)
        }
        for _ in 0..<64 {
            for block in Swift.stride(from: 0, to: 8, by: 2) {
                (words[block], words[block + 1]) = blowfish.encrypt(words[block], words[block + 1])
            }
        }
        var output = [UInt8](repeating: 0, count: 32)
        for (index, word) in words.enumerated() {
            output[4 * index + 3] = UInt8(truncatingIfNeeded: word >> 24)
            output[4 * index + 2] = UInt8(truncatingIfNeeded: word >> 16)
            output[4 * index + 1] = UInt8(truncatingIfNeeded: word >> 8)
            output[4 * index] = UInt8(truncatingIfNeeded: word)
        }
        return output
    }
}

/// The Blowfish cipher with the "eksblowfish" state expansion used by bcrypt.
struct Blowfish {
    private var p = BlowfishTables.p
    private var s = BlowfishTables.s

    /// Reads four bytes as a big-endian word, wrapping around the end of `data`.
    static func streamToWord(_ data: [UInt8], _ position: inout Int) -> UInt32 {
        var word: UInt32 = 0
        for _ in 0..<4 {
            if position >= data.count {
                position = 0
            }
            word = (word << 8) | UInt32(data[position])
            position += 1
        }
        return word
    }

    private func f(_ x: UInt32) -> UInt32 {
        let a = s[Int(x >> 24)]
        let b = s[0x100 + Int((x >> 16) & 0xFF)]
        let c = s[0x200 + Int((x >> 8) & 0xFF)]
        let d = s[0x300 + Int(x & 0xFF)]
        return ((a &+ b) ^ c) &+ d
    }

    func encrypt(_ left: UInt32, _ right: UInt32) -> (UInt32, UInt32) {
        var left = left ^ p[0]
        var right = right
        for round in Swift.stride(from: 1, through: 15, by: 2) {
            right ^= f(left) ^ p[round]
            left ^= f(right) ^ p[round + 1]
        }
        return (right ^ p[17], left)
    }

    /// `Blowfish_expandstate`: mixes `key` into P and re-encrypts the tables with `data`.
    mutating func expandState(data: [UInt8], key: [UInt8]) {
        var position = 0
        for index in p.indices {
            p[index] ^= Self.streamToWord(key, &position)
        }
        position = 0
        var left: UInt32 = 0
        var right: UInt32 = 0
        for index in Swift.stride(from: 0, to: p.count, by: 2) {
            left ^= Self.streamToWord(data, &position)
            right ^= Self.streamToWord(data, &position)
            (left, right) = encrypt(left, right)
            p[index] = left
            p[index + 1] = right
        }
        for index in Swift.stride(from: 0, to: s.count, by: 2) {
            left ^= Self.streamToWord(data, &position)
            right ^= Self.streamToWord(data, &position)
            (left, right) = encrypt(left, right)
            s[index] = left
            s[index + 1] = right
        }
    }

    /// `Blowfish_expand0state`: the same expansion without data.
    mutating func expandState(key: [UInt8]) {
        var position = 0
        for index in p.indices {
            p[index] ^= Self.streamToWord(key, &position)
        }
        var left: UInt32 = 0
        var right: UInt32 = 0
        for index in Swift.stride(from: 0, to: p.count, by: 2) {
            (left, right) = encrypt(left, right)
            p[index] = left
            p[index + 1] = right
        }
        for index in Swift.stride(from: 0, to: s.count, by: 2) {
            (left, right) = encrypt(left, right)
            s[index] = left
            s[index + 1] = right
        }
    }
}
