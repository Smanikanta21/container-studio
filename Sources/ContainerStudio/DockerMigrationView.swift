import AppKit
import Foundation
import Observation
import StudioCore
import SwiftUI

struct DockerImportResult: Identifiable {
    let id: String
    let source: String
    let destination: String?
    let detail: String
    let directory: URL
}

@MainActor @Observable
final class DockerMigrationStore {
    var isPreview = false
    var inventory: DockerInventory?
    var selected: Set<String> = []
    var acknowledged = false
    var isScanning = false
    var isImporting = false
    var progress = ""
    var results: [DockerImportResult] = []
    @ObservationIgnored private var task: Task<Void, Never>?
    var sources: [DockerSource] {
        if case .available(_, let sources) = inventory { return sources }
        return []
    }
    var selectedSources: [DockerSource] { sources.filter { selected.contains($0.id) && $0.canImport } }
    var canImport: Bool { !isScanning && !isImporting && !selectedSources.isEmpty && acknowledged && results.isEmpty }

    func scan() {
        guard !isPreview else { return }
        guard !isImporting else { return }
        task?.cancel(); isScanning = true; inventory = nil
        selected = []; acknowledged = false; results = []; progress = "Checking the local Docker engine…"
        task = Task {
            guard let docker = DockerMigrationClient.discoverDocker(), let cli = CLIBackend.discover() else {
                inventory = .missingCLI; isScanning = false; return
            }
            let inventory = await DockerMigrationClient(docker: docker, container: cli).inventory()
            guard !Task.isCancelled else { return }
            self.inventory = inventory; isScanning = false; progress = ""
        }
    }
    func start(onFinish: @escaping @MainActor ([DockerImportResult]) -> Void) {
        guard !isPreview else { return }
        guard canImport, let docker = DockerMigrationClient.discoverDocker(), let cli = CLIBackend.discover() else { return }
        let selection = selectedSources
        let client = DockerMigrationClient(docker: docker, container: cli)
        isImporting = true; results = []
        task = Task {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ContainerStudio/Migrations/" + UUID().uuidString)
            for source in selection {
                if Task.isCancelled { break }
                let directory = base.appendingPathComponent(String(source.id.prefix(16)))
                do {
                    let name = try await client.migrate(source, directory: directory) { [weak self] text in
                        await MainActor.run { self?.progress = text }
                    }
                    results.append(DockerImportResult(id: source.id, source: source.name, destination: name, detail: "Imported and stopped", directory: directory))
                } catch is CancellationError {
                    results.append(DockerImportResult(id: source.id, source: source.name, destination: nil, detail: "Cancelled. Any copied folders or loaded image remain available; no Docker container was changed.", directory: directory)); break
                } catch {
                    // Do not expose CLI output: inspect data and environment files can contain secrets.
                    let detail: String
                    if let error = error as? MigrationError { detail = error.localizedDescription }
                    else { detail = "Import failed. Copied folders or a loaded image may remain. Check both engines and available disk space before retrying." }
                    results.append(DockerImportResult(id: source.id, source: source.name, destination: nil, detail: detail, directory: directory))
                }
            }
            for source in selection where !results.contains(where: { $0.id == source.id }) {
                results.append(DockerImportResult(id: source.id, source: source.name, destination: nil, detail: "Not imported. Cancellation happened before this container was processed.", directory: base.appendingPathComponent(String(source.id.prefix(16)))))
            }
            progress = ""; isImporting = false; onFinish(results)
        }
    }
    func cancel() { task?.cancel() }
    func cancelAndWait() async { task?.cancel(); await task?.value }
}

