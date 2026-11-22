import Foundation

public enum ArchiveMode: String, CaseIterable, Identifiable, Sendable {
    case single = "Single archive"
    case separate = "Separate files"
    public var id: String { rawValue }
}

public enum DeleteMode: String, CaseIterable, Identifiable, Sendable {
    case none
    case trash
    case permanent
    public var id: String { rawValue }
}

public struct SourceItem: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public let url: URL
    public let isDirectory: Bool
    public var name: String { url.lastPathComponent }
    public init(url: URL, isDirectory: Bool) {
        self.url = url.standardizedFileURL
        self.isDirectory = isDirectory
    }
}

public struct PlannedArchive: Identifiable, Sendable {
    public let id = UUID()
    public let outputName: String
    public let items: [SourceItem]
    /// Top-level names inside the archive, parallel to `items` (deduplicated).
    public let rootNames: [String]
}

public enum ArchivePlanner {
    /// Characters that cannot appear in a file name on macOS.
    public static func sanitize(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Archive" : cleaned
    }

    public static func defaultSingleName(for items: [SourceItem]) -> String {
        guard items.count == 1, let first = items.first else { return "Archive" }
        return baseName(of: first)
    }

    static func baseName(of item: SourceItem) -> String {
        if item.isDirectory { return item.name }
        let base = (item.name as NSString).deletingPathExtension
        return base.isEmpty ? item.name : base
    }

    public static func plan(items: [SourceItem], mode: ArchiveMode, singleName: String,
                            destination: URL) -> [PlannedArchive] {
        guard !items.isEmpty else { return [] }
        var taken = Set<String>()
        func uniqueOutput(_ base: String) -> String {
            var n = 1
            while true {
                let candidate = n == 1 ? "\(base).zip" : "\(base) \(n).zip"
                let exists = FileManager.default.fileExists(atPath: destination.appendingPathComponent(candidate).path)
                if !exists && !taken.contains(candidate.lowercased()) {
                    taken.insert(candidate.lowercased())
                    return candidate
                }
                n += 1
            }
        }

        switch mode {
        case .single:
            var roots = Set<String>()
            let rootNames = items.map { item -> String in
                var name = item.name
                var n = 2
                while roots.contains(name.lowercased()) {
                    let ext = (item.name as NSString).pathExtension
                    let base = item.isDirectory ? item.name : (item.name as NSString).deletingPathExtension
                    name = item.isDirectory || ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
                    n += 1
                }
                roots.insert(name.lowercased())
                return name
            }
            var base = sanitize(singleName)
            if base.lowercased().hasSuffix(".zip") { base = String(base.dropLast(4)) }
            return [PlannedArchive(outputName: uniqueOutput(sanitize(base)), items: items, rootNames: rootNames)]
        case .separate:
            return items.map { item in
                PlannedArchive(outputName: uniqueOutput(baseName(of: item)), items: [item], rootNames: [item.name])
            }
        }
    }
}

// MARK: - Entry collection

struct EntrySpec {
    enum Kind { case file, directory, symlink(String) }
    let kind: Kind
    let source: URL
    let archivePath: String
    let size: UInt64
    let mode: UInt16
    let modified: Date
}

enum EntryCollector {
    static func stat(_ url: URL) -> Darwin.stat? {
        var st = Darwin.stat()
        return lstat(url.path, &st) == 0 ? st : nil
    }

    static func spec(for url: URL, archivePath: String) throws -> EntrySpec? {
        guard let st = stat(url) else { throw ZipError.io("Cannot read \(url.lastPathComponent)", errno) }
        let mode = UInt16(truncatingIfNeeded: st.st_mode)
        let modified = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
        switch st.st_mode & S_IFMT {
        case S_IFDIR:
            return EntrySpec(kind: .directory, source: url, archivePath: archivePath + "/", size: 0, mode: mode, modified: modified)
        case S_IFREG:
            return EntrySpec(kind: .file, source: url, archivePath: archivePath, size: UInt64(st.st_size), mode: mode, modified: modified)
        case S_IFLNK:
            let target = (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) ?? ""
            return EntrySpec(kind: .symlink(target), source: url, archivePath: archivePath,
                             size: UInt64(target.utf8.count), mode: mode, modified: modified)
        default:
            return nil // sockets, FIFOs, devices
        }
    }

