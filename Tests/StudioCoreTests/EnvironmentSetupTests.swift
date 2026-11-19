import Foundation
import Testing
@testable import StudioCore

private let supportedMac = HostPlatform(majorVersion: 26, version: "26.2.0", appleSilicon: true, virtualizationSupported: true)

private struct Fixture {
    let directory: URL
    let root: URL
    let executable: URL
    var log: URL { directory.appendingPathComponent("commands") }
    var kernel: URL { root.appendingPathComponent("kernels/default.kernel-arm64") }
    var running: URL { directory.appendingPathComponent("running") }
    var probe: EnvironmentProbe { EnvironmentProbe(executable: executable, platform: supportedMac, defaultRoot: root) }

    init(running: Bool = false, kernel: Bool = false, version: String = "container CLI version 1.0.0 (build: release)", failSetup: Bool = false, slowStart: Bool = false, unknownStatus: Bool = false) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("studio-setup-\(UUID().uuidString)")
        root = directory.appendingPathComponent("Apple container data", isDirectory: true)
        executable = directory.appendingPathComponent("container")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("kernels"), withIntermediateDirectories: true)
        func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let script = """
        #!/bin/sh
        printf '%s\\n' "$*" >> \(quote(log.path))
        case "$*" in
          '--version') printf '%s\\n' \(quote(version)) ;;
          'system status')
            if [ \(unknownStatus ? "1" : "0") = 1 ]; then echo 'unknown service response'; exit 0; fi
            if [ -f \(quote(self.running.path)) ]; then
              printf 'FIELD VALUE\\nstatus running\\npaths.appRoot %s\\n' \(quote(root.path))
            else
              echo 'apiserver is not running'; exit 1
            fi ;;
          'system start --enable-kernel-install'|'system kernel set --recommended')
            \(slowStart ? "exec /bin/sleep 30" : "true")
            if [ \(failSetup ? "1" : "0") = 1 ]; then echo 'kernel download failed' >&2; exit 2; fi
            printf 'kernel' > \(quote(self.kernel.path))
            touch \(quote(self.running.path)) ;;
          *) echo 'unexpected command' >&2; exit 9 ;;
        esac
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        if running { try Data().write(to: self.running) }
        if kernel { try Data("kernel".utf8).write(to: self.kernel) }
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
    func commands() -> [String] { ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
}

@Test func unsupportedMacDoesNotInvokeAnInstallerOrCLI() async throws {
    let fixture = try Fixture(); defer { fixture.remove() }
    for platform in [
        HostPlatform(majorVersion: 25, version: "25.0", appleSilicon: true, virtualizationSupported: true),
        HostPlatform(majorVersion: 26, version: "26.0", appleSilicon: false, virtualizationSupported: true),
        HostPlatform(majorVersion: 26, version: "26.0", appleSilicon: true, virtualizationSupported: false),
    ] {
        let report = try await EnvironmentSetup(probe: EnvironmentProbe(executable: fixture.executable, platform: platform, defaultRoot: fixture.root)).prepare()
        if case .unsupported = report.state {} else { Issue.record("Unsupported host must block setup") }
    }
    #expect(fixture.commands().isEmpty)
}

@Test func missingCLIIsReportedWithoutStartingAnything() async throws {
    let report = try await EnvironmentSetup(probe: EnvironmentProbe(executable: nil, platform: supportedMac)).prepare()
    #expect(report.state == .missingCLI)
    #expect(!report.isReady)
}

@Test func firstLaunchStartsStoppedEngineAndReusesReadyInstallation() async throws {
    let fixture = try Fixture(); defer { fixture.remove() }
    let setup = EnvironmentSetup(probe: fixture.probe)
    let first = try await setup.prepare()
    #expect(first.isReady && first.kernelAvailable)
    #expect(first.cliVersion == "1.0.0")
    #expect(first.applicationRoot == fixture.root)
    #expect(fixture.commands().filter { $0 == "system start --enable-kernel-install" }.count == 1)
    let before = fixture.commands().count
    #expect(try await setup.prepare().isReady)
    #expect(fixture.commands().dropFirst(before).allSatisfy { $0 == "--version" || $0 == "system status" })
}

@Test func runningEngineWithMissingKernelIsRepairedWithoutRestartingIt() async throws {
    let fixture = try Fixture(running: true); defer { fixture.remove() }
    let report = try await EnvironmentSetup(probe: fixture.probe).prepare()
    #expect(report.isReady)
    #expect(fixture.commands().contains("system kernel set --recommended"))
    #expect(!fixture.commands().contains("system start --enable-kernel-install"))
}

@Test func kernelChecksRejectEmptyFilesAndBrokenDefaultLinks() async throws {
    let fixture = try Fixture(running: true); defer { fixture.remove() }
    try Data().write(to: fixture.kernel)
    #expect(try await fixture.probe.inspect().state == .missingKernel)
    try FileManager.default.removeItem(at: fixture.kernel)
    try FileManager.default.createSymbolicLink(atPath: fixture.kernel.path, withDestinationPath: fixture.root.appendingPathComponent("missing-kernel").path)
    #expect(try await fixture.probe.inspect().state == .missingKernel)
}

@Test func failedKernelDownloadDoesNotReportReadinessOrRetryInALoop() async throws {
    let fixture = try Fixture(running: true, failSetup: true); defer { fixture.remove() }
    do {
        _ = try await EnvironmentSetup(probe: fixture.probe).prepare()
        Issue.record("Kernel setup failure must reach the caller")
    } catch CommandError.failed(let code, let detail) {
        #expect(code == 2)
        #expect(detail.contains("kernel download failed"))
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.kernel.path))
    #expect(fixture.commands().filter { $0 == "system kernel set --recommended" }.count == 1)
}

@Test func unknownServiceAndUnsupportedCLIMustNotTriggerGuessedSetup() async throws {
    for fixture in [try Fixture(running: true, kernel: true, unknownStatus: true), try Fixture(version: "docker version 1.0.0"), try Fixture(version: "container CLI version 2.0.0")] {
        defer { fixture.remove() }
        let report = try await EnvironmentSetup(probe: fixture.probe).prepare()
        #expect(!report.isReady)
        #expect(fixture.commands().allSatisfy { $0 == "--version" || $0 == "system status" })
    }
}

@Test func cancellationStopsAutomaticSetup() async throws {
    let fixture = try Fixture(slowStart: true); defer { fixture.remove() }
    let task = Task { try await EnvironmentSetup(probe: fixture.probe).prepare() }
    for _ in 0..<200 {
        if fixture.commands().contains("system start --enable-kernel-install") { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    task.cancel()
    do { _ = try await task.value; Issue.record("Setup must respect cancellation") }
    catch is CancellationError {}
    #expect(!FileManager.default.fileExists(atPath: fixture.kernel.path))
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["STUDIO_LIVE_CHECK"] == "1"))
func liveEnvironmentInspectionIsReadOnly() async throws {
    let report = try await EnvironmentProbe().inspect()
    #expect(report.platform.unsupportedReason == nil)
    #expect(report.cliVersion != nil)
    #expect(report.isReady)
    // Inspection does not call EnvironmentSetup.prepare or start/modify workloads.
}
