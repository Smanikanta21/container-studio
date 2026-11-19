import Foundation
import StudioCore
import SwiftUI

@MainActor @Observable
final class ContainerFilesSession {
    let id: String
    let isPreview: Bool
    var path = "/"
    var entries: [ContainerFileEntry] = []
    var filePath: String?
    var text = ""
    var originalText = ""
    var checksum = ""
    var error: String?
    var loading = false
    var saving = false
    var dirty: Bool { filePath != nil && text != originalText }
    @ObservationIgnored private var request = UUID()
    init(id: String, isPreview: Bool = false) { self.id = id; self.isPreview = isPreview }

    private func runner() throws -> ProcessRunner {
        guard let cli = CLIBackend.discover() else { throw CommandError.missingCLI }
        return ProcessRunner(executable: cli)
    }
    func loadDirectory(_ destination: String) async {
        guard !isPreview else { return }
        let token = UUID(); request = token; loading = true; error = nil
        defer { if request == token { loading = false } }
        do {
            let data = try await runner().run(ContainerFilesystem.arguments(id: id, script: ContainerFilesystem.listScript, values: [destination]), outputLimit: 1_048_576)
            try Task.checkCancellation()
            let items = try ContainerFilesystem.decodeEntries(data)
            guard request == token else { return }
            path = destination; entries = items
        } catch is CancellationError {} catch { if request == token { self.error = error.localizedDescription } }
    }
    func open(_ entry: ContainerFileEntry) async {
        guard !isPreview else { return }
        let destination = (path as NSString).appendingPathComponent(entry.name)
        if entry.isDirectory { await loadDirectory(destination); return }
        let token = UUID(); request = token; loading = true; error = nil
        defer { if request == token { loading = false } }
        do {
            let data = try await runner().run(ContainerFilesystem.arguments(id: id, script: ContainerFilesystem.readScript, values: [destination]), outputLimit: 131_072)
            try Task.checkCancellation()
            let file = try ContainerFilesystem.decodeText(data)
            guard request == token else { return }
            filePath = destination; text = file.text; originalText = file.text; checksum = file.checksum
        } catch is CancellationError {} catch { if request == token { self.error = error.localizedDescription } }
    }
    func save(store: StudioStore) async {
        guard !isPreview, !store.isPreview else { return }
        guard let filePath, !saving, dirty else { return }
        guard text.utf8.count <= ContainerFilesystem.maximumFileBytes else {
            error = "Files larger than 64 KB can be edited in the terminal."; return
        }
        saving = true; error = nil
        defer { saving = false }
        let content = text
        do {
            let data = try await runner().run(ContainerFilesystem.arguments(id: id, script: ContainerFilesystem.saveScript, values: [filePath, checksum, content]))
            checksum = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            originalText = content
            store.record("Container file saved", detail: "\(id) · \(filePath)")
        } catch { self.error = error.localizedDescription }
    }
}

struct ContainerFilesPanel: View {
    @Bindable var store: StudioStore
    @Bindable var session: ContainerFilesSession
    let terminal: ContainerTerminalSession
    var body: some View {
        HSplitView {
            ContainerFileNavigator(store: store, session: session, terminal: terminal).frame(minWidth: 220, idealWidth: 260, maxWidth: 340)
            ContainerFileEditor(store: store, session: session).frame(minWidth: 300)
        }
    }
}

