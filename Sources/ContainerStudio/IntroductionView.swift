import SwiftUI

struct IntroductionView: View {
    @Bindable var store: StudioStore
    let complete: () -> Void
    @State private var page = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let titles = ["See what’s running", "Keep work on your Mac", "We’ll get this Mac ready"]
    private let descriptions = [
        "Your containers, local images, and logs in one macOS workspace. Find a service, inspect its configuration, and manage it from here.",
        "Container Studio works with Apple’s local container engine. Setup prepares that engine while preserving your existing workloads and data.",
        "We’ll check your environment, install missing dependencies, and start Apple container. If installation needs administrator approval, macOS will ask you."
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            HStack(spacing: 12) {
                StudioLogo(size: 32).foregroundStyle(Palette.accent)
                Text("Container Studio").font(.system(size: 15, weight: .medium))
                Spacer()
                Text("Getting started · \(page + 1) of 3").font(.system(size: 12)).foregroundStyle(Palette.secondary)
            }
            HStack(alignment: .center, spacing: 44) {
                if page < 2 { illustration.frame(width: 280, height: 320) }
                VStack(alignment: .leading, spacing: 18) {
                    Text(titles[page]).font(.system(size: 30, weight: .medium)).tracking(-0.6)
                        .accessibilityAddTraits(.isHeader)
                    Text(descriptions[page]).font(.system(size: 14)).lineSpacing(5)
                        .foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                    if page == 2 { EnvironmentChecklistView(store: store).padding(.top, 6) }
                    else {
                        Label(page == 0 ? "A native workspace for Apple container" : "Local engine · local configuration", systemImage: page == 0 ? "macwindow" : "internaldrive")
                            .font(.system(size: 12)).foregroundStyle(Palette.secondary).padding(.top, 14)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(minHeight: page == 2 ? 425 : 320)
                .id(page).transition(.opacity)
            HStack(spacing: 16) {
                HStack(spacing: 7) {
                    ForEach(0..<3) { step in
                        Circle().fill(step == page ? Palette.accent : Palette.line)
                            .frame(width: 6, height: 6)
                    }
                }.accessibilityHidden(true)
                Spacer()
                if page > 0 { Button("Back") { changePage(page - 1) }.buttonStyle(.plain).foregroundStyle(Palette.secondary) }
                Button(page == 2 ? "Set up this Mac" : "Continue") {
                    if page == 2 { complete() } else { changePage(page + 1) }
                }.buttonStyle(.borderedProminent).controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxWidth: page == 2 ? 660 : 820, alignment: .leading)
        .padding(48).frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.background).foregroundStyle(Palette.primary).tint(Palette.accent)
    }

    private func changePage(_ value: Int) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { page = value }
    }

    private var illustration: some View {
        VStack(spacing: 24) {
            Image(systemName: "desktopcomputer").font(.system(size: 68, weight: .ultraLight)).foregroundStyle(Palette.secondary)
            Rectangle().fill(Palette.line).frame(width: 1, height: 22)
            HStack(spacing: 14) {
                StudioLogo(size: 32).foregroundStyle(Palette.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Container Studio").font(.system(size: 14, weight: .medium))
                    Text(page == 0 ? "Apple container engine" : "Powered by your Mac").font(.system(size: 11)).foregroundStyle(Palette.secondary)
                }
            }.padding(18).frame(maxWidth: .infinity)
                .background(Palette.panel, in: RoundedRectangle(cornerRadius: 12))
            HStack(spacing: 22) {
                Label(page == 0 ? "Containers" : "Linux kernel", systemImage: "shippingbox")
                Label(page == 0 ? "Images" : "Local data", systemImage: "square.stack.3d.up")
            }.font(.system(size: 11)).foregroundStyle(Palette.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Your Mac connects to Apple container and local workloads")
    }
}

#Preview("Introduction") { IntroductionView(store: StudioPreview.store(), complete: {}).frame(width: 1120, height: 700).preferredColorScheme(.dark) }
