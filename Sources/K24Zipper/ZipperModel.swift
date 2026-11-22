import AppKit
import Observation
import UniformTypeIdentifiers
import ZipperCore

@Observable
@MainActor
final class ZipperModel {
    static let shared = ZipperModel()

    // Inputs
    var items: [SourceItem] = []
    var sizes: [UUID: UInt64] = [:]
    var mode: ArchiveMode = .separate { didSet { defaults.set(mode.rawValue, forKey: "mode") } }
    var singleName = ""
    var destination: URL { didSet { defaults.set(destination.path, forKey: "destination") } }

    var passwordEnabled = false
    var password = ""
    var confirmPassword = ""
    var encryption: ZipEncryption = .aes256 { didSet { defaults.set(encryption.rawValue, forKey: "encryption") } }

    var deleteOriginals = false
    var deleteMode: DeleteMode = .trash { didSet { defaults.set(deleteMode.rawValue, forKey: "deleteMode") } }
    var skipJunkFiles = true { didSet { defaults.set(skipJunkFiles, forKey: "skipJunk") } }

    // Job state
    var isRunning = false
    var progress: JobProgress?
    var results: [ArchiveResult]?
    var showDeleteConfirmation = false
    private var cancelFlag = CancelFlag()

    @ObservationIgnored private let defaults = UserDefaults.standard

    init() {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        if let saved = defaults.string(forKey: "destination"),
           FileManager.default.fileExists(atPath: saved) {
            destination = URL(fileURLWithPath: saved)
        } else {
            destination = downloads
        }
        if let m = defaults.string(forKey: "mode").flatMap(ArchiveMode.init(rawValue:)) { mode = m }
        if let e = defaults.string(forKey: "encryption").flatMap(ZipEncryption.init(rawValue:)) { encryption = e }
        if let d = defaults.string(forKey: "deleteMode").flatMap(DeleteMode.init(rawValue:)), d != .none { deleteMode = d }
        if defaults.object(forKey: "skipJunk") != nil { skipJunkFiles = defaults.bool(forKey: "skipJunk") }
    }

    // MARK: Derived

    var totalSize: UInt64 { items.reduce(0) { $0 + (sizes[$1.id] ?? 0) } }
    var sizesPending: Bool { items.contains { sizes[$0.id] == nil } }

    var effectiveSingleName: String {
        let trimmed = singleName.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? ArchivePlanner.defaultSingleName(for: items) : trimmed
    }

    var plan: [PlannedArchive] {
        ArchivePlanner.plan(items: items, mode: mode, singleName: effectiveSingleName, destination: destination)
    }

    var passwordProblem: String? {
        guard passwordEnabled else { return nil }
        if password.isEmpty { return "Enter a password." }
        if confirmPassword.isEmpty { return "Confirm the password." }
        if password != confirmPassword { return "Passwords don't match." }
        return nil
    }

    var passwordWarning: String? {
        guard passwordEnabled, passwordProblem == nil else { return nil }
        if password.count < 8 { return "Short passwords are easy to guess. Use 8 or more characters." }
        if encryption == .zipCrypto && password.unicodeScalars.contains(where: { !$0.isASCII }) {
            return "Non-English characters in ZipCrypto passwords may not work in other apps."
        }
        return nil
    }

    /// Items whose originals would be kept because the destination is inside them.
    var destinationInsideSources: [SourceItem] {
        let dst = destination.resolvingSymlinksInPath().path + "/"
        return items.filter { $0.isDirectory && dst.hasPrefix($0.url.resolvingSymlinksInPath().path + "/") }
    }

    var canCreate: Bool { !items.isEmpty && passwordProblem == nil && !isRunning }

    var createButtonTitle: String {
        let n = plan.count
        return n <= 1 ? "Create ZIP" : "Create \(n) ZIP files"
    }

    // MARK: Item management

    func add(_ urls: [URL]) {
        let existing = Set(items.map { $0.url.path })
        for url in urls where url.isFileURL {
            let std = url.standardizedFileURL
            guard !existing.contains(std.path) else { continue }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: std.path, isDirectory: &isDir) else { continue }
            let item = SourceItem(url: std, isDirectory: isDir.boolValue)
            items.append(item)
            computeSize(for: item)
        }
    }

    private func computeSize(for item: SourceItem) {
        let id = item.id, url = item.url
        Task.detached(priority: .utility) {
            let size = sizeOnDisk(url)
            await MainActor.run { self.sizes[id] = size }
        }
    }

    func remove(_ item: SourceItem) {
        items.removeAll { $0.id == item.id }
        sizes[item.id] = nil
    }

    func removeAll() {
        items.removeAll()
        sizes.removeAll()
    }

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose files or folders to zip"
        if panel.runModal() == .OK { add(panel.urls) }
    }

    func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = destination
        panel.prompt = "Choose"
        panel.message = "Choose where to save the ZIP files"
        if panel.runModal() == .OK, let url = panel.url { destination = url }
    }

    // MARK: Running

    func requestCreate() {
        guard canCreate else { return }
        if deleteOriginals {
            showDeleteConfirmation = true
        } else {
            start()
        }
    }

    func start() {
        guard canCreate else { return }
        let archives = plan
        let options = JobOptions(destination: destination,
                                 password: passwordEnabled ? password : nil,
                                 encryption: encryption,
                                 deleteMode: deleteOriginals ? deleteMode : .none,
                                 skipJunkFiles: skipJunkFiles)
        let flag = CancelFlag()
        cancelFlag = flag
        isRunning = true
        results = nil
        progress = JobProgress(archiveIndex: 0, archiveCount: archives.count, archiveName: "", currentFile: "",
                               bytesDone: 0, bytesTotal: totalSize, phase: "Preparing…")

        Task.detached(priority: .userInitiated) {
            let results = ZipJob.run(archives: archives, options: options, cancel: flag) { p in
                Task { @MainActor in self.progress = p }
            }
            await MainActor.run { self.finish(results) }
        }
    }

    private func finish(_ results: [ArchiveResult]) {
        isRunning = false
        self.results = results
        // Drop items that no longer exist (removed after zipping).
        let removed = items.filter { !FileManager.default.fileExists(atPath: $0.url.path) }
        for item in removed { remove(item) }
    }

    func cancel() { cancelFlag.cancel() }

    func dismissResults() {
        results = nil
        progress = nil
    }

    func revealResults() {
        let urls = (results ?? []).compactMap(\.url)
        if urls.isEmpty {
            NSWorkspace.shared.open(destination)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }
}
