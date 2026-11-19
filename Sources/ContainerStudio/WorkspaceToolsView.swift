import AppKit
import StudioCore
import SwiftUI
import UniformTypeIdentifiers

struct StudioSettingsModal: View {
    @Bindable var store: StudioStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("Settings").font(.headline); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }.padding(.horizontal, 20).frame(height: 76)
            Divider()
            StudioSettingsView(store: store)
        }.frame(width: 700, height: 560).background(Palette.background)
    }
}

struct StudioSettingsView: View {
    @Environment(\.openWindow) private var openWindow
    @AppStorage("studio.appearance") private var appearance = StudioAppearance.system
    @Bindable var store: StudioStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Settings").font(.system(size: 28, weight: .semibold))
                GroupBox("Appearance") {
                    VStack(alignment: .leading, spacing: 12) {
                    Picker("Appearance", selection: $appearance) {
                        ForEach(StudioAppearance.allCases, id: \.self) { choice in
                            Text(choice.title).tag(choice)
                        }
                    }.pickerStyle(.segmented)
                    Text("Light uses warm orange. Dark uses graphite blue. System follows your Mac.")
                        .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                    }.padding(12)
                }
                Text("Manage the engine and this workspace.").foregroundStyle(Palette.secondary)
                GroupBox("Docker migration") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Import stopped Linux arm64 containers from your local Docker engine, including copied files and supported configuration.")
                            .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                        Button("Import from Docker…") {
                            openWindow(id: "studio")
                            store.showDockerMigration()
                        }
                            .disabled(store.setupState != .ready || store.dockerMigration.isImporting)
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .top) {
                            Label("Apple container engine", systemImage: "server.rack").font(.headline)
                            Spacer()
                            if store.isLoading { ProgressView().controlSize(.small) }
                            Text(engineStatus).foregroundStyle(Palette.secondary)
                        }
                        LabeledContent("Executable", value: store.environment?.executable?.path ?? CLIBackend.discover()?.path ?? "Not found")
                        LabeledContent("Version", value: store.environment?.cliVersion ?? "Not checked")
                        HStack {
                            Button("Check Engine") { store.checkEnvironment() }
                                .accessibilityLabel("Check Engine")
                                .disabled(store.isLoading || store.isSettingUp || store.isPerformingAction)
                            if store.setupState != .ready {
                                Button("Open Engine Setup") { store.hasOpenedWorkspace = false; store.setUpEnvironment() }
                                    .disabled(store.isLoading || store.isSettingUp)
                            }
                        }
                        Text("Checks the CLI and engine status. It does not start or stop containers.")
                            .font(.caption).foregroundStyle(Palette.secondary)
                        if let error = store.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                    }.padding(12)
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Container access", systemImage: "terminal").font(.headline)
                        Text("Double-click a container to open its filesystem and embedded CLI. Use Scripts to run a script with output here. The container must be running, and the chosen shell must be installed in its image.")
                        Text("Scripts have a 60-second timeout and a 1 MB output limit. Activity keeps up to 200 events for this app session; script contents and output are not saved in Activity.")
                            .font(.caption).foregroundStyle(Palette.secondary)
                    }.padding(12)
                }
            }.padding(28).frame(maxWidth: 780, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
        }.background(Palette.background)
    }

    private var engineStatus: String {
        switch store.setupState {
        case .ready: "Ready"
        case .checking: "Checking"
        case .missingCLI: "CLI not installed"
        case .stopped: "Stopped"
        case .missingKernel: "Kernel required"
        case .unavailable: "Unavailable"
        case .unsupported: "Unsupported Mac"
        }
    }
}