    static func collect(item: SourceItem, rootName: String, skipJunk: Bool) throws -> [EntrySpec] {
        guard let root = try spec(for: item.url, archivePath: rootName) else { return [] }
        guard case .directory = root.kind else { return [root] }
        var result = [root]
        guard let e = FileManager.default.enumerator(atPath: item.url.path) else { return result }
        var paths: [String] = []
        while let rel = e.nextObject() as? String {
            let last = (rel as NSString).lastPathComponent
            if skipJunk && (last == ".DS_Store" || last.hasPrefix("._") || last == "__MACOSX") {
                if last == "__MACOSX" { e.skipDescendants() }
                continue
            }
            if last.hasPrefix(".K24Zipper-") && last.hasSuffix(".part") { continue }
            paths.append(rel)
        }
        paths.sort()
        for rel in paths {
            if let s = try spec(for: item.url.appendingPathComponent(rel), archivePath: rootName + "/" + rel) {
                result.append(s)
            }
        }
        return result
    }

    /// Total size of regular files below a URL (for display).
    public static func totalSize(of url: URL) -> UInt64 {
        guard let st = stat(url) else { return 0 }
        if st.st_mode & S_IFMT != S_IFDIR { return st.st_mode & S_IFMT == S_IFREG ? UInt64(st.st_size) : 0 }
        var total: UInt64 = 0
        let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                                               options: [], errorHandler: { _, _ in true })
        while let u = e?.nextObject() as? URL {
            if let v = try? u.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), v.isRegularFile == true {
                total += UInt64(v.fileSize ?? 0)
            }
        }
        return total
    }
}

public func sizeOnDisk(_ url: URL) -> UInt64 { EntryCollector.totalSize(of: url) }

// MARK: - Verification

public enum ZipVerifier {
    /// Re-reads the end of the archive and walks the central directory, checking the entry count
    /// and that each local header is where the central directory says it is.
    public static func verify(url: URL, expectedEntries: Int) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()
        let tailLength = min(fileSize, 22 + 0xFFFF + 20)
        try handle.seek(toOffset: fileSize - tailLength)
        let tail = [UInt8](try handle.read(upToCount: Int(tailLength)) ?? Data())
        func u16(_ b: [UInt8], _ i: Int) -> UInt64 { UInt64(b[i]) | UInt64(b[i + 1]) << 8 }
        func u32(_ b: [UInt8], _ i: Int) -> UInt64 { u16(b, i) | u16(b, i + 2) << 16 }
        func u64(_ b: [UInt8], _ i: Int) -> UInt64 { u32(b, i) | u32(b, i + 4) << 32 }

        guard tail.count >= 22,
              let eocd = stride(from: tail.count - 22, through: 0, by: -1).first(where: { u32(tail, $0) == 0x0605_4B50 })
        else { throw ZipError.verificationFailed("end of central directory not found") }

        var count = u16(tail, eocd + 10)
        var cdSize = u32(tail, eocd + 12)
        var cdOffset = u32(tail, eocd + 16)
        if eocd >= 20, u32(tail, eocd - 20) == 0x0706_4B50 {
            let z64Offset = u64(tail, eocd - 20 + 8)
            try handle.seek(toOffset: z64Offset)
            let z = [UInt8](try handle.read(upToCount: 56) ?? Data())
            guard z.count == 56, u32(z, 0) == 0x0606_4B50 else { throw ZipError.verificationFailed("bad ZIP64 record") }
            count = u64(z, 32); cdSize = u64(z, 40); cdOffset = u64(z, 48)
        }
        guard count == UInt64(expectedEntries) else {
            throw ZipError.verificationFailed("expected \(expectedEntries) entries, found \(count)")
        }
        guard cdOffset + cdSize <= fileSize else { throw ZipError.verificationFailed("central directory out of range") }

