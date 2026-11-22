import Foundation
import CommonCrypto
import Security
import zlib

// MARK: - CRC-32

/// Streaming CRC-32 (IEEE), backed by zlib's optimised implementation.
struct CRC32 {
    private(set) var value: UInt32 = 0

    mutating func update(_ pointer: UnsafeRawPointer, count: Int) {
        guard count > 0 else { return }
        value = UInt32(zlib.crc32(uLong(value), pointer.assumingMemoryBound(to: Bytef.self), uInt(count)))
    }
}

enum CryptoError: LocalizedError {
    case randomFailed
    case keyDerivationFailed(Int32)
    case cipherFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .randomFailed: return "Could not generate secure random bytes."
        case .keyDerivationFailed(let s): return "Password key derivation failed (\(s))."
        case .cipherFailed(let s): return "AES encryption failed (\(s))."
        }
    }
}

func secureRandomBytes(_ count: Int) throws -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: count)
    guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
        throw CryptoError.randomFailed
    }
    return bytes
}

/// Common interface for the per-entry encryptors.
protocol EntryEncryptor: AnyObject {
    /// Bytes written before the encrypted payload (salt + verifier, or the 12-byte ZipCrypto header).
    var header: [UInt8] { get }
    /// Encrypts in place.
    func encrypt(_ pointer: UnsafeMutablePointer<UInt8>, count: Int) throws
    /// Bytes written after the encrypted payload (AES authentication code).
    func trailer() -> [UInt8]
}

// MARK: - Traditional PKWARE encryption ("ZipCrypto")

private let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
    var c = UInt32(n)
    for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
    return c
}

final class ZipCryptoEncryptor: EntryEncryptor {
    private var k0: UInt32 = 0x1234_5678
    private var k1: UInt32 = 0x2345_6789
    private var k2: UInt32 = 0x3456_7890
    private(set) var header: [UInt8] = []

    /// - Parameter checkByte: high byte of the DOS time (entry uses a data descriptor, flag bit 3).
    init(password: [UInt8], checkByte: UInt8) throws {
        for b in password { updateKeys(b) }
        var plain = try secureRandomBytes(12)
        plain[11] = checkByte
        for i in 0..<plain.count { plain[i] = encryptByte(plain[i]) }
        header = plain
    }

    @inline(__always) private func updateKeys(_ b: UInt8) {
        k0 = crcTable[Int((k0 ^ UInt32(b)) & 0xFF)] ^ (k0 >> 8)
        k1 = (k1 &+ (k0 & 0xFF)) &* 134_775_813 &+ 1
        k2 = crcTable[Int((k2 ^ (k1 >> 24)) & 0xFF)] ^ (k2 >> 8)
    }

    @inline(__always) private func encryptByte(_ p: UInt8) -> UInt8 {
        let t = (k2 | 2) & 0xFFFF
        let k = UInt8(truncatingIfNeeded: (t &* (t ^ 1)) >> 8)
        updateKeys(p)
        return p ^ k
    }

    func encrypt(_ pointer: UnsafeMutablePointer<UInt8>, count: Int) throws {
        crcTable.withUnsafeBufferPointer { table in
            var a = k0, b = k1, c = k2
            for i in 0..<count {
                let p = pointer[i]
                let t = (c | 2) & 0xFFFF
                pointer[i] = p ^ UInt8(truncatingIfNeeded: (t &* (t ^ 1)) >> 8)
                a = table[Int((a ^ UInt32(p)) & 0xFF)] ^ (a >> 8)
                b = (b &+ (a & 0xFF)) &* 134_775_813 &+ 1
                c = table[Int((c ^ (b >> 24)) & 0xFF)] ^ (c >> 8)
            }
            k0 = a; k1 = b; k2 = c
        }
    }

    func trailer() -> [UInt8] { [] }
}

// MARK: - WinZip AES-256 (AE-2)

final class WinZipAESEncryptor: EntryEncryptor {
    static let saltLength = 16
    static let overhead = saltLength + 2 + 10 // salt + password verifier + auth code

    let header: [UInt8]
    private var cryptor: CCCryptorRef?
    private var hmac = CCHmacContext()
    private var counter: UInt64 = 0
    private var leftover = [UInt8](repeating: 0, count: 16)
    private var leftoverPos = 16
    private var counterBuf: [UInt8] = []
    private var keystream: [UInt8] = []

    init(password: [UInt8]) throws {
        let salt = try secureRandomBytes(Self.saltLength)
        var derived = [UInt8](repeating: 0, count: 32 + 32 + 2)
        let status = password.withUnsafeBufferPointer { pw in
            pw.baseAddress!.withMemoryRebound(to: CChar.self, capacity: max(pw.count, 1)) { pwPtr in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pwPtr, pw.count,
                                     salt, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1000,
                                     &derived, derived.count)
            }
        }
        guard status == kCCSuccess else { throw CryptoError.keyDerivationFailed(status) }

        let encKey = Array(derived[0..<32])
        let authKey = Array(derived[32..<64])
        header = salt + Array(derived[64..<66])

        var ref: CCCryptorRef?
        let s = CCCryptorCreate(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
                                CCOptions(kCCOptionECBMode), encKey, encKey.count, nil, &ref)
        guard s == kCCSuccess, let ref else { throw CryptoError.cipherFailed(s) }
        cryptor = ref
        CCHmacInit(&hmac, CCHmacAlgorithm(kCCHmacAlgSHA1), authKey, authKey.count)
    }

    deinit { if let cryptor { CCCryptorRelease(cryptor) } }

    /// AES-CTR with a little-endian counter starting at 1 (WinZip convention), then HMAC-SHA1 over ciphertext.
    func encrypt(_ pointer: UnsafeMutablePointer<UInt8>, count: Int) throws {
        var i = 0
        while i < count && leftoverPos < 16 {
            pointer[i] ^= leftover[leftoverPos]
            leftoverPos += 1; i += 1
        }
        let remaining = count - i
        if remaining > 0 {
            let blocks = (remaining + 15) / 16
            let bytes = blocks * 16
            if counterBuf.count < bytes {
                counterBuf = [UInt8](repeating: 0, count: bytes)
                keystream = [UInt8](repeating: 0, count: bytes)
            }
            counterBuf.withUnsafeMutableBytes { raw in
                for b in 0..<blocks {
                    counter &+= 1
                    raw.storeBytes(of: counter.littleEndian, toByteOffset: b * 16, as: UInt64.self)
                    raw.storeBytes(of: UInt64(0), toByteOffset: b * 16 + 8, as: UInt64.self)
                }
            }
            var moved = 0
            let s = counterBuf.withUnsafeBytes { inp in
                keystream.withUnsafeMutableBytes { out in
                    CCCryptorUpdate(cryptor, inp.baseAddress, bytes, out.baseAddress, bytes, &moved)
                }
            }
            guard s == kCCSuccess else { throw CryptoError.cipherFailed(s) }
            keystream.withUnsafeBufferPointer { ks in
                for j in 0..<remaining { pointer[i + j] ^= ks[j] }
            }
            let used = remaining % 16
            if used != 0 {
                for j in 0..<16 { leftover[j] = keystream[(blocks - 1) * 16 + j] }
                leftoverPos = used
            } else {
                leftoverPos = 16
            }
        }
        CCHmacUpdate(&hmac, pointer, count)
    }

    func trailer() -> [UInt8] {
        var mac = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        CCHmacFinal(&hmac, &mac)
        return Array(mac[0..<10])
    }
}