struct StudioActivityView: View {
    @Bindable var store: StudioStore
    private var events: [StudioActivity] {
        store.activity.filter { store.activityQuery.isEmpty || ($0.title + " " + $0.detail).localizedCaseInsensitiveContains(store.activityQuery) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Activity").font(.system(size: 28, weight: .semibold))
            Text("Engine checks, container actions, and script results from this app session.")
                .foregroundStyle(Palette.secondary)
            HStack {
                TextField("Search activity", text: $store.activityQuery).textFieldStyle(.roundedBorder)
                Button("Clear") { store.activity.removeAll() }.disabled(store.activity.isEmpty)
            }
            if events.isEmpty {
                ContentUnavailableView(store.activity.isEmpty ? "No activity yet" : "No matching events", systemImage: "clock", description: Text("Refresh the workspace or use a container to see events here."))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(events) { event in
                            HStack(alignment: .top, spacing: 14) {
                                Image(systemName: event.failed ? "exclamationmark.circle" : "clock")
                                    .foregroundStyle(event.failed ? Color.red : Palette.accent).padding(.top, 2)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(event.title).fontWeight(.medium)
                                    Text(event.detail).foregroundStyle(Palette.secondary).textSelection(.enabled)
                                }
                                Spacer()
                                Text(event.date.formatted(date: .omitted, time: .standard))
                                    .font(.caption.monospacedDigit()).foregroundStyle(Palette.secondary)
                            }.padding(.vertical, 16)
                            Divider()
                        }
                    }
                }
            }
            Text("\(events.count) events · Current session only").font(.caption).foregroundStyle(Palette.secondary)
        }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Palette.background)
    }
}

@MainActor @Observable
final class ContainerSession {
    let id: String
    let isPreview: Bool
    var logs = ""
    var logsError: String?
    var logsLoading = false
    var logsUpdated: Date?
    var script = ""
    var stdout = ""
    var stderr = ""
    var exitCode: Int32?
    var scriptError: String?
    var scriptRunning = false
    @ObservationIgnored private var logRequest = UUID()
    @ObservationIgnored private var scriptTask: Task<Void, Never>?
    @ObservationIgnored private var scriptRequest = UUID()

    init(id: String, isPreview: Bool = false) { self.id = id; self.isPreview = isPreview }

    func loadLogs(lines: Int, boot: Bool) async {
        guard !isPreview else { return }
        let request = UUID(); logRequest = request
        logsLoading = true; logsError = nil
        defer { if logRequest == request { logsLoading = false } }
        do {
            guard let executable = CLIBackend.discover() else { throw CommandError.missingCLI }
            let text = try await CLIBackend(executable: executable).logs(id: id, lines: lines, boot: boot)
            try Task.checkCancellation()
            guard logRequest == request else { return }
            logs = text; logsUpdated = Date()
        } catch is CancellationError {} catch {
            if logRequest == request { logsError = error.localizedDescription }
        }
    }

    func clearLogs() { logRequest = UUID(); logs = ""; logsError = nil; logsUpdated = nil; logsLoading = false }

    func run(shell: String, store: StudioStore) {
        guard !store.isPreview else { return }
        guard !scriptRunning else { return }
        guard store.containers.first(where: { $0.id == id })?.isRunning == true else {
            scriptError = "Start the container before running a script."; return
        }
        let source = script
        do { _ = try ContainerTools.scriptArguments(id: id, shell: shell, script: source) }
        catch { scriptError = error.localizedDescription; return }
        scriptRunning = true; stdout = ""; stderr = ""; exitCode = nil; scriptError = nil
        let request = UUID(); scriptRequest = request
        store.record("Script started", detail: "\(id) · \(shell)")
        scriptTask = Task { [weak self] in
            guard let self else { return }
            defer { if scriptRequest == request { scriptRunning = false } }
            do {
                guard let executable = CLIBackend.discover() else { throw CommandError.missingCLI }
                let result = try await CLIBackend(executable: executable).runScript(id: id, shell: shell, script: source)
                try Task.checkCancellation()
                guard scriptRequest == request else { return }
                stdout = result.stdout; stderr = result.stderr; exitCode = result.exitCode
                store.record("Script finished", detail: "\(id) · Exit \(result.exitCode)", failed: result.exitCode != 0)
            } catch is CancellationError {
                if scriptRequest == request { scriptError = "Execution cancelled. Processes started inside the container may need to be stopped there." }
                store.record("Script cancelled", detail: id)
            } catch {
                if scriptRequest == request { scriptError = error.localizedDescription }
                store.record("Script failed", detail: "\(id) · \(error.localizedDescription)", failed: true)
            }
        }
    }

    func cancelScript() { scriptTask?.cancel() }
}

enum ContainerToolTab: String, CaseIterable { case workspace = "Files & CLI", logs = "Logs", scripts = "Scripts" }

struct ContainerToolsView: View {
    @Bindable var store: StudioStore
    let container: StudioContainer
    @State private var session: ContainerSession
    @State private var tab: ContainerToolTab
    @State private var terminal: ContainerTerminalSession
    @State private var files: ContainerFilesSession