        try handle.seek(toOffset: cdOffset)
        let cd = [UInt8](try handle.read(upToCount: Int(cdSize)) ?? Data())
        var p = 0
        for _ in 0..<count {
            guard p + 46 <= cd.count, u32(cd, p) == 0x0201_4B50 else { throw ZipError.verificationFailed("corrupt central directory") }
            let nameLen = Int(u16(cd, p + 28)), extraLen = Int(u16(cd, p + 30)), commentLen = Int(u16(cd, p + 32))
            var localOffset = u32(cd, p + 42)
            if localOffset == 0xFFFF_FFFF {
                // Find ZIP64 extra; the offset is the last field present.
                var q = p + 46 + nameLen
                let end = q + extraLen
                while q + 4 <= end {
                    let id = u16(cd, q), len = Int(u16(cd, q + 2))
                    if id == 0x0001 { localOffset = u64(cd, q + 4 + len - 8) }
                    q += 4 + len
                }
            }
            try handle.seek(toOffset: localOffset)
            let sig = [UInt8](try handle.read(upToCount: 4) ?? Data())
            guard sig.count == 4, u32(sig, 0) == 0x0403_4B50 else { throw ZipError.verificationFailed("local header mismatch") }
            p += 46 + nameLen + extraLen + commentLen
        }
    }
}

// MARK: - Job

public struct JobProgress: Sendable {
    public var archiveIndex: Int
    public var archiveCount: Int
    public var archiveName: String
    public var currentFile: String
    public var bytesDone: UInt64
    public var bytesTotal: UInt64
    public var phase: String

    public init(archiveIndex: Int, archiveCount: Int, archiveName: String, currentFile: String,
                bytesDone: UInt64, bytesTotal: UInt64, phase: String) {
        self.archiveIndex = archiveIndex; self.archiveCount = archiveCount; self.archiveName = archiveName
        self.currentFile = currentFile; self.bytesDone = bytesDone; self.bytesTotal = bytesTotal; self.phase = phase
    }
}

public struct ArchiveResult: Identifiable, Sendable {
    public let id = UUID()
    public let name: String
    public let url: URL?
    public let error: String?
    public let originalsRemoved: Bool
    public let deleteNote: String?
}

public struct JobOptions: Sendable {
    public var destination: URL
    public var password: String?
    public var encryption: ZipEncryption
    public var deleteMode: DeleteMode
    public var skipJunkFiles: Bool
    public init(destination: URL, password: String?, encryption: ZipEncryption, deleteMode: DeleteMode, skipJunkFiles: Bool) {
        self.destination = destination; self.password = password; self.encryption = encryption
        self.deleteMode = deleteMode; self.skipJunkFiles = skipJunkFiles
    }
}

public final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    public init() {}
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    public func cancel() { lock.lock(); value = true; lock.unlock() }
}

