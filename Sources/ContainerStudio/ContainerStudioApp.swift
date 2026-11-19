import AppKit
import Darwin
import SwiftUI

@main
struct ContainerStudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = StudioStore()
    @AppStorage("studio.appearance") private var appearance = StudioAppearance.system
    @AppStorage("studio.introductionCompleted") private var introductionCompleted = false
    @Environment(\.scenePhase) private var scenePhase

    init() {
        if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" { return }
        guard StudioInstance.acquire() else { exit(0) }
    }

    var body: some Scene {
        Window("Container Studio", id: "studio") {
            Group {
                if !introductionCompleted {
                    IntroductionView(store: store) { introductionCompleted = true }
                } else if store.hasOpenedWorkspace || (store.setupState == .ready && !store.isSettingUp) {
                    StudioView(store: store).onAppear { store.hasOpenedWorkspace = true }
                }
                else { EngineSetupView(store: store) }
            }
                .onAppear { delegate.store = store }
                .preferredColorScheme(appearance.colorScheme)
                .frame(minWidth: 1120, minHeight: 700)
                .task {
                    if introductionCompleted { store.setUpEnvironment() }
                    else { store.checkEnvironment() }
                }
                .onChange(of: introductionCompleted) { _, completed in
                    if completed { store.setUpEnvironment() }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active && introductionCompleted { store.resumeSetup() }
                }
                .onChange(of: store.setupState, initial: true) { _, state in
                    if introductionCompleted && state == .ready { store.offerDockerMigration() }
                }
                .onChange(of: store.isSettingUp) { _, settingUp in
                    if introductionCompleted && !settingUp { store.offerDockerMigration() }
                }
                .sheet(isPresented: $store.isDockerMigrationPresented, onDismiss: { store.dismissDockerMigration() }) {
                    DockerMigrationView(migration: store.dockerMigration, store: store, finish: { store.dismissDockerMigration() })
                        .preferredColorScheme(appearance.colorScheme)
                }
                .sheet(isPresented: $store.showsSettings) {
                    StudioSettingsModal(store: store).preferredColorScheme(appearance.colorScheme)
                }
        }
        .defaultSize(width: 1320, height: 820)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { store.showsSettings = true }.keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .toolbar) {
                Button("Import from Docker…") { store.showDockerMigration() }
                    .disabled(store.setupState != .ready || store.dockerMigration.isImporting)
                Button("Refresh workspace") { store.refresh() }
                    .keyboardShortcut("r")
                    .disabled(!introductionCompleted || store.isLoading || store.isSettingUp || store.isPerformingAction)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: StudioStore?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let migration = store?.dockerMigration, migration.isImporting else { return .terminateNow }
        Task { @MainActor in
            await migration.cancelAndWait()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