    init(store: StudioStore, container: StudioContainer, tab: ContainerToolTab) {
        self.store = store; self.container = container
        _tab = State(initialValue: tab)
        _terminal = State(initialValue: store.isPreview ? StudioPreview.terminal() : ContainerTerminalSession())
        _session = State(initialValue: store.isPreview ? StudioPreview.logs(id: container.id) : ContainerSession(id: container.id))
        _files = State(initialValue: store.isPreview ? StudioPreview.files(id: container.id) : ContainerFilesSession(id: container.id))
    }

    var body: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 20) { identity; Spacer(minLength: 16); tabs }
                VStack(alignment: .leading, spacing: 12) { identity; tabs }
            }.padding(20).fixedSize(horizontal: false, vertical: true)
            Divider()
            if tab == .workspace { ContainerWorkspaceView(store: store, id: container.id, files: files, terminal: terminal) }
            else if tab == .logs { DetailedLogsView(session: session) }
            else { ContainerScriptsView(store: store, session: session) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Palette.background)
            .onChange(of: files.dirty) { _, dirty in store.workspaceDirty = dirty }
            .onDisappear { session.cancelScript(); terminal.disconnect(); store.workspaceDirty = false }
    }

    private var identity: some View {
        HStack(spacing: 12) {
            Button { store.navigate(to: "Containers") } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.bordered).help("Back to containers").accessibilityLabel("Back to containers")
            VStack(alignment: .leading, spacing: 4) {
                Text(container.id).font(.headline).lineLimit(1).truncationMode(.middle)
                Text(container.shortImage).font(.caption).foregroundStyle(Palette.secondary).lineLimit(1)
            }
            StateBadge(state: store.containers.first(where: { $0.id == container.id })?.state ?? container.state)
        }
    }
    private var tabs: some View {
        Picker("Container tools", selection: $tab) {
            ForEach(ContainerToolTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }.pickerStyle(.segmented).labelsHidden().frame(width: 280)
    }
}

struct DetailedLogsView: View {
    @Bindable var session: ContainerSession
    @State private var source = "Output"
    @State private var lines = 200
    @State private var query = ""
    @State private var follow = false
    @State private var refresh = 0
    @Environment(\.scenePhase) private var scenePhase

    private var displayedLines: [(offset: Int, element: String)] {
        Array(session.logs.components(separatedBy: "\n").enumerated())
            .filter { query.isEmpty || $0.element.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Picker("Log source", selection: $source) { Text("App output").tag("Output"); Text("Boot logs").tag("Boot") }
                    .frame(width: 190)
                Picker("Lines", selection: $lines) { ForEach([200, 1000, 5000], id: \.self) { Text("Last \($0)").tag($0) } }.frame(width: 170)
                Toggle("Live tail", isOn: $follow).toggleStyle(.checkbox)
                Spacer()
            }
            HStack {
                TextField("Search log text", text: $query).textFieldStyle(.roundedBorder)
                Button { refresh += 1 } label: { Label("Refresh", systemImage: "arrow.clockwise") }.disabled(session.logsLoading).fixedSize()
                Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(session.logs, forType: .string) }.disabled(session.logs.isEmpty)
                Button("Export…") { exportLogs() }.disabled(session.logs.isEmpty)
            }
            if let error = session.logsError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 3) {
                    if session.logs.isEmpty {
                        Text(session.logsLoading ? "Loading logs…" : "No logs available for this source.").foregroundStyle(Palette.secondary)
                    } else if displayedLines.isEmpty {
                        Text("No lines match your search.").foregroundStyle(Palette.secondary)
                    } else {
                        ForEach(displayedLines, id: \.offset) { line in
                            HStack(alignment: .top, spacing: 16) {
                                Text("\(line.offset + 1)").foregroundStyle(Palette.secondary).frame(minWidth: 36, alignment: .trailing)
                                Text(line.element.isEmpty ? " " : line.element).textSelection(.enabled)
                            }.font(.system(size: 12, design: .monospaced))
                        }
                    }
                }.padding(16).frame(minWidth: 740, alignment: .leading)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Palette.panel).clipShape(RoundedRectangle(cornerRadius: 8))
            HStack {
                if session.logsLoading { ProgressView().controlSize(.mini) }
                Text(follow ? "Live tail · Refreshes every 2 seconds while active" : "Refreshes on demand")
                Spacer()
                if let date = session.logsUpdated { Text("Updated \(date.formatted(date: .omitted, time: .standard))") }
            }.font(.caption).foregroundStyle(Palette.secondary)
        }.padding(20)
            .onChange(of: source) { _, _ in session.clearLogs() }
            .task(id: "\(source)-\(lines)-\(follow)-\(refresh)-\(scenePhase)") {
                guard scenePhase == .active else { return }
                await session.loadLogs(lines: lines, boot: source == "Boot")
                while follow && !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(2)); try Task.checkCancellation() }
                    catch { return }
                    await session.loadLogs(lines: lines, boot: source == "Boot")
                }
            }
    }

    private func exportLogs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "container-\(source.lowercased())-logs.txt"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do { try session.logs.write(to: url, atomically: true, encoding: .utf8) }
            catch { session.logsError = "Export failed: \(error.localizedDescription)" }
        }
    }
}