public enum ZipJob {
    public static func run(archives: [PlannedArchive], options: JobOptions, cancel: CancelFlag,
                           progress: @escaping (JobProgress) -> Void) -> [ArchiveResult] {
        var state = JobProgress(archiveIndex: 0, archiveCount: archives.count, archiveName: "",
                                currentFile: "", bytesDone: 0, bytesTotal: 0, phase: "Scanning files…")
        progress(state)

        // Scan everything up front so sizes are known and freshly created archives are never picked up.
        var plans: [(PlannedArchive, [EntrySpec])] = []
        var results: [ArchiveResult] = []
        for archive in archives {
            do {
                var entries: [EntrySpec] = []
                for (item, root) in zip(archive.items, archive.rootNames) {
                    entries += try EntryCollector.collect(item: item, rootName: root, skipJunk: options.skipJunkFiles)
                }
                plans.append((archive, entries))
                state.bytesTotal += entries.reduce(0) { $0 + $1.size }
            } catch {
                results.append(ArchiveResult(name: archive.outputName, url: nil, error: error.localizedDescription,
                                             originalsRemoved: false, deleteNote: nil))
            }
        }

        var lastReport = Date.distantPast
        for (index, (archive, entries)) in plans.enumerated() {
            if cancel.isCancelled {
                results.append(ArchiveResult(name: archive.outputName, url: nil, error: ZipError.cancelled.localizedDescription,
                                             originalsRemoved: false, deleteNote: nil))
                continue
            }
            state.archiveIndex = index + 1
            state.archiveCount = plans.count
            state.archiveName = archive.outputName
            state.phase = "Zipping"
            progress(state)

            let finalURL = options.destination.appendingPathComponent(archive.outputName)
            let tempURL = options.destination.appendingPathComponent(".K24Zipper-\(UUID().uuidString).part")
            do {
                let writer = try ZipWriter(url: tempURL, password: options.password, encryption: options.encryption)
                for entry in entries {
                    if cancel.isCancelled { throw ZipError.cancelled }
                    state.currentFile = entry.archivePath
                    switch entry.kind {
                    case .directory:
                        try writer.addDirectory(name: entry.archivePath, mode: entry.mode, modified: entry.modified)
                    case .symlink(let target):
                        try writer.addSymlink(name: entry.archivePath, target: target, mode: entry.mode, modified: entry.modified)
                        state.bytesDone += entry.size
                    case .file:
                        try writer.addFile(name: entry.archivePath, source: entry.source, size: entry.size,
                                           mode: entry.mode, modified: entry.modified) { n in
                            if cancel.isCancelled { throw ZipError.cancelled }
                            state.bytesDone += UInt64(n)
                            let now = Date()
                            if now.timeIntervalSince(lastReport) > 0.08 { lastReport = now; progress(state) }
                        }
                    }
                }
                try writer.finish()
                let count = writer.entryCount
                state.phase = "Verifying"
                progress(state)
                try ZipVerifier.verify(url: tempURL, expectedEntries: count)

                var target = finalURL
                var n = 2
                while FileManager.default.fileExists(atPath: target.path) {
                    let base = (archive.outputName as NSString).deletingPathExtension
                    target = options.destination.appendingPathComponent("\(base) \(n).zip"); n += 1
                }
                try FileManager.default.moveItem(at: tempURL, to: target)

                let (removed, note) = removeOriginals(archive.items, archiveURL: target, mode: options.deleteMode)
                results.append(ArchiveResult(name: target.lastPathComponent, url: target, error: nil,
                                             originalsRemoved: removed, deleteNote: note))
            } catch {
                try? FileManager.default.removeItem(at: tempURL)
                results.append(ArchiveResult(name: archive.outputName, url: nil, error: error.localizedDescription,
                                             originalsRemoved: false, deleteNote: nil))
            }
        }
        state.phase = "Done"
        progress(state)
        return results
    }

    private static func removeOriginals(_ items: [SourceItem], archiveURL: URL, mode: DeleteMode) -> (Bool, String?) {
        guard mode != .none else { return (false, nil) }
        var failures: [String] = []
        for item in items {
            let src = item.url.resolvingSymlinksInPath().path
            let dst = archiveURL.resolvingSymlinksInPath().path
            if item.isDirectory && dst.hasPrefix(src + "/") {
                failures.append("\(item.name) kept (the archive was saved inside it)")
                continue
            }
            do {
                if mode == .trash {
                    try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
                } else {
                    try FileManager.default.removeItem(at: item.url)
                }
            } catch {
                failures.append("\(item.name): \(error.localizedDescription)")
            }
        }
        return (failures.isEmpty, failures.isEmpty ? nil : failures.joined(separator: "\n"))
    }
}