struct ContainerFileNavigator: View {
    @Bindable var store: StudioStore
    @Bindable var session: ContainerFilesSession
    let terminal: ContainerTerminalSession
    @State private var destination = "/"
    @State private var pendingEntry: ContainerFileEntry?
    @State private var discardPrompt = false
    @State private var actionTask: Task<Void, Never>?
    private var running: Bool { store.containers.first(where: { $0.id == session.id })?.isRunning == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Files", systemImage: "folder").font(.headline)
                Spacer()
                Button { navigate((session.path as NSString).deletingLastPathComponent.isEmpty ? "/" : (session.path as NSString).deletingLastPathComponent) } label: { Image(systemName: "arrow.up") }
                    .help("Parent folder").disabled(session.path == "/" || !running || session.loading || session.saving)
                Button { navigate(session.path) } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh files").disabled(!running || session.loading || session.saving)
            }
            TextField("Container path", text: $destination).textFieldStyle(.roundedBorder)
                .onSubmit { navigate(destination) }
            HStack {
                Button("Go") { navigate(destination) }.disabled(!running || session.loading || session.saving)
                Spacer()
                Button("Use in CLI") { terminal.terminal?.send(txt: "cd -- " + ContainerTools.shellQuote(session.path) + "\r") }
                    .disabled(!terminal.connected).help("Change the CLI to this folder")
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if !running { Text("Start the container to browse its files.").font(.callout).foregroundStyle(Palette.secondary).padding(.vertical, 12) }
                    else if session.entries.isEmpty { Text(session.loading ? "Loading…" : "Empty folder").foregroundStyle(Palette.secondary).padding(.vertical, 12) }
                    ForEach(session.entries) { entry in
                        Button {
                            if session.dirty && !entry.isDirectory { pendingEntry = entry; discardPrompt = true }
                            else { open(entry) }
                        } label: {
                            Label(entry.name, systemImage: entry.isDirectory ? "folder" : entry.isSymbolicLink ? "link" : "doc.text")
                                .font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                                .background(session.filePath == (session.path as NSString).appendingPathComponent(entry.name) ? Palette.accent.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(session.loading || session.saving || !running).accessibilityLabel(entry.name)
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Text("\(session.entries.count) items").font(.caption).foregroundStyle(Palette.secondary)
        }.padding(16).background(Palette.sidebar)
            .task { destination = session.path; if running { await session.loadDirectory(session.path) } }
            .onChange(of: session.path) { _, path in destination = path }
            .onChange(of: running) { _, value in if value { navigate(session.path) } }
            .confirmationDialog("Discard unsaved file changes?", isPresented: $discardPrompt) {
                Button("Discard Changes", role: .destructive) {
                    session.text = session.originalText
                    if let entry = pendingEntry { open(entry); pendingEntry = nil }
                }
                Button("Cancel", role: .cancel) { pendingEntry = nil }
            }
            .onDisappear { actionTask?.cancel() }
    }
    private func navigate(_ path: String) {
        guard path.hasPrefix("/"), !session.loading, !session.saving else { return }
        actionTask?.cancel(); actionTask = Task { await session.loadDirectory(path) }
    }
    private func open(_ entry: ContainerFileEntry) {
        actionTask?.cancel(); actionTask = Task { await session.open(entry) }
    }
}

struct ContainerFileEditor: View {
    @Bindable var store: StudioStore
    @Bindable var session: ContainerFilesSession
    @State private var saveTask: Task<Void, Never>?
    private var running: Bool { store.containers.first(where: { $0.id == session.id })?.isRunning == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let filePath = session.filePath {
                HStack(spacing: 12) {
                    Image(systemName: "doc.text").foregroundStyle(Palette.secondary)
                    Text(filePath).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Spacer(minLength: 8)
                    Text(session.dirty ? "Edited" : "Saved").font(.caption).foregroundStyle(Palette.secondary)
                    Button("Save") { saveTask = Task { await session.save(store: store) } }
                        .disabled(!session.dirty || session.saving || !running || session.loading).fixedSize()
                }.padding(14).fixedSize(horizontal: false, vertical: true)
                Divider()
                TextEditor(text: $session.text).font(.system(size: 13, design: .monospaced))
                    .scrollContentBackground(.hidden).padding(12).background(Palette.panel)
                    .disabled(session.saving || !running).accessibilityLabel("Container file contents")
            } else {
                ContentUnavailableView("Select a file", systemImage: "doc.text", description: Text("Browse a folder on the left. Text files up to 64 KB open here; use the CLI for larger files."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let error = session.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled).padding(14) }
        }.background(Palette.background).onDisappear { saveTask?.cancel() }
    }
}

struct ContainerWorkspaceView: View {
    @Bindable var store: StudioStore
    let id: String
    @Bindable var files: ContainerFilesSession
    @Bindable var terminal: ContainerTerminalSession

    var body: some View {
        HSplitView {
            ContainerFileNavigator(store: store, session: files, terminal: terminal)
                .frame(minWidth: 220, idealWidth: 250, maxWidth: 300)
            VSplitView {
                ContainerFileEditor(store: store, session: files).frame(minHeight: 200, idealHeight: 280)
                VStack(alignment: .leading, spacing: 12) {
                    Label("Container CLI", systemImage: "terminal").font(.subheadline.weight(.medium))
                    ContainerTerminalPanel(store: store, id: id, session: terminal)
                }.padding(16).frame(minHeight: 240, idealHeight: 300)
            }.frame(minWidth: 450)
        }.task { terminal.connect(id: id, store: store) }
    }
}

#Preview("File browser and editor") { ContainerFilesPanel(store: StudioPreview.store(), session: StudioPreview.files(), terminal: StudioPreview.terminal()).frame(width: 900, height: 500).preferredColorScheme(.dark) }
#Preview("File navigator") { ContainerFileNavigator(store: StudioPreview.store(), session: StudioPreview.files(), terminal: StudioPreview.terminal()).frame(width: 260, height: 600).preferredColorScheme(.dark) }
#Preview("File editor") { ContainerFileEditor(store: StudioPreview.store(), session: StudioPreview.files()).frame(width: 600, height: 450).preferredColorScheme(.dark) }
#Preview("Files and CLI layout") { ContainerWorkspaceView(store: StudioPreview.store(), id: "web-api", files: StudioPreview.files(), terminal: StudioPreview.terminal()).frame(width: 1000, height: 670).preferredColorScheme(.dark) }