struct ContainerScriptsView: View {
    @Bindable var store: StudioStore
    @Bindable var session: ContainerSession
    @State private var shell = "/bin/sh"
    @State private var outputTab = "stdout"
    private var running: Bool { store.containers.first(where: { $0.id == session.id })?.isRunning == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Picker("Shell", selection: $shell) { Text("/bin/sh").tag("/bin/sh"); Text("/bin/bash").tag("/bin/bash") }.frame(width: 210).disabled(session.scriptRunning)
                Spacer()
                if session.scriptRunning {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { session.cancelScript() }
                } else {
                    Button("Run Script") { outputTab = "stdout"; session.run(shell: shell, store: store) }
                        .buttonStyle(.borderedProminent).tint(Palette.accent)
                        .disabled(!running || session.script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            Text(running ? "Runs inside \(session.id). The chosen shell must exist in this image." : "Start this container to open a shell or run a script.")
                .font(.caption).foregroundStyle(Palette.secondary)
            Text("Script").font(.subheadline.weight(.medium))
            TextEditor(text: $session.script).font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden).padding(10).background(Palette.panel)
                .clipShape(RoundedRectangle(cornerRadius: 8)).frame(minHeight: 150).disabled(session.scriptRunning)
                .accessibilityLabel("Script to execute in \(session.id)")
            HStack {
                Picker("Output stream", selection: $outputTab) { Text("stdout").tag("stdout"); Text("stderr").tag("stderr") }.pickerStyle(.segmented).frame(width: 190)
                if let exit = session.exitCode { Text("Exit \(exit)").foregroundStyle(exit == 0 ? Palette.secondary : Color.red) }
                Spacer()
                Button("Copy Output") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(outputTab == "stdout" ? session.stdout : session.stderr, forType: .string)
                }.disabled((outputTab == "stdout" ? session.stdout : session.stderr).isEmpty)
            }
            if let error = session.scriptError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            ScrollView([.horizontal, .vertical]) {
                let output = outputTab == "stdout" ? session.stdout : session.stderr
                Text(output.isEmpty ? (session.scriptRunning ? "Running…" : "No \(outputTab) output.") : output)
                    .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading).padding(14)
            }.frame(minHeight: 140, maxHeight: .infinity).background(Palette.panel).clipShape(RoundedRectangle(cornerRadius: 8))
            Text("60-second timeout · 1 MB output limit · Closing cancels the exec client; child processes may remain in the container")
                .font(.caption).foregroundStyle(Palette.secondary)
        }.padding(20)
    }

}

#Preview("Settings modal") { StudioSettingsModal(store: StudioPreview.store()).preferredColorScheme(.dark) }
#Preview("Settings content") { StudioSettingsView(store: StudioPreview.store()).frame(width: 700, height: 560).preferredColorScheme(.light) }
#Preview("Activity") { StudioActivityView(store: StudioPreview.store()).frame(width: 900, height: 650).preferredColorScheme(.dark) }
#Preview("Container tools") { ContainerToolsView(store: StudioPreview.store(), container: StudioPreview.container(), tab: .workspace).frame(width: 1000, height: 670).preferredColorScheme(.dark) }
#Preview("Detailed logs") { DetailedLogsView(session: StudioPreview.logs()).frame(width: 900, height: 600).preferredColorScheme(.dark) }
#Preview("Scripts") { ContainerScriptsView(store: StudioPreview.store(), session: StudioPreview.logs()).frame(width: 900, height: 600).preferredColorScheme(.dark) }
