import StudioCore
import SwiftUI

struct EnvironmentChecklistView: View {
    @Bindable var store: StudioStore

    private var platform: HostPlatform { store.environment?.platform ?? .current }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row("This Mac", detail: "macOS \(platform.version) · \(platform.appleSilicon ? "Apple silicon" : "Intel")", passed: platform.majorVersion >= 26 && platform.appleSilicon)
            Divider().overlay(Palette.line)
            row("Hardware virtualization", detail: platform.virtualizationSupported ? "Available" : "Unavailable", passed: platform.virtualizationSupported)
            Divider().overlay(Palette.line)
            row("Apple container CLI", detail: cliDetail, passed: store.environment?.cliVersion != nil, pending: store.environment == nil)
            Divider().overlay(Palette.line)
            row("Linux kernel", detail: kernelDetail, passed: store.environment?.kernelAvailable == true, pending: store.environment == nil || (store.isSettingUp && store.setupPhase != .checking))
            Divider().overlay(Palette.line)
            row("Local engine", detail: serviceDetail, passed: store.environment?.serviceState == .ready, pending: store.environment == nil || (store.isSettingUp && store.setupPhase == .startingEngine))
        }
        .padding(.horizontal, 20)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
    }

    private var cliDetail: String {
        if let version = store.environment?.cliVersion { return "Version \(version) · installed" }
        if store.awaitingInstaller { return "Waiting for macOS Installer" }
        if store.environment?.executable != nil { return "Version could not be verified" }
        return store.environment == nil ? "Checking…" : "Official installer required"
    }

    private var kernelDetail: String {
        if store.environment?.kernelAvailable == true { return "Default kernel is readable and configured" }
        if store.isSettingUp && store.setupPhase != .checking { return "Setting up the recommended kernel…" }
        return store.environment == nil ? "Checking…" : "Will be installed during setup"
    }

    private var serviceDetail: String {
        if store.isSettingUp && store.setupPhase == .startingEngine { return "Starting Apple container…" }
        switch store.environment?.serviceState {
        case .ready: return "Running and responding"
        case .stopped: return "Installed · waiting to start"
        case .unavailable: return "Not responding · review setup details"
        case .unsupported: return "Environment needs attention"
        case .missingCLI: return "Waiting for the CLI"
        default: return "Checking…"
        }
    }

    private func row(_ title: String, detail: String, passed: Bool, pending: Bool = false) -> some View {
        HStack(spacing: 14) {
            Image(systemName: passed ? "checkmark.circle.fill" : pending ? "circle.dotted" : "circle")
                .font(.system(size: 17)).foregroundStyle(passed ? Palette.success : Palette.secondary)
                .frame(width: 22).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 12)).foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Text(passed ? "Ready" : pending ? "Checking" : "Needed")
                .font(.system(size: 11)).foregroundStyle(passed ? Palette.success : Palette.secondary)
        }.padding(.vertical, 14)
    }
}

#Preview("Environment checklist") { EnvironmentChecklistView(store: StudioPreview.store()).padding(24).frame(width: 660).preferredColorScheme(.dark) }
