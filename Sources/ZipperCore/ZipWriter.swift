import Foundation

public enum ZipEncryption: String, CaseIterable, Identifiable, Sendable {
    case aes256 = "AES-256"
    case zipCrypto = "ZipCrypto"
    public var id: String { rawValue }
}

public enum ZipError: LocalizedError {
    case io(String, Int32)
    case fileChanged(String)
    case cancelled
    case verificationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .io(let what, let code): return "\(what): \(String(cString: strerror(code)))"
        case .fileChanged(let name): return "\"\(name)\" changed while it was being zipped."
        case .cancelled: return "Cancelled."
        case .verificationFailed(let why): return "Archive verification failed: \(why)"
        }
    }
}

/// Little-endian byte builder for ZIP structures.
struct ByteWriter {
    var bytes: [UInt8] = []
    mutating func u16(_ v: UInt16) { bytes += [UInt8(v & 0xFF), UInt8(v >> 8)] }
    mutating func u32(_ v: UInt32) { for i in 0..<4 { bytes.append(UInt8(truncatingIfNeeded: v >> (8 * UInt32(i)))) } }
    mutating func u64(_ v: UInt64) { for i in 0..<8 { bytes.append(UInt8(truncatingIfNeeded: v >> (8 * UInt64(i)))) } }
    mutating func raw(_ b: [UInt8]) { bytes += b }
}

/// Writes a ZIP archive using the "stored" method (no compression), with optional
/// WinZip AES-256 or traditional ZipCrypto encryption and automatic ZIP64 support.
public final class ZipWriter {
    private struct CentralRecord {
        var name: [UInt8]
        var versionNeeded: UInt16
        var flags: UInt16
        var method: UInt16
        var time: UInt16
        var date: UInt16
        var crc: UInt32
        var compressedSize: UInt64
        var size: UInt64
        var offset: UInt64
        var externalAttributes: UInt32
        var aesExtra: [UInt8]
    }

    private static let max32: UInt64 = 0xFFFF_FFFF
    private static let chunkSize = 1 << 20

    private let fd: Int32
    private let path: String
    private let password: [UInt8]?
    private let encryption: ZipEncryption
    private var offset: UInt64 = 0
    private var records: [CentralRecord] = []
    private let buffer: UnsafeMutablePointer<UInt8>
    private var finished = false

    public var entryCount: Int { records.count }
    public var bytesWritten: UInt64 { offset }

    public init(url: URL, password: String?, encryption: ZipEncryption) throws {
        path = url.path
        fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { throw ZipError.io("Cannot create \(url.lastPathComponent)", errno) }
        if let password, !password.isEmpty {
            self.password = Array(password.utf8)
        } else {
            self.password = nil
        }
        self.encryption = encryption
        buffer = .allocate(capacity: Self.chunkSize)
    }

    deinit {
        buffer.deallocate()
        close(fd)
    }

    // MARK: Public API

    public func addDirectory(name: String, mode: UInt16, modified: Date) throws {
        let n = name.hasSuffix("/") ? name : name + "/"
        try writeEntry(name: n, mode: mode, modified: modified, size: 0, isDirectory: true, allowEncryption: false,
                       reader: { _, _ in 0 }, progress: { _ in })
    }

    public func addFile(name: String, source: URL, size: UInt64, mode: UInt16, modified: Date,
                        progress: (Int) throws -> Void) throws {
        let input = open(source.path, O_RDONLY)
        guard input >= 0 else { throw ZipError.io("Cannot read \(source.lastPathComponent)", errno) }
        defer { close(input) }
        try writeEntry(name: name, mode: mode, modified: modified, size: size, isDirectory: false, allowEncryption: true,
                       reader: { ptr, max in
                           while true {
                               let n = read(input, ptr, max)
                               if n >= 0 { return n }
                               if errno != EINTR { throw ZipError.io("Read error in \(source.lastPathComponent)", errno) }
                           }
                       }, progress: progress)
    }

    public func addSymlink(name: String, target: String, mode: UInt16, modified: Date) throws {
        let data = Array(target.utf8)
        var pos = 0
        // Symlinks hold only a path, never file data. They are stored unencrypted because most
        // extractors (libarchive, Archive Utility) cannot restore encrypted links.
        try writeEntry(name: name, mode: mode, modified: modified, size: UInt64(data.count), isDirectory: false,
                       allowEncryption: false,
                       reader: { ptr, max in
                           let n = min(max, data.count - pos)
                           for i in 0..<n { ptr[i] = data[pos + i] }
                           pos += n
                           return n
                       }, progress: { _ in })
    }

