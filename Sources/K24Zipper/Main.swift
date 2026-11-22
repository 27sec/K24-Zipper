import AppKit
import SwiftUI
import ZipperCore

@main
enum Main {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.first == "--cli" {
            exit(CLI.run(Array(args.dropFirst())))
        }
        if args.first == "--export-icon", args.count >= 2 {
            let ok = MainActor.assumeIsolated { IconExporter.export(to: URL(fileURLWithPath: args[1])) }
            exit(ok ? 0 : 1)
        }
        if args.first == "--snapshot", args.count >= 2 {
            let ok = MainActor.assumeIsolated { Snapshot.run(Array(args.dropFirst())) }
            exit(ok ? 0 : 1)
        }
        K24ZipperApp.main()
    }
}

struct K24ZipperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let model = ZipperModel.shared

    var body: some Scene {
        Window("K24 Zipper", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 520, idealWidth: 540, minHeight: 640, idealHeight: 820)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Files…") { model.chooseFiles() }
                    .keyboardShortcut("o")
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if Bundle.main.bundleURL.pathExtension != "app" {
            NSApp.applicationIconImage = IconExporter.image(size: 512)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Files dropped on the Dock icon or opened with "Open With".
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { ZipperModel.shared.add(urls) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Headless mode: K24Zipper --cli [--separate] [--name N] [--password P] [--zipcrypto]
///                              [--trash|--delete] [--keep-junk] --out DIR paths…
enum CLI {
    static func run(_ args: [String]) -> Int32 {
        var mode = ArchiveMode.single, name: String?, password: String?, encryption = ZipEncryption.aes256
        var deleteMode = DeleteMode.none, skipJunk = true, out: URL?, paths: [URL] = []
        var i = 0
        func next() -> String? { i += 1; return i < args.count ? args[i] : nil }
        while i < args.count {
            switch args[i] {
            case "--separate": mode = .separate
            case "--name": name = next()
            case "--password": password = next()
            case "--zipcrypto": encryption = .zipCrypto
            case "--trash": deleteMode = .trash
            case "--delete": deleteMode = .permanent
            case "--keep-junk": skipJunk = false
            case "--out": out = next().map { URL(fileURLWithPath: $0) }
            default: paths.append(URL(fileURLWithPath: args[i]))
            }
            i += 1
        }
        guard let out, !paths.isEmpty else {
            FileHandle.standardError.write("usage: K24Zipper --cli [--separate] [--name N] [--password P] [--zipcrypto] [--trash|--delete] --out DIR paths…\n".data(using: .utf8)!)
            return 2
        }
        let items = paths.map { url -> SourceItem in
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            return SourceItem(url: url, isDirectory: isDir.boolValue)
        }
        let plan = ArchivePlanner.plan(items: items, mode: mode,
                                       singleName: name ?? ArchivePlanner.defaultSingleName(for: items), destination: out)
        let results = ZipJob.run(archives: plan,
                                 options: JobOptions(destination: out, password: password, encryption: encryption,
                                                     deleteMode: deleteMode, skipJunkFiles: skipJunk),
                                 cancel: CancelFlag(), progress: { _ in })
        var failed = false
        for r in results {
            if let e = r.error { failed = true; print("FAIL \(r.name): \(e)") }
            else { print("OK   \(r.url!.path)\(r.originalsRemoved ? " (originals removed)" : "")") }
            if let note = r.deleteNote { print("     \(note)") }
        }
        return failed ? 1 : 0
    }
}
