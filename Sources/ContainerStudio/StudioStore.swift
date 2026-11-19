import AppKit
import Foundation
import Observation
import StudioCore

struct StudioActivity: Identifiable {
    let id = UUID()
    let date = Date()
    let title: String
    let detail: String
    let failed: Bool
}

@MainActor @Observable
final class StudioStore {
    let dockerMigration = DockerMigrationStore()
    var isDockerMigrationPresented = false
    @ObservationIgnored private var offeredDockerMigration = false

    func offerDockerMigration() {
        guard setupState == .ready, !isSettingUp, !offeredDockerMigration,
              !UserDefaults.standard.bool(forKey: "studio.dockerMigrationReviewed") else { return }
        offeredDockerMigration = true
        showDockerMigration()
    }

    func showDockerMigration() {
        guard setupState == .ready, !dockerMigration.isImporting else { return }
        isDockerMigrationPresented = true
        dockerMigration.scan()
    }

    func dismissDockerMigration() {
        dockerMigration.cancel()
        UserDefaults.standard.set(true, forKey: "studio.dockerMigrationReviewed")
        isDockerMigrationPresented = false
    }
    var containers: [StudioContainer] = []
    var images: [StudioImage] = []
    var selection: String?
    var hasOpenedWorkspace = false
    var showsSettings = false
    var workspaceContainer: StudioContainer?
    var workspaceTab: ContainerToolTab = .workspace
    var workspaceDirty = false
    var pendingPage: String?
    var confirmsWorkspaceNavigation = false
    let isPreview: Bool

    init(isPreview: Bool = ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1") {
        self.isPreview = isPreview
        dockerMigration.isPreview = isPreview
    }
    var setupState: EngineSetupState = .checking
    var environment: EnvironmentSnapshot?
    var setupPhase: SetupPhase = .checking
    var awaitingInstaller = false
    var setupMessage = ""
    var isSettingUp = false
    var isLoading = false
    var isPerformingAction = false
    var activity: [StudioActivity] = []
    var activityQuery = ""
    var lastUpdated: Date?
    var error: String?
    var logs = ""
    var logsLoading = false
    var query = ""
    var filter = "All"
    var page = "Containers"
    @ObservationIgnored private var setupTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshID = UUID()

    var selected: StudioContainer? { containers.first { $0.id == selection } }
    var runningCount: Int { containers.filter(\.isRunning).count }
    var filteredContainers: [StudioContainer] {
        containers.filter {
            (query.isEmpty || $0.id.localizedCaseInsensitiveContains(query) || $0.image.localizedCaseInsensitiveContains(query))
                && (filter == "All" || (filter == "Running" ? $0.isRunning : $0.state == "stopped"))
        }
    }
    var filteredImages: [StudioImage] {
        images.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
    }

    private func backend() throws -> any ContainerBackend {
        guard let executable = CLIBackend.discover() else { throw CommandError.missingCLI }
        return CLIBackend(executable: executable)
    }

    func checkEnvironment() { refresh(force: true, loadSnapshot: false) }

    func navigate(to page: String) {
        if page == "Settings" { showsSettings = true; return }
        if workspaceDirty { pendingPage = page; confirmsWorkspaceNavigation = true; return }
        workspaceContainer = nil
        self.page = page
        query = ""
    }

    func openContainer(_ container: StudioContainer, tab: ContainerToolTab = .workspace) {
        selection = container.id; page = "Containers"
        workspaceTab = tab; workspaceContainer = container
    }

    func discardAndNavigate() {
        workspaceDirty = false
        if let page = pendingPage { pendingPage = nil; navigate(to: page) }
    }

    func record(_ title: String, detail: String, failed: Bool = false) {
        activity.insert(StudioActivity(title: title, detail: detail, failed: failed), at: 0)
        if activity.count > 200 { activity.removeLast(activity.count - 200) }
    }

