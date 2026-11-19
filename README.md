<picture>
  <source media="(prefers-color-scheme: dark)" srcset="branding/logo-dark.svg">
  <source media="(prefers-color-scheme: light)" srcset="branding/logo-light.svg">
  <img src="branding/logo-light.svg" width="72" height="72" alt="Container Studio CS logo">
</picture>

# Container Studio

A native macOS workspace for [Apple container](https://github.com/apple/container). Manage local Linux containers, inspect their files and logs, and work in an embedded terminal from one SwiftUI app.

**macOS 26+ · Apple silicon · Apache 2.0 · Source alpha**

[Build from source](#build-from-source) · [Source tag](https://github.com/Smanikanta21/container-studio/tree/v0.2.0-alpha.1) · [Sponsor](https://github.com/sponsors/Smanikanta21)

Container Studio is an independent companion, not an official Apple app. The current source tag is **`v0.2.0-alpha.1`**. A signed, notarized binary release is still being prepared; native volume management and profile features remain on the roadmap.

## What you can do

| Workflow | Native app today |
| --- | --- |
| Set up this Mac | First-launch introduction, environment checks, and guided Apple container engine setup. |
| Manage local containers | Browse containers and images, filter container state, inspect configuration, and start or stop selected containers. |
| Work inside a container | Open its Files & CLI workspace, browse and edit files, and use the SwiftTerm-based embedded terminal. The container must be running for shell/file access. |
| Inspect output | View app and boot logs, search, copy or export output, and run scripts with bounded execution and output. |
| Bring workloads from Docker | Review and import compatible **stopped Linux arm64** containers, with copied mount data and supported configuration. |
| Choose an appearance | System, warm-orange Light, and graphite-blue Dark, with an original CS mark and Icon Composer app icon. |

The app opens one workspace window. Double-click a container to open its Files & CLI workspace; Settings is available from the sidebar or **⌘,**.

## First launch

1. Review the introduction and choose **Set up this Mac**.
2. The app checks macOS, architecture, virtualization, the Apple container CLI, kernel availability, and service state.
3. If the CLI is missing, it downloads Apple's official signed installer, verifies its identity, and opens the normal macOS installation flow. macOS may ask for administrator authorization.
4. Setup reuses a ready engine, starts a stopped service when needed, and prepares the kernel through Apple container's supported commands.
5. After the engine is ready, the app checks for Docker migration. **Not now** remembers your choice; reopen it from **Settings → Import from Docker…**.

Apple container runs Linux workloads in lightweight virtual machines. The engine is installed separately; Swift, Node, Python, and Xcode are not end-user dependencies. Building this source alpha requires Xcode.

## Build from source

Requirements: **macOS 26 or newer**, **Apple silicon**, and **Xcode with Swift 6.2 or newer**. The project resolves its pinned SwiftTerm dependency through Swift Package Manager.

```sh
git clone https://github.com/Smanikanta21/container-studio.git
cd container-studio
open ContainerStudio.xcodeproj
```

Select the **Container Studio** scheme and **My Mac**, then Run. `Package.swift` contains the shared `StudioCore` library and tests; the native app is built with the Xcode project.

To create a local Release build:

```sh
zsh scripts/package.sh
open "dist/Container Studio.app"
```

The packaging script verifies the app's local code signature. This development build uses ad-hoc signing; it is not the final Developer ID-signed, notarized public download.

## Docker import

Migration is an **opt-in snapshot import** from a local Docker engine, not Compose orchestration or a live synchronization service.

- Select compatible stopped Linux arm64 containers and acknowledge the review before import.
- The importer exports the writable filesystem, copies supported mount data into independent local folders, and creates distinctly named **stopped** Apple containers.
- Supported startup settings, environment, user, working directory, ports, resource limits, and read-only flags are carried over where compatible.
- Docker originals are never started, stopped, or deleted by the importer. The app does not install Docker or start its daemon.
- Unsupported configurations are blocked. Review notes explain network, shared-volume, ownership, restart-policy, and other differences. Imported data is independent of the Docker source.

Copied data lives under `~/Library/Application Support/ContainerStudio/Migrations/`. Partial failures can leave copied data or a loaded image for inspection; results explain what was retained.

Core tests and a live Apple-target fixture have passed. A full transfer from a real Docker source still needs validation on a Docker-equipped Mac. The import review explains compatibility restrictions before any transfer begins.

## Current status

The native app implements setup, container/image views, Files & CLI, logs, scripts, Settings, appearance controls, and the initial Docker snapshot importer.

These features are **not yet implemented**:

- Named-volume management.
- Runtime presets.
- Project workspaces.
- A local personal profile.

Before a public binary release, remaining work also includes live Docker-source validation, clean-Mac setup and upgrade checks, final interface checks, Developer ID signing, and notarization.

## Tests and development

From the repository root:

```sh
swift test
```

The latest verified core run passed **41 tests**, and the native Release build passed. The optional Apple-engine integration fixture loads a tiny generated OCI image, creates a uniquely named stopped test container, and removes the fixture container/image:

```sh
STUDIO_DOCKER_TARGET_LIVE=1 swift test
```

Run that optional check only against a local Apple engine you use for testing. It does not operate on Docker workloads.

Useful references:

- [Editable CS identity and Icon Composer assets](branding/README.md)
- [Shared core and native app source](Sources)
- [Core tests](Tests/StudioCoreTests)

## Contribute

[Report a bug or propose an improvement](https://github.com/Smanikanta21/container-studio/issues). Include your macOS version, architecture, Apple container version, reproduction steps, and relevant logs with credentials removed.

For a substantial feature, discuss the approach in an issue before opening a pull request. Preserve dependency notices and run the checks relevant to the change. Contributors should understand and be able to explain submitted code, including AI-assisted work.

Companion-app development belongs in this repository. Apple currently keeps [the official container repository CLI-only](https://github.com/apple/container/pull/2527#issuecomment-6929147370); independently useful engine changes can be proposed upstream through [Apple's contribution process](https://github.com/apple/containerization/blob/main/CONTRIBUTING.md).

## Sponsor

[Sponsor Container Studio development on GitHub](https://github.com/sponsors/Smanikanta21).

Support helps sustain maintenance, compatibility work, and testing. Bug reports, useful feedback, and code contributions are also welcome.

Maintained by [Smanikanta21](https://github.com/Smanikanta21).

## License and credits

Container Studio code and original CS artwork use [Apache License 2.0](LICENSE). The app bundles [complete third-party license notices](Resources/ThirdPartyNotices.txt), including SwiftTerm's MIT license and the resolved Argument Parser license with its Swift runtime exception.

Apple platform resources and external tools retain their own terms. The UI design workflow was informed by an adaptation of Unslop by [Damir Sokolovsky](https://x.com/heydamir), licensed under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