struct DockerMigrationView: View {
    @Bindable var migration: DockerMigrationStore
    let store: StudioStore
    let finish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top, spacing: 16) {
                StudioLogo(size: 42).foregroundStyle(Palette.accent)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Bring your Docker containers").font(.system(size: 27, weight: .semibold))
                    Text("Apple container is ready. Move the workloads you want to keep on this Mac.")
                        .font(.system(size: 13)).foregroundStyle(Palette.secondary)
                }
                Spacer()
            }
            if migration.isScanning {
                HStack(spacing: 12) { ProgressView().controlSize(.small); Text(migration.progress) }
                    .frame(maxWidth: .infinity, minHeight: 220)
            } else if !migration.results.isEmpty && !migration.isImporting {
                results
            } else {
                inventory
            }
            if migration.isImporting {
                HStack(spacing: 12) { ProgressView().controlSize(.small); Text(migration.progress).font(.system(size: 13)) }
                Text("Docker originals stay intact. New Apple containers stay stopped.")
                    .font(.system(size: 12)).foregroundStyle(Palette.secondary)
            }
            Divider()
            HStack {
                if migration.isImporting {
                    Button("Cancel import") { migration.cancel() }
                } else {
                    Button(migration.results.isEmpty ? "Not now" : "Done") { finish() }
                    Spacer()
                    if migration.results.isEmpty {
                        Button("Check again") { migration.scan() }.disabled(migration.isScanning)
                        Button("Import \(migration.selectedSources.count) containers") {
                            migration.start { results in
                                for result in results {
                                    store.record(result.destination == nil ? "Docker import needs attention" : "Docker container imported", detail: result.source, failed: result.destination == nil)
                                }
                                store.refresh(force: true)
                            }
                        }.buttonStyle(.borderedProminent).disabled(!migration.canImport)
                    } else {
                        Button("Check Docker again") { migration.scan() }
                    }
                }
            }
        }.padding(32).frame(width: 820, height: 680)
            .background(Palette.background).foregroundStyle(Palette.primary).tint(Palette.accent)
            .interactiveDismissDisabled(migration.isImporting)
    }

    @ViewBuilder private var inventory: some View {
        switch migration.inventory {
        case .missingCLI:
            empty(title: "No Docker CLI found", detail: "If you already use Docker Desktop, open it and check again. You can import later from Settings → Import from Docker.")
        case .unavailable(let message):
            empty(title: "Docker needs attention", detail: message)
        case .available(let context, let sources):
            if sources.isEmpty {
                empty(title: "No Docker containers to import", detail: "The local Docker context ‘\(context)’ is reachable and has no containers. You’re ready to use Apple container.")
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    HStack { Text("Docker / \(context)").font(.system(size: 13, weight: .medium)); Spacer(); Text("\(sources.count) containers").font(.system(size: 12)).foregroundStyle(Palette.secondary) }
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(sources) { source in sourceRow(source) }
                        }
                    }.frame(maxHeight: .infinity)
                    Text("Imports copy the writable filesystem, mounted files, environment, startup command, and supported resource/port settings. Copies need enough local disk space; Docker originals are retained. Environment values may include secrets and stay on your Mac.")
                        .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                    Toggle("I’ve reviewed the configuration and data notes for my selection", isOn: $migration.acknowledged)
                        .font(.system(size: 12)).disabled(migration.isImporting)
                }
            }
        case nil:
            empty(title: "Check your Docker workspace", detail: "Detection reads only your local Docker context.")
        }
    }
    private func sourceRow(_ source: DockerSource) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(get: { migration.selected.contains(source.id) }, set: { value in
                if value { migration.selected.insert(source.id) } else { migration.selected.remove(source.id) }
                migration.acknowledged = false
            })) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(source.name).font(.system(size: 14, weight: .semibold))
                        Text(source.image).font(.system(size: 12)).foregroundStyle(Palette.secondary).lineLimit(1)
                    }
                    Spacer()
                    Text(source.status.capitalized).font(.system(size: 12)).foregroundStyle(Palette.secondary)
                }
            }.disabled(!source.canImport || migration.isImporting)
            if source.canImport {
                Text("Creates \(source.destinationName) · \(source.environment.count) environment values · \(source.mounts.count) data mounts")
                    .font(.system(size: 11)).foregroundStyle(Palette.secondary)
                if !source.ports.isEmpty {
                    Text("Ports: " + source.ports.joined(separator: ", ")).font(.system(size: 11)).foregroundStyle(Palette.secondary)
                }
            }
            ForEach(source.blockers, id: \.self) { Text($0).font(.system(size: 12)).foregroundStyle(Palette.secondary) }
            ForEach(source.warnings, id: \.self) { Text($0).font(.system(size: 12)).foregroundStyle(Palette.secondary) }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.panel, in: RoundedRectangle(cornerRadius: 10))
    }
    private func empty(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "shippingbox").font(.system(size: 26)).foregroundStyle(Palette.accent)
            Text(title).font(.system(size: 19, weight: .semibold))
            Text(detail).font(.system(size: 13)).foregroundStyle(Palette.secondary)
            if FileManager.default.fileExists(atPath: "/Applications/Docker.app") {
                Button("Open Docker Desktop") { NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Docker.app")) }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
    private var results: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Import results").font(.system(size: 19, weight: .semibold))
                ForEach(migration.results) { result in
                    VStack(alignment: .leading, spacing: 8) {
                        Label(result.source, systemImage: result.destination == nil ? "exclamationmark.circle" : "checkmark.circle")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(result.destination == nil ? Palette.secondary : Palette.success)
                        if let destination = result.destination { Text(destination).font(.system(size: 12, design: .monospaced)) }
                        Text(result.detail).font(.system(size: 12)).foregroundStyle(Palette.secondary)
                        if FileManager.default.fileExists(atPath: result.directory.path) {
                            Button("Show copied data") { NSWorkspace.shared.activateFileViewerSelecting([result.directory]) }
                        }
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 10))
                }
                Text("Start imported containers when you’re ready. Review ports and connections before running them alongside Docker.")
                    .font(.system(size: 12)).foregroundStyle(Palette.secondary)
            }
        }.frame(maxHeight: .infinity)
    }
}

#Preview("Docker migration · empty") {
    let store = StudioPreview.store()
    return DockerMigrationView(migration: store.dockerMigration, store: store, finish: {}).preferredColorScheme(.dark)
}