    func refresh(force: Bool = false, loadSnapshot: Bool = true) {
        guard !isPreview else { return }
        guard !isSettingUp, force || !isLoading else { return }
        refreshTask?.cancel()
        let request = UUID()
        refreshID = request
        isLoading = true
        error = nil
        refreshTask = Task { [weak self] in
            guard let self else { return }
            defer { if refreshID == request { isLoading = false } }
            do {
                let report = try await EnvironmentProbe().inspect()
                try Task.checkCancellation()
                guard refreshID == request else { return }
                environment = report
                setupState = report.state
                if !loadSnapshot {
                    record("Engine checked", detail: report.state == .ready ? "Engine is ready" : "\(report.state)")
                }
                guard report.isReady, loadSnapshot else { return }
                let snapshot = try await backend().snapshot()
                try Task.checkCancellation()
                guard refreshID == request else { return }
                containers = snapshot.containers; images = snapshot.images
                if !containers.contains(where: { $0.id == selection }) { selection = containers.first?.id }
                lastUpdated = Date()
                record("Workspace refreshed", detail: "\(snapshot.containers.count) containers · \(snapshot.images.count) images")
            } catch is CancellationError {} catch {
                if refreshID == request {
                    self.error = error.localizedDescription; setupState = .unavailable(error.localizedDescription)
                    record("Refresh failed", detail: error.localizedDescription, failed: true)
                }
            }
        }
    }

    func perform(_ action: ContainerAction, id: String) {
        guard !isPreview else { return }
        guard !isPerformingAction, !isLoading, !isSettingUp, setupState == .ready else { return }
        isPerformingAction = true
        error = nil
        Task {
            defer { isPerformingAction = false }
            do {
                try await backend().perform(action, id: id)
                record(action == .start ? "Container started" : "Container stopped", detail: id)
                refresh()
            } catch {
                self.error = error.localizedDescription
                record("Container action failed", detail: "\(id) · \(error.localizedDescription)", failed: true)
            }
        }
    }

    func setUpEnvironment(retryInstaller: Bool = false) {
        guard !isPreview else { return }
        guard !isSettingUp else { return }
        refreshTask?.cancel(); refreshID = UUID(); isLoading = false
        isSettingUp = true; setupMessage = "Checking this Mac…"; error = nil
        setupTask = Task { [weak self] in
            guard let self else { return }
            defer { isSettingUp = false }
            do {
                let report = try await EnvironmentSetup().prepare(progress: { [weak self] phase in
                    await self?.showSetupPhase(phase)
                }, observed: { [weak self] report in
                    await self?.showEnvironment(report)
                })
                try Task.checkCancellation()
                environment = report; setupState = report.state
                if report.state == .missingCLI {
                    if awaitingInstaller && !retryInstaller {
                        setupMessage = "Finish macOS Installer. Setup continues automatically when you return here."
                        return
                    }
                    setupMessage = "Finding Apple's signed container installer…"
                    let installer = DependencyInstaller()
                    let asset = try await installer.latest()
                    try Task.checkCancellation()
                    setupMessage = "Downloading and verifying Apple container \(asset.version)…"
                    let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                    let directory = caches.appendingPathComponent("ContainerStudio/Installers", isDirectory: true)
                    let package = try await installer.downloadAndVerify(asset, directory: directory)
                    try Task.checkCancellation()
                    guard NSWorkspace.shared.open(package) else { throw InstallerError.downloadFailed }
                    awaitingInstaller = true
                    setupMessage = "Approve and finish macOS Installer. Setup continues automatically when you return here."
                } else if report.isReady {
                    awaitingInstaller = false; setupMessage = ""; isSettingUp = false
                    refresh(force: true)
                } else {
                    setupMessage = "Setup could not finish. Review the environment checks below and try again."
                }
            } catch is CancellationError {
                setupMessage = "Setup cancelled. You can check this Mac or try again."
                setupState = .unavailable(setupMessage)
            } catch {
                setupMessage = error.localizedDescription
                setupState = .unavailable(setupMessage)
            }
        }
    }

    private func showSetupPhase(_ phase: SetupPhase) {
        setupPhase = phase
        switch phase {
        case .checking: setupMessage = "Checking this Mac…"
        case .startingEngine: setupMessage = "Starting Apple container and setting up its Linux kernel…"
        case .installingKernel: setupMessage = "Installing Apple's recommended Linux kernel…"
        }
    }

    private func showEnvironment(_ report: EnvironmentSnapshot) {
        environment = report; setupState = report.state
    }

    func resumeSetup() {
        guard !isSettingUp, !isLoading else { return }
        if awaitingInstaller && CLIBackend.discover() != nil { setUpEnvironment() }
    }

    func cancelSetup() { setupTask?.cancel() }

    func loadLogs(id: String) async {
        guard !isPreview else { return }
        logsLoading = true
        logs = ""
        defer { if selection == id { logsLoading = false } }
        do {
            let result = try await backend().logs(id: id)
            try Task.checkCancellation()
            if selection == id { logs = result.isEmpty ? "No logs available." : result }
        } catch is CancellationError {} catch {
            if selection == id { logs = error.localizedDescription }
        }
    }
}