    public func finish() throws {
        guard !finished else { return }
        let cdStart = offset
        for r in records {
            var w = ByteWriter()
            let needs64Size = r.size >= Self.max32
            let needs64CSize = r.compressedSize >= Self.max32
            let needs64Offset = r.offset >= Self.max32
            var extra = ByteWriter()
            if needs64Size || needs64CSize || needs64Offset {
                var z = ByteWriter()
                if needs64Size { z.u64(r.size) }
                if needs64CSize { z.u64(r.compressedSize) }
                if needs64Offset { z.u64(r.offset) }
                extra.u16(0x0001); extra.u16(UInt16(z.bytes.count)); extra.raw(z.bytes)
            }
            extra.raw(r.aesExtra)

            w.u32(0x0201_4B50)
            w.u16((3 << 8) | 63)           // made by: UNIX, spec 6.3
            w.u16(r.versionNeeded)
            w.u16(r.flags)
            w.u16(r.method)
            w.u16(r.time)
            w.u16(r.date)
            w.u32(r.crc)
            w.u32(needs64CSize ? UInt32(Self.max32) : UInt32(r.compressedSize))
            w.u32(needs64Size ? UInt32(Self.max32) : UInt32(r.size))
            w.u16(UInt16(r.name.count))
            w.u16(UInt16(extra.bytes.count))
            w.u16(0)                        // comment length
            w.u16(0)                        // disk number
            w.u16(0)                        // internal attributes
            w.u32(r.externalAttributes)
            w.u32(needs64Offset ? UInt32(Self.max32) : UInt32(r.offset))
            w.raw(r.name)
            w.raw(extra.bytes)
            try write(w.bytes)
        }
        let cdSize = offset - cdStart
        let count = UInt64(records.count)

        if count >= 0xFFFF || cdStart >= Self.max32 || cdSize >= Self.max32 {
            let zip64EOCD = offset
            var z = ByteWriter()
            z.u32(0x0606_4B50)
            z.u64(44)
            z.u16((3 << 8) | 63)
            z.u16(45)
            z.u32(0); z.u32(0)
            z.u64(count); z.u64(count)
            z.u64(cdSize); z.u64(cdStart)
            z.u32(0x0706_4B50)              // locator
            z.u32(0)
            z.u64(zip64EOCD)
            z.u32(1)
            try write(z.bytes)
        }

        var e = ByteWriter()
        e.u32(0x0605_4B50)
        e.u16(0); e.u16(0)
        e.u16(UInt16(min(count, 0xFFFF)))
        e.u16(UInt16(min(count, 0xFFFF)))
        e.u32(UInt32(min(cdSize, Self.max32)))
        e.u32(UInt32(min(cdStart, Self.max32)))
        e.u16(0)
        try write(e.bytes)
        guard fsync(fd) == 0 else { throw ZipError.io("Cannot flush archive", errno) }
        finished = true
    }

    // MARK: Entry writing

