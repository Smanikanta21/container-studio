import StudioCore
import SwiftUI

struct ContainerInspector: View {
    @Bindable var store: StudioStore
    let container: StudioContainer
    @State private var tab = "Details"
    @State private var logRefresh = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                eyebrow("CONTAINER DETAILS")
                Spacer()
                Image(systemName: "sidebar.right").foregroundStyle(Palette.secondary)
            }
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: "shippingbox").font(.system(size: 27, weight: .light))
                    .foregroundStyle(Palette.accent).frame(width: 58, height: 58)
                    .background(Palette.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                Text(container.id).font(.system(size: 21, weight: .semibold)).textSelection(.enabled)
                StateBadge(state: container.state)
            }
            HStack(spacing: 8) {
                Button {
                    store.perform(container.isRunning ? .stop : .start, id: container.id)
                } label: {
                    Label(store.isPerformingAction ? "Working…" : container.isRunning ? "Stop container" : "Start container", systemImage: container.isRunning ? "stop.fill" : "play.fill")
                        .font(.system(size: 11, weight: .medium)).frame(maxWidth: .infinity).padding(.vertical, 7)
                }.buttonStyle(.bordered).tint(container.isRunning ? .gray : Palette.accent)
                    .disabled(store.isPerformingAction || store.isLoading || !["running", "stopped"].contains(container.state))
            }
            Button {
                store.openContainer(container)
            } label: { Label("Open Container", systemImage: "terminal") }
                .buttonStyle(.bordered).controlSize(.small).accessibilityLabel("Open Container Workspace")
            Picker("Inspector", selection: $tab) {
                Text("Details").tag("Details")
                Text("Logs").tag("Logs")
            }.pickerStyle(.segmented).labelsHidden()
            if tab == "Details" {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        field("IMAGE", container.image)
                        field("IP ADDRESS", container.address)
                        field("PUBLISHED PORTS", container.ports.isEmpty ? "No published ports" : container.ports.joined(separator: "\n"))
                        Rectangle().fill(Palette.line).frame(height: 1)
                        eyebrow("RESOURCE LIMITS")
                        HStack {
                            resource("CPU", "\(container.cpus) cores", icon: "cpu")
                            Spacer()
                            resource("Memory", formattedBytes(container.memoryBytes), icon: "memorychip")
                        }
                        Text("Configured limits, not live usage.")
                            .font(.system(size: 10)).foregroundStyle(Palette.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Button("Detailed Logs") { store.openContainer(container, tab: .logs) }
                            .buttonStyle(.bordered).controlSize(.small).accessibilityLabel("Detailed Logs")
                        Spacer()
                        Button { logRefresh += 1 } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.plain).help("Reload logs").disabled(store.logsLoading)
                    }
                    ScrollView([.horizontal, .vertical]) {
                        Text(store.logsLoading ? "Loading logs…" : store.logs)
                            .font(.system(size: 10, design: .monospaced)).lineSpacing(5)
                            .textSelection(.enabled).padding(12)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .background(Palette.sidebar, in: RoundedRectangle(cornerRadius: 7))
                }
                .task(id: "\(container.id)-\(store.setupState)-\(logRefresh)") { await store.loadLogs(id: container.id) }
            }
            Spacer(minLength: 0)
            Label("Actions apply to this local container", systemImage: "desktopcomputer")
                .font(.system(size: 10)).foregroundStyle(Palette.secondary)
        }.padding(23).frame(maxHeight: .infinity, alignment: .topLeading)
            .background(Palette.panel.opacity(0.45))
    }

    private func field(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            eyebrow(label)
            Text(value).font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.8)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func resource(_ label: String, _ value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(label, systemImage: icon).font(.system(size: 10)).foregroundStyle(Palette.secondary)
            Text(value).font(.system(size: 12, weight: .medium))
        }
    }
}

#Preview("Container inspector") { ContainerInspector(store: StudioPreview.store(), container: StudioPreview.container()).frame(width: 290, height: 700).preferredColorScheme(.dark) }
