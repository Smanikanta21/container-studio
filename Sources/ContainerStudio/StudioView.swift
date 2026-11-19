import AppKit
import StudioCore
import SwiftUI

enum StudioAppearance: String, CaseIterable {
    case system, light, dark
    var title: String { rawValue.capitalized }
    var colorScheme: ColorScheme? {
        switch self { case .system: nil; case .light: .light; case .dark: .dark }
    }
}

enum Palette {
    private static func adaptive(_ light: (Double, Double, Double), _ dark: (Double, Double, Double)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: value.0 / 255, green: value.1 / 255, blue: value.2 / 255, alpha: 1)
        })
    }
    static let background = adaptive((244, 243, 236), (28, 28, 30))
    static let sidebar = adaptive((237, 235, 225), (36, 36, 38))
    static let panel = adaptive((252, 251, 246), (44, 44, 46))
    static let line = adaptive((222, 219, 207), (55, 55, 58))
    static let accent = adaptive((151, 89, 32), (121, 176, 223))
    static let primary = adaptive((44, 43, 39), (246, 246, 248))
    static let secondary = adaptive((106, 103, 94), (160, 160, 168))
    static let success = adaptive((45, 112, 78), (121, 193, 154))
}

struct StudioView: View {
    @Bindable var store: StudioStore

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Palette.line).frame(width: 1)
            VStack(alignment: .leading, spacing: 0) {
                toolbar
                Divider().overlay(Palette.line)
                if let error = store.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange)
                        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.orange.opacity(0.08))
                }
                HStack(spacing: 0) {
                    Group {
                        if store.page == "Containers", let container = store.workspaceContainer {
                            ContainerToolsView(store: store, container: container, tab: store.workspaceTab).id(container.id)
                        }
                        else if store.page == "Activity" { StudioActivityView(store: store) }
                        else { workspace }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    if store.page == "Containers", store.workspaceContainer == nil, let container = store.selected {
                        Rectangle().fill(Palette.line).frame(width: 1)
                        ContainerInspector(store: store, container: container).frame(width: 290)
                    }
                }
                footer
            }
        }
        .background(Palette.background)
        .tint(Palette.accent)
        .confirmationDialog("Discard unsaved file changes?", isPresented: $store.confirmsWorkspaceNavigation) {
            Button("Discard and Leave", role: .destructive) { store.discardAndNavigate() }
            Button("Cancel", role: .cancel) { store.pendingPage = nil }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                StudioLogo(size: 36).foregroundStyle(Palette.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Container Studio").font(.system(size: 17, weight: .medium))
                    Text("Local container workspace").font(.system(size: 11)).foregroundStyle(Palette.secondary)
                }
            }.padding(.top, 46).padding(.bottom, 38)
            eyebrow("WORKSPACE").padding(.bottom, 13)
            navigation("Containers", icon: "square.stack.3d.up", count: store.containers.count)
            navigation("Images", icon: "square.3.layers.3d", count: store.images.count)
            navigation("Activity", icon: "clock", count: store.activity.count)
            Spacer()
            navigation("Settings", icon: "gearshape", count: 0)
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 7) {
                    Circle().fill(store.setupState == .ready ? Palette.accent : Palette.secondary).frame(width: 6, height: 6)
                    Text(store.setupState == .ready ? "Local engine" : "Not connected")
                        .font(.system(size: 12, weight: .medium))
                }
                Text("Powered by Apple container.")
                    .font(.system(size: 11)).foregroundStyle(Palette.secondary)
            }.padding(13).background(Palette.panel, in: RoundedRectangle(cornerRadius: 10))
            HStack {
                Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.2.0")")
                Spacer()
                Button { store.showsSettings = true } label: {
                    Image(systemName: "gearshape").frame(width: 28, height: 28)
                }.buttonStyle(.plain).help("Open settings")
                    .accessibilityLabel("Open settings")
            }.font(.system(size: 11)).foregroundStyle(Palette.secondary).padding(.top, 16)
        }.padding(.horizontal, 20).padding(.bottom, 22).frame(width: 210).background(Palette.sidebar)
    }

    private func navigation(_ title: String, icon: String, count: Int) -> some View {
        Button {
            store.navigate(to: title)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).frame(width: 18)
                Text(title)
                Spacer()
                if title != "Settings" { Text("\(count)").font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.secondary) }
            }.font(.system(size: 13, weight: store.page == title ? .medium : .regular))
                .padding(.horizontal, 11).padding(.vertical, 11)
                .foregroundStyle(store.page == title ? Palette.accent : Palette.secondary)
                .background(store.page == title ? Palette.accent.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain).padding(.bottom, 5).accessibilityLabel(title)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "desktopcomputer").foregroundStyle(Palette.secondary)
            Text("Local workspace").fontWeight(.medium)
            Text("/").foregroundStyle(Palette.secondary)
            Text(store.workspaceContainer?.id ?? store.page).foregroundStyle(Palette.secondary)
                .lineLimit(1).truncationMode(.middle)
            Spacer()
            Text("ON THIS MAC")
                .font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(1)
                .foregroundStyle(Palette.secondary)
            if store.page == "Containers" || store.page == "Images" { Button { store.refresh() } label: {
                Label(store.isLoading ? "Refreshing…" : "Refresh", systemImage: "arrow.clockwise")
            }.buttonStyle(.bordered).controlSize(.small)
                .disabled(store.isLoading || store.isPerformingAction)
                .help("Refresh workspace (⌘R)")
            }
        }.font(.system(size: 12)).padding(.horizontal, 27).frame(height: 64)
    }


    private var workspace: some View {
        VStack(alignment: .leading, spacing: 25) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(store.page).font(.system(size: 29, weight: .semibold))
                    Text(store.page == "Containers" ? "Your services. One quiet workspace." : "The building blocks of your workspace.")
                        .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                }
                Spacer()
                Image(systemName: store.page == "Containers" ? "shippingbox" : "square.3.layers.3d")
                    .font(.system(size: 26, weight: .ultraLight)).foregroundStyle(Palette.secondary.opacity(0.5))
            }
            HStack(spacing: 12) {
                metric("RUNNING", value: "\(store.runningCount)", detail: "containers", color: Palette.accent)
                metric("STOPPED", value: "\(store.containers.filter { $0.state == "stopped" }.count)", detail: "containers", color: Palette.secondary)
                metric("IMAGES", value: "\(store.images.count)", detail: "available locally", color: Palette.secondary)
            }
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Palette.secondary)
                    TextField(store.page == "Containers" ? "Find a container…" : "Find an image…", text: $store.query)
                        .textFieldStyle(.plain).font(.system(size: 12))
                }.padding(10).background(Palette.panel, in: RoundedRectangle(cornerRadius: 7))
                if store.page == "Containers" {
                    Picker("Filter containers", selection: $store.filter) {
                        Text("All").tag("All")
                        Text("Running").tag("Running")
                        Text("Stopped").tag("Stopped")
                    }.labelsHidden().pickerStyle(.segmented).frame(width: 190)
                }
            }
            if store.page == "Containers" { containerList } else { imageList }
            Spacer(minLength: 0)
        }.padding(27)
    }

    private var containerList: some View {
        VStack(spacing: 0) {
            HStack {
                eyebrow("NAME / IMAGE")
                Spacer()
                eyebrow("STATE").frame(width: 85, alignment: .leading)
            }.padding(.horizontal, 14).padding(.bottom, 12)
            if store.filteredContainers.isEmpty {
                emptyState(store.isLoading ? "Loading containers…" : store.query.isEmpty && store.filter == "All" ? "No containers yet" : "No matching containers", detail: "Refresh or adjust your filters to update this view.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(store.filteredContainers) { container in
                            Button { store.selection = container.id } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "shippingbox").font(.system(size: 17))
                                        .foregroundStyle(container.isRunning ? Palette.accent : Palette.secondary)
                                        .frame(width: 36, height: 38).background(Palette.line, in: RoundedRectangle(cornerRadius: 7))
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(container.id).font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.primary)
                                        Text(container.shortImage).font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(Palette.secondary).lineLimit(1).truncationMode(.middle)
                                    }
                                    Spacer(minLength: 4)
                                    StateBadge(state: container.state).frame(width: 85, alignment: .leading)
                                }.padding(12).frame(maxWidth: .infinity)
                                    .background(store.selection == container.id ? Palette.accent.opacity(0.065) : Palette.panel.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(store.selection == container.id ? Palette.accent.opacity(0.25) : .clear))
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityLabel("\(container.id), \(container.state)")
                                .simultaneousGesture(TapGesture(count: 2).onEnded {
                                    store.openContainer(container)
                                })
                                .contextMenu { Button("Open Container Workspace") { store.openContainer(container) } }
                        }
                    }.padding(1)
                }
            }
        }
    }

    private var imageList: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                if store.filteredImages.isEmpty { emptyState("No images found", detail: "Local images appear here after a refresh.") }
                ForEach(store.filteredImages) { image in
                    HStack(spacing: 12) {
                        Image(systemName: "square.3.layers.3d").foregroundStyle(Palette.accent)
                        VStack(alignment: .leading, spacing: 7) {
                            Text(image.name).font(.system(size: 12, weight: .medium)).textSelection(.enabled)
                            Text(image.architecture).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.secondary)
                        }
                        Spacer()
                        Text(formattedBytes(image.bytes)).font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.secondary)
                    }.padding(16).background(Palette.panel, in: RoundedRectangle(cornerRadius: 8))
                }
                Text("Image sizes are reported by the CLI; shared layers may be counted more than once.")
                    .font(.system(size: 10)).foregroundStyle(Palette.secondary).padding(.top, 12)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 7) {
            Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 9))
            Text("Refreshes on demand")
            Spacer()
            if let updated = store.lastUpdated {
                Text("\(store.error == nil ? "Updated" : "Last successful update") \(updated.formatted(date: .omitted, time: .standard))")
            }
        }.font(.system(size: 10)).foregroundStyle(Palette.secondary)
            .padding(.horizontal, 27).frame(height: 37)
            .overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: 1) }
    }

    private func metric(_ title: String, value: String, detail: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            eyebrow(title)
            Text(value).font(.system(size: 28, weight: .medium, design: .rounded)).foregroundStyle(color)
            Text(detail).font(.system(size: 10)).foregroundStyle(Palette.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .background(Palette.panel, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Palette.line))
    }
}

