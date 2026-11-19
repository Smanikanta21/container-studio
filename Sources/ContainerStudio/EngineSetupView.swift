import AppKit
import StudioCore
import SwiftUI

struct EngineSetupView: View {
    @Bindable var store: StudioStore

    private var title: String {
        if store.isSettingUp { return "Preparing this Mac" }
        if store.awaitingInstaller { return "Finish installation in macOS" }
        switch store.setupState {
        case .unsupported: return "This environment needs attention"
        case .unavailable: return "Setup needs attention"
        case .ready: return "Your workspace is ready"
        default: return "Let’s prepare Apple container"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 14) {
                StudioLogo(size: 44).foregroundStyle(Palette.accent)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Container Studio").font(.system(size: 13)).foregroundStyle(Palette.secondary)
                    Text(title).font(.system(size: 26, weight: .medium)).accessibilityAddTraits(.isHeader)
                }
            }
            Text("Apple container needs a compatible Mac, its CLI, a Linux kernel, and a running local service. Setup checks each one and prepares what’s missing.")
                .font(.system(size: 14)).lineSpacing(4).foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            EnvironmentChecklistView(store: store)
            if store.isSettingUp {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text(store.setupMessage).font(.system(size: 13))
                    Spacer()
                    Button("Cancel") { store.cancelSetup() }.buttonStyle(.plain).foregroundStyle(Palette.secondary)
                }
            } else {
                if !store.setupMessage.isEmpty {
                    Text(store.setupMessage).font(.system(size: 13)).foregroundStyle(Palette.secondary)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                if case .unsupported(let message) = store.setupState {
                    Text(message).font(.system(size: 13)).foregroundStyle(Palette.secondary).textSelection(.enabled)
                }
                if case .unavailable(let message) = store.setupState, !message.isEmpty, message != store.setupMessage {
                    Text(message).font(.system(size: 13)).foregroundStyle(Palette.secondary)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                HStack(spacing: 20) {
                    if HostPlatform.current.unsupportedReason == nil {
                        Button(store.awaitingInstaller ? "Check installation" : "Try setup again") {
                            store.setUpEnvironment(retryInstaller: !store.awaitingInstaller)
                        }.buttonStyle(.borderedProminent)
                        if store.awaitingInstaller {
                            Button("Try installer again") { store.setUpEnvironment(retryInstaller: true) }.buttonStyle(.plain).foregroundStyle(Palette.secondary)
                        }
                    }
                    Button("Official releases") { NSWorkspace.shared.open(DependencyInstaller.releasesURL) }
                        .buttonStyle(.plain).foregroundStyle(Palette.secondary)
                }
            }
            Text("Downloads need an internet connection. macOS handles administrator approval for the CLI installer; the native app requires no developer tools.")
                .font(.system(size: 12)).foregroundStyle(Palette.secondary)
        }
        .frame(maxWidth: 660, alignment: .leading).padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.background).foregroundStyle(Palette.primary).tint(Palette.accent)
    }
}

#Preview("Engine setup · missing CLI") {
    let store = StudioPreview.store()
    store.setupState = .missingCLI
    return EngineSetupView(store: store).frame(width: 1120, height: 700).preferredColorScheme(.dark)
}
#Preview("Engine setup · preparing") {
    let store = StudioPreview.store()
    store.isSettingUp = true; store.setupMessage = "Preparing the Linux kernel…"
    return EngineSetupView(store: store).frame(width: 1120, height: 700)
}
