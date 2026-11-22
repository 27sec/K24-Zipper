import AppKit
import SwiftUI
import ZipperCore

struct ContentView: View {
    @Environment(ZipperModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HeaderView()
                    DropZone()
                    if !model.items.isEmpty { FileListSection() }
                    ModeSection()
                    if !model.items.isEmpty { OutputPreviewSection() }
                    SaveSection()
                    PasswordSection()
                    AfterZipSection()
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }
            Divider()
            FooterView()
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: Binding(get: { model.isRunning || model.results != nil },
                                    set: { if !$0 { model.dismissResults() } })) {
            ProgressSheet().environment(model)
        }
        .confirmationDialog(deleteTitle, isPresented: $model.showDeleteConfirmation) {
            Button(model.deleteMode == .trash ? "Zip and Move to Trash" : "Zip and Delete Permanently",
                   role: .destructive) { model.start() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.deleteMode == .trash
                 ? "Originals are moved to the Trash only after their archive has been written and verified."
                 : "Originals are deleted permanently after their archive has been written and verified. This cannot be undone.")
        }
    }

    private var deleteTitle: String {
        let n = model.items.count
        return "Remove \(n) original \(n == 1 ? "item" : "items") after zipping?"
    }
}

// MARK: - Building blocks

/// Small piece of view-local state (Command Line Tools builds can't expand the @State macro).
final class UIFlag: ObservableObject {
    @Published var on = false
}

struct Card<Content: View, Accessory: View>: View {
    let title: String
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                accessory
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.primary.opacity(0.04))
            content
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.1)))
    }
}

extension Card where Accessory == EmptyView {
    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.accessory = EmptyView()
        self.content = content()
    }
}

struct FieldRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).font(.headline).frame(width: 120, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

func formatBytes(_ b: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: b), countStyle: .file)
}

struct FileIcon: View {
    let url: URL
    var size: CGFloat = 22
    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
            .resizable()
            .frame(width: size, height: size)
    }
}

// MARK: - Sections

struct HeaderView: View {
    var body: some View {
        HStack(spacing: 16) {
            ZipIcon().frame(width: 60, height: 60)
            Divider().frame(height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text("Create ZIP archive").font(.system(size: 22, weight: .bold))
                Text("Bundle files without compression").foregroundStyle(.secondary)
            }
        }
    }
}

struct DropZone: View {
    @Environment(ZipperModel.self) private var model
    @StateObject private var drop = UIFlag()

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "folder.fill")
                .font(.system(size: 36))
                .foregroundStyle(Color.accentColor.gradient)
            Text("Drop files or folders here").font(.headline)
            Button("Choose Files…") { model.chooseFiles() }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, model.items.isEmpty ? 34 : 16)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(drop.on ? Color.accentColor.opacity(0.1) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(drop.on ? Color.accentColor : Color.secondary.opacity(0.5),
                          style: StrokeStyle(lineWidth: drop.on ? 2 : 1, dash: [6, 4])))
        .dropDestination(for: URL.self) { urls, _ in
            model.add(urls)
            return !urls.isEmpty
        } isTargeted: { drop.on = $0 }
        .animation(.easeOut(duration: 0.15), value: drop.on)
    }
}

struct FileListSection: View {
    @Environment(ZipperModel.self) private var model

    var body: some View {
        Card(title: "Files") {
            HStack(spacing: 6) {
                Button("Clear") { model.removeAll() }
                Button("Add…") { model.chooseFiles() }
            }
            .disabled(model.isRunning)
        } content: {
            VStack(spacing: 0) {
                ForEach(model.items) { item in
                    HStack(spacing: 10) {
                        FileIcon(url: item.url, size: 26)
                        Text(item.name).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Group {
                            if let size = model.sizes[item.id] {
                                Text(formatBytes(size))
                            } else {
                                ProgressView().controlSize(.small)
                            }
                        }
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        Button { model.remove(item) } label: {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 16))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Remove from list")
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .help(item.url.path)
                    Divider().padding(.leading, 14)
                }
                HStack {
                    let n = model.items.count
                    Text("\(n) \(n == 1 ? "item" : "items") · \(formatBytes(model.totalSize))\(model.sizesPending ? "…" : "")")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.primary.opacity(0.03))
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.add(urls)
            return !urls.isEmpty
        }
    }
}

struct ModeSection: View {
    @Environment(ZipperModel.self) private var model

