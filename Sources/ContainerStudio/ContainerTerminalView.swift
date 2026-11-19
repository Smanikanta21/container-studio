import AppKit
import StudioCore
import SwiftUI
import SwiftTerm

@MainActor @Observable
final class ContainerTerminalSession: NSObject, LocalProcessTerminalViewDelegate {
    var shell = "/bin/sh"
    var status = "Disconnected"
    var connected = false
    var terminal: LocalProcessTerminalView?
    private var closing = false

    func connect(id: String, store: StudioStore) {
        guard !store.isPreview else { status = "Canvas preview · No live connection"; return }
        guard !connected else { return }
        guard store.containers.first(where: { $0.id == id })?.isRunning == true else {
            status = "Start the container to connect."; return
        }
        do {
            guard let cli = CLIBackend.discover() else { throw CommandError.missingCLI }
            let args = try ContainerTools.terminalArguments(id: id, shell: shell)
            let view = LocalProcessTerminalView(frame: .zero)
            view.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
            view.processDelegate = self
            view.nativeBackgroundColor = NSColor(red: 0.08, green: 0.09, blue: 0.11, alpha: 1)
            view.nativeForegroundColor = NSColor(white: 0.92, alpha: 1)
            view.setAccessibilityIdentifier("container-cli")
            view.setAccessibilityLabel("Interactive CLI inside container \(id)")
            terminal = view; connected = true; closing = false; status = "Connected · \(shell)"
            view.startProcess(executable: cli.path, args: args)
            store.record("Container terminal opened", detail: "\(id) · \(shell)")
        } catch { status = error.localizedDescription }
    }

    func disconnect() {
        closing = true
        if connected { terminal?.terminate() }
        connected = false; status = "Disconnected"
        // The terminal stays visible until reconnect so the user can still copy its output.
    }

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor [weak self, weak source] in
            guard let self, source === terminal else { return }
            connected = false
            if !closing {
                status = exitCode.map { value in
                    let signal = value & 0x7f
                    return signal == 0 ? "Shell exited · \((value >> 8) & 0xff)" : "Shell ended · Signal \(signal)"
                } ?? "Shell could not start. Check the container and shell path."
            }
        }
    }
}

struct EmbeddedContainerTerminal: NSViewRepresentable {
    let terminal: LocalProcessTerminalView
    func makeNSView(context: Context) -> LocalProcessTerminalView { terminal }
    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}
}

struct ContainerTerminalPanel: View {
    @Bindable var store: StudioStore
    let id: String
    @Bindable var session: ContainerTerminalSession
    private var running: Bool { store.containers.first(where: { $0.id == id })?.isRunning == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack { shellPicker; Spacer(); connectionControls }
                VStack(alignment: .leading, spacing: 10) { shellPicker; connectionControls }
            }
            if let terminal = session.terminal {
                EmbeddedContainerTerminal(terminal: terminal).id(ObjectIdentifier(terminal))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                ContentUnavailableView("Container CLI", systemImage: "terminal", description: Text(running ? "Connect to work directly inside this container." : "Start this container to access its CLI and filesystem."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(Palette.panel)
            }
            Text(session.status).font(.caption).foregroundStyle(Palette.secondary).textSelection(.enabled)
        }.onChange(of: running) { _, value in if !value { session.disconnect() } }
    }

    private var shellPicker: some View {
        Picker("Shell", selection: $session.shell) { Text("/bin/sh").tag("/bin/sh"); Text("/bin/bash").tag("/bin/bash") }
            .frame(width: 200).disabled(session.connected)
    }
    private var connectionControls: some View {
        HStack(spacing: 10) {
            if session.connected {
                Button("Interrupt") { session.terminal?.send(txt: "\u{03}") }.help("Send Ctrl-C to the container")
                Button("Disconnect") { session.disconnect() }
            } else {
                Button("Connect") { session.connect(id: id, store: store) }.disabled(!running)
            }
        }.fixedSize(horizontal: true, vertical: false)
    }
}

#Preview("Embedded CLI") { EmbeddedContainerTerminal(terminal: StudioPreview.terminal().terminal!).frame(width: 700, height: 300) }
#Preview("Terminal controls") { ContainerTerminalPanel(store: StudioPreview.store(), id: "web-api", session: StudioPreview.terminal()).padding(16).frame(width: 700, height: 340).preferredColorScheme(.dark) }