    private func writeEntry(name: String, mode: UInt16, modified: Date, size: UInt64, isDirectory: Bool,
                            allowEncryption: Bool,
                            reader: (UnsafeMutablePointer<UInt8>, Int) throws -> Int,
                            progress: (Int) throws -> Void) throws {
        let nameBytes = Array(name.precomposedStringWithCanonicalMapping.utf8)
        let (time, date) = Self.dosDateTime(modified)
        let encrypted = password != nil && allowEncryption
        let useAES = encrypted && encryption == .aes256
        let useZipCrypto = encrypted && encryption == .zipCrypto

        let overhead: UInt64 = useAES ? UInt64(WinZipAESEncryptor.overhead) : (useZipCrypto ? 12 : 0)
        let compressedSize = size + overhead
        let localZip64 = size >= Self.max32 || compressedSize >= Self.max32
        let headerOffset = offset
        let anyZip64 = localZip64 || headerOffset >= Self.max32

        var flags: UInt16 = 0x0800                 // UTF-8 names
        if encrypted { flags |= 0x0001 }
        if useZipCrypto { flags |= 0x0008 }        // data descriptor → check byte from time

        var versionNeeded: UInt16 = isDirectory ? 20 : 10
        if useZipCrypto { versionNeeded = max(versionNeeded, 20) }
        if anyZip64 { versionNeeded = max(versionNeeded, 45) }
        if useAES { versionNeeded = max(versionNeeded, 51) }

        var aesExtra = ByteWriter()
        if useAES {
            aesExtra.u16(0x9901); aesExtra.u16(7)
            aesExtra.u16(2)                        // AE-2
            aesExtra.raw([0x41, 0x45])             // "AE"
            aesExtra.raw([3])                      // AES-256
            aesExtra.u16(0)                        // actual method: stored
        }
        let method: UInt16 = useAES ? 99 : 0

        var localExtra = ByteWriter()
        if localZip64 {
            localExtra.u16(0x0001); localExtra.u16(16)
            localExtra.u64(size); localExtra.u64(compressedSize)
        }
        localExtra.raw(aesExtra.bytes)

        var h = ByteWriter()
        h.u32(0x0403_4B50)
        h.u16(versionNeeded)
        h.u16(flags)
        h.u16(method)
        h.u16(time)
        h.u16(date)
        h.u32(0)                                   // CRC: patched later / descriptor / 0 for AE-2
        h.u32(localZip64 ? UInt32(Self.max32) : UInt32(compressedSize))
        h.u32(localZip64 ? UInt32(Self.max32) : UInt32(size))
        h.u16(UInt16(nameBytes.count))
        h.u16(UInt16(localExtra.bytes.count))
        h.raw(nameBytes)
        h.raw(localExtra.bytes)
        try write(h.bytes)

        let encryptor: EntryEncryptor?
        if useAES {
            encryptor = try WinZipAESEncryptor(password: password!)
        } else if useZipCrypto {
            encryptor = try ZipCryptoEncryptor(password: password!, checkByte: UInt8(time >> 8))
        } else {
            encryptor = nil
        }
        if let encryptor { try write(encryptor.header) }

        var crc = CRC32()
        var remaining = size
        while remaining > 0 {
            let want = Int(min(UInt64(Self.chunkSize), remaining))
            let n = try reader(buffer, want)
            if n == 0 { throw ZipError.fileChanged(name) }
            if !useAES { crc.update(buffer, count: n) }
            try encryptor?.encrypt(buffer, count: n)
            try write(buffer, count: n)
            remaining -= UInt64(n)
            try progress(n)
        }
        // Make sure the file did not grow while reading.
        if !isDirectory {
            var probe: UInt8 = 0
            let extra = try withUnsafeMutablePointer(to: &probe) { try reader($0, 1) }
            if extra != 0 { throw ZipError.fileChanged(name) }
        }
        if let encryptor { try write(encryptor.trailer()) }

        let finalCRC: UInt32 = useAES ? 0 : crc.value
        if useZipCrypto {
            var d = ByteWriter()
            d.u32(0x0807_4B50)
            d.u32(finalCRC)
            if localZip64 { d.u64(compressedSize); d.u64(size) } else { d.u32(UInt32(compressedSize)); d.u32(UInt32(size)) }
            try write(d.bytes)
        } else if !useAES && finalCRC != 0 {
            var c = ByteWriter(); c.u32(finalCRC)
            try c.bytes.withUnsafeBytes { raw in
                guard pwrite(fd, raw.baseAddress, 4, off_t(headerOffset + 14)) == 4 else {
                    throw ZipError.io("Cannot update archive header", errno)
                }
            }
        }

        let typeBits: UInt32 = isDirectory ? 0x10 : 0  // MS-DOS directory attribute
        records.append(CentralRecord(name: nameBytes, versionNeeded: versionNeeded, flags: flags, method: method,
                                     time: time, date: date, crc: finalCRC, compressedSize: compressedSize,
                                     size: size, offset: headerOffset,
                                     externalAttributes: (UInt32(mode) << 16) | typeBits,
                                     aesExtra: aesExtra.bytes))
    }

    // MARK: Low level

    private func write(_ bytes: [UInt8]) throws {
        try bytes.withUnsafeBufferPointer { b in
            try write(UnsafeMutablePointer(mutating: b.baseAddress!), count: b.count)
        }
    }

    private func write(_ ptr: UnsafeMutablePointer<UInt8>, count: Int) throws {
        var done = 0
        while done < count {
            let n = Darwin.write(fd, ptr + done, count - done)
            if n < 0 {
                if errno == EINTR { continue }
                throw ZipError.io("Cannot write archive", errno)
            }
            done += n
        }
        offset += UInt64(count)
    }

    static func dosDateTime(_ date: Date) -> (UInt16, UInt16) {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = min(max((c.year ?? 1980), 1980), 2107)
        let time = UInt16((c.hour ?? 0) << 11 | (c.minute ?? 0) << 5 | (c.second ?? 0) / 2)
        let day = UInt16((year - 1980) << 9 | (c.month ?? 1) << 5 | (c.day ?? 1))
        return (time, day)
    }
}