    var body: some View {
        @Bindable var model = model
        FieldRow(label: "Archive mode") {
            Picker("", selection: $model.mode) {
                ForEach(ArchiveMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(model.mode == .single
                 ? "Combine every item into one ZIP."
                 : "Create one ZIP for each file or folder.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

struct OutputPreviewSection: View {
    @Environment(ZipperModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let plan = model.plan
        Card(title: "Output preview") {
            VStack(alignment: .leading, spacing: 10) {
                if model.mode == .single, let archive = plan.first {
                    HStack {
                        Text("Archive name")
                        TextField(ArchivePlanner.defaultSingleName(for: model.items), text: $model.singleName)
                            .textFieldStyle(.roundedBorder)
                        Text(".zip").foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        Image(systemName: "doc.zipper").foregroundStyle(Color.accentColor)
                        Text(archive.outputName).fontWeight(.medium)
                        Text("containing").foregroundStyle(.secondary)
                    }
                    ForEach(Array(zip(archive.items, archive.rootNames)), id: \.0.id) { item, root in
                        HStack(spacing: 8) {
                            FileIcon(url: item.url, size: 18)
                            Text(root + (item.isDirectory ? "/" : ""))
                        }
                        .padding(.leading, 26)
                    }
                } else {
                    ForEach(plan) { archive in
                        if let item = archive.items.first {
                            HStack(spacing: 8) {
                                FileIcon(url: item.url, size: 22)
                                Text(item.name).lineLimit(1).truncationMode(.middle)
                                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                                Text(archive.outputName).lineLimit(1).truncationMode(.middle)
                                    .fontWeight(.medium)
                            }
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct SaveSection: View {
    @Environment(ZipperModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            FieldRow(label: "Save to") {
                HStack {
                    HStack(spacing: 8) {
                        FileIcon(url: model.destination, size: 18)
                        Text(model.destination.lastPathComponent).lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15)))
                    .help(model.destination.path)
                    .onTapGesture(count: 2) { NSWorkspace.shared.open(model.destination) }
                    Button("Choose…") { model.chooseDestination() }
                }
            }
            FieldRow(label: "Compression") {
                Text("Store Only")
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                    .foregroundStyle(.secondary)
                Text("Files are stored without compression.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct PasswordSection: View {
    @Environment(ZipperModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Card(title: "Password protection") {
            Toggle("", isOn: $model.passwordEnabled.animation(.easeOut(duration: 0.15)))
                .toggleStyle(.switch)
                .labelsHidden()
        } content: {
            if model.passwordEnabled {
                VStack(alignment: .leading, spacing: 10) {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                        GridRow {
                            Text("Password")
                            RevealableField(text: $model.password, placeholder: "Password")
                        }
                        GridRow {
                            Text("Confirm password")
                            RevealableField(text: $model.confirmPassword, placeholder: "Repeat password")
                        }
                        GridRow {
                            Text("Encryption")
                            Picker("", selection: $model.encryption) {
                                Text("AES-256").tag(ZipEncryption.aes256)
                                Text("ZipCrypto (legacy, most compatible)").tag(ZipEncryption.zipCrypto)
                            }
                            .labelsHidden()
                        }
                    }
                    if let problem = model.passwordProblem, !model.password.isEmpty || !model.confirmPassword.isEmpty {
                        Label(problem, systemImage: "exclamationmark.circle.fill")
                            .foregroundStyle(.red).font(.callout)
                    } else if let warning = model.passwordWarning {
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange).font(.callout)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        if model.mode == .separate && model.plan.count > 1 {
                            Text("The same password applies to all archives.")
                        }
                        if model.encryption == .aes256 {
                            Text("Requires an AES-compatible app such as Keka, 7-Zip or WinRAR. macOS Archive Utility can't open it.")
                        } else {
                            Text("Opens in macOS Archive Utility and Windows Explorer, but ZipCrypto is weak and can be cracked.")
                        }
                        Text("File names remain visible inside the archive.")
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
            }
        }
    }
}

struct RevealableField: View {
    @Binding var text: String
    let placeholder: String
    @StateObject private var reveal = UIFlag()

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if reveal.on {
                    TextField(placeholder, text: $text)
                } else {
                    SecureField(placeholder, text: $text)
                }
            }
            .textFieldStyle(.roundedBorder)
            Button { reveal.on.toggle() } label: {
                Image(systemName: reveal.on ? "eye.slash" : "eye")
                    .frame(width: 18)
            }
            .buttonStyle(.borderless)
            .help(reveal.on ? "Hide password" : "Show password")
        }
    }
}

struct AfterZipSection: View {
    @Environment(ZipperModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Card(title: "After zipping") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Delete original files after a successful zip", isOn: $model.deleteOriginals)
                if model.deleteOriginals {
                    Picker("", selection: $model.deleteMode) {
                        Text("Move to Trash").tag(DeleteMode.trash)
                        Text("Delete permanently").tag(DeleteMode.permanent)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    .padding(.leading, 20)
                    Text("Each original is removed only after its archive has been written and verified. If an archive fails, its originals are kept.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !model.destinationInsideSources.isEmpty {
                        Label("The save folder is inside \(model.destinationInsideSources.map(\.name).joined(separator: ", ")), so it will be kept.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.callout).foregroundStyle(.orange)
                    }
                }
                Toggle("Skip .DS_Store and other macOS metadata files", isOn: $model.skipJunkFiles)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct FooterView: View {
    @Environment(ZipperModel.self) private var model

    var body: some View {
        HStack {
            let n = model.plan.count
            Text(model.items.isEmpty
                 ? "Add files to get started"
                 : "\(n) \(n == 1 ? "archive" : "archives") · Estimated total: \(formatBytes(model.totalSize))")
                .foregroundStyle(.secondary)
            Spacer()
            Button(model.createButtonTitle) { model.requestCreate() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canCreate)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(.bar)
    }
}

// MARK: - Progress / results

struct ProgressSheet: View {
    @Environment(ZipperModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let results = model.results {
                ResultsView(results: results)
            } else if let p = model.progress {
                Text(p.archiveName.isEmpty ? p.phase : "Creating \(p.archiveName)")
                    .font(.headline)
                if p.archiveCount > 1 && p.archiveIndex > 0 {
                    Text("Archive \(p.archiveIndex) of \(p.archiveCount)").foregroundStyle(.secondary)
                }
                ProgressView(value: p.bytesTotal == 0 ? 0 : Double(p.bytesDone) / Double(p.bytesTotal))
                HStack {
                    Text(p.phase == "Zipping" ? p.currentFile : p.phase)
                        .lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(formatBytes(p.bytesDone)) of \(formatBytes(p.bytesTotal))")
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.callout)
                HStack {
                    Spacer()
                    Button("Cancel") { model.cancel() }.keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(20)
        .frame(width: 440)
        .interactiveDismissDisabled(model.isRunning)
    }
}

struct ResultsView: View {
    @Environment(ZipperModel.self) private var model
    let results: [ArchiveResult]

    var body: some View {
        let failed = results.filter { $0.error != nil }
        HStack(spacing: 10) {
            Image(systemName: failed.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 28))
                .foregroundStyle(failed.isEmpty ? .green : .orange)
            Text(failed.isEmpty
                 ? "Created \(results.count) \(results.count == 1 ? "archive" : "archives")"
                 : "\(results.count - failed.count) of \(results.count) archives created")
                .font(.headline)
        }
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(results) { r in
                    VStack(alignment: .leading, spacing: 2) {
                        Label(r.name, systemImage: r.error == nil ? "doc.zipper" : "xmark.octagon.fill")
                            .foregroundStyle(r.error == nil ? Color.primary : Color.red)
                        if let e = r.error {
                            Text(e).font(.callout).foregroundStyle(.secondary).padding(.leading, 24)
                        }
                        if r.originalsRemoved {
                            Text(model.deleteMode == .trash ? "Originals moved to Trash" : "Originals deleted")
                                .font(.callout).foregroundStyle(.secondary).padding(.leading, 24)
                        }
                        if let note = r.deleteNote {
                            Text(note).font(.callout).foregroundStyle(.orange).padding(.leading, 24)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 220)
        HStack {
            Spacer()
            Button("Show in Finder") { model.revealResults() }
            Button("Done") { model.dismissResults() }
                .keyboardShortcut(.defaultAction)
        }
    }
}