func eyebrow(_ text: String) -> some View {
    Text(text).font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(1.1).foregroundStyle(Palette.secondary)
}

func emptyState(_ title: String, detail: String) -> some View {
    VStack(spacing: 12) {
        Image(systemName: "shippingbox").font(.system(size: 28, weight: .light)).foregroundStyle(Palette.secondary)
        Text(title).font(.system(size: 14, weight: .medium))
        Text(detail).font(.system(size: 11)).foregroundStyle(Palette.secondary)
    }.frame(maxWidth: .infinity).padding(.vertical, 50)
}

struct StateBadge: View {
    let state: String
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(state == "running" ? Palette.accent : Palette.secondary).frame(width: 5, height: 5)
            Text(state.capitalized).font(.system(size: 10))
        }.foregroundStyle(state == "running" ? Palette.accent : Palette.secondary)
    }
}

#Preview("Containers · Dark") { StudioView(store: StudioPreview.store()).frame(width: 1320, height: 820).preferredColorScheme(.dark) }
#Preview("Containers · Light") { StudioView(store: StudioPreview.store()).frame(width: 1120, height: 700).preferredColorScheme(.light) }
#Preview("Images") { StudioView(store: StudioPreview.store(page: "Images")).frame(width: 1120, height: 700) }
#Preview("Container in main window") {
    let store = StudioPreview.store()
    store.openContainer(store.containers[0])
    return StudioView(store: store).frame(width: 1320, height: 820).preferredColorScheme(.dark)
}
#Preview("Container · minimum window") {
    let store = StudioPreview.store()
    store.openContainer(store.containers[0])
    return StudioView(store: store).frame(width: 1120, height: 700).preferredColorScheme(.light)
}
#Preview("State badges") { HStack { StateBadge(state: "running"); StateBadge(state: "stopped") }.padding() }
