import AppKit
import SwiftUI
import ZipperCore

/// Developer aid for README screenshots: renders the main window offscreen to a PNG.
///
///     K24Zipper --snapshot out.png [--dark] [--single] [--password] [--delete] files…
///
/// Saved preferences are restored afterwards, so taking a snapshot never changes the user's settings.
@MainActor
enum Snapshot {
    /// An offscreen window that draws its controls as if it were the active window.
    private final class ActiveWindow: NSWindow {
        override var isKeyWindow: Bool { true }
        override var isMainWindow: Bool { true }
    }

    static func run(_ args: [String]) -> Bool {
        let output = URL(fileURLWithPath: args[0])
        let flags = Set(args.dropFirst().filter { $0.hasPrefix("--") })
        let files = args.dropFirst().filter { !$0.hasPrefix("--") }.map { URL(fileURLWithPath: $0) }

        let domain = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        let savedPrefs = UserDefaults.standard.persistentDomain(forName: domain)
        defer {
            if let savedPrefs {
                UserDefaults.standard.setPersistentDomain(savedPrefs, forName: domain)
            } else {
                UserDefaults.standard.removePersistentDomain(forName: domain)
            }
            UserDefaults.standard.synchronize() // flush before the process exits
        }

        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: flags.contains("--dark") ? .darkAqua : .aqua)

        let model = ZipperModel.shared
        model.destination = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? model.destination
        model.add(files)
        model.mode = flags.contains("--single") ? .single : .separate
        model.encryption = .aes256
        if flags.contains("--password") {
            model.passwordEnabled = true
            model.password = "correct horse battery"
            model.confirmPassword = model.password
        }
        model.deleteOriginals = flags.contains("--delete")
        model.deleteMode = .trash
        model.skipJunkFiles = true

        // Let the background size calculations finish.
        let deadline = Date().addingTimeInterval(10)
        while model.sizesPending && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }

        let size = NSSize(width: 540, height: 100)
        let root = ContentView()
            .environment(model)
            .environment(\.controlActiveState, .key)
            .frame(width: size.width)
        let host = NSHostingView(rootView: root)
        // Size the window to the full content so nothing is scrolled out of view.
        let fitting = host.fittingSize
        let height = max(fitting.height, 640)
        host.frame = NSRect(x: 0, y: 0, width: size.width, height: height)

        let window = ActiveWindow(contentRect: host.frame, styleMask: [.titled, .closable, .miniaturizable],
                                  backing: .buffered, defer: false)
        window.title = "K24 Zipper"
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))

        // Capture the frame view so the title bar is included.
        guard let frameView = window.contentView?.superview,
              let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return false }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        window.orderOut(nil)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: output)) != nil
    }
}
