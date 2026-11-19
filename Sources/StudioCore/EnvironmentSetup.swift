import Foundation
import Virtualization

public struct HostPlatform: Sendable, Equatable {
    public let majorVersion: Int
    public let version: String
    public let appleSilicon: Bool
    public let virtualizationSupported: Bool

    public init(majorVersion: Int, version: String, appleSilicon: Bool, virtualizationSupported: Bool) {
        self.majorVersion = majorVersion; self.version = version
        self.appleSilicon = appleSilicon; self.virtualizationSupported = virtualizationSupported
    }

    public static var current: Self {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let appleSilicon = true
        #else
        let appleSilicon = false
        #endif
        return Self(majorVersion: os.majorVersion, version: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)", appleSilicon: appleSilicon, virtualizationSupported: VZVirtualMachine.isSupported)
    }

    public var unsupportedReason: String? {
        if majorVersion < 26 { return "Apple container requires macOS 26 or later. This Mac is running macOS \(version)." }
        if !appleSilicon { return "Apple silicon is required for the local Apple container engine." }
        if !virtualizationSupported { return "Hardware virtualization is unavailable on this Mac. Apple container cannot run here." }
        return nil
    }
}

public struct EnvironmentSnapshot: Sendable, Equatable {
    public let platform: HostPlatform
    public let executable: URL?
    public let cliVersion: String?
    public let serviceState: EngineSetupState
    public let applicationRoot: URL
    public let kernelAvailable: Bool

    public var state: EngineSetupState {
        serviceState == .ready && !kernelAvailable ? .missingKernel : serviceState
    }
    public var isReady: Bool { state == .ready }
}

public struct EnvironmentProbe: Sendable {
    public let executable: URL?
    private let platform: HostPlatform
    private let defaultRoot: URL

    public init(executable: URL? = CLIBackend.discover(), platform: HostPlatform = .current, defaultRoot: URL? = nil) {
        self.executable = executable; self.platform = platform
        self.defaultRoot = defaultRoot ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("com.apple.container", isDirectory: true)
    }

    public static func cliVersion(from output: String) -> String? {
        // Validate the CLI's identity instead of treating any executable as container.
        let fields = output.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: \.isWhitespace)
        guard fields.count >= 4, Array(fields.prefix(3)) == ["container", "CLI", "version"] else { return nil }
        let parts = fields[3].split(separator: ".")
        guard parts.count == 3, parts.allSatisfy({ Int($0) != nil }) else { return nil }
        return String(fields[3])
    }

    public static func applicationRoot(from output: String) -> URL? {
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard fields.count == 2, ["appRoot", "paths.appRoot"].contains(String(fields[0])) else { continue }
            let path = fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if path.hasPrefix("/") { return URL(fileURLWithPath: path, isDirectory: true) }
        }
        return nil
    }

    public func inspect() async throws -> EnvironmentSnapshot {
        func snapshot(_ state: EngineSetupState, version: String? = nil, root: URL? = nil) -> EnvironmentSnapshot {
            let applicationRoot = root ?? defaultRoot
            let kernel = applicationRoot.appendingPathComponent("kernels/default.kernel-arm64").resolvingSymlinksInPath()
            let attributes = try? FileManager.default.attributesOfItem(atPath: kernel.path)
            let available = FileManager.default.isReadableFile(atPath: kernel.path)
                && attributes?[.type] as? FileAttributeType == .typeRegular
                && ((attributes?[.size] as? NSNumber)?.int64Value ?? 0) > 0
            return EnvironmentSnapshot(platform: platform, executable: executable, cliVersion: version, serviceState: state, applicationRoot: applicationRoot, kernelAvailable: available)
        }
        if let reason = platform.unsupportedReason { return snapshot(.unsupported(reason)) }
        guard let executable else { return snapshot(.missingCLI) }
        let runner = ProcessRunner(executable: executable)
        let versionOutput = String(decoding: try await runner.run(["--version"]), as: UTF8.self)
        guard let version = Self.cliVersion(from: versionOutput), version.split(separator: ".").first == "1" else {
            return snapshot(.unsupported("This executable is not a supported Apple container 1.x CLI. Choose an official compatible installation."))
        }
        do {
            let status = String(decoding: try await runner.run(["system", "status"]), as: UTF8.self)
            return snapshot(EngineSetup.state(from: status), version: version, root: Self.applicationRoot(from: status))
        } catch CommandError.failed(_, let detail) {
            let state = EngineSetup.state(from: detail)
            return snapshot(state == .stopped ? .stopped : .unavailable(detail.isEmpty ? "The Apple container service did not return a readable status." : detail), version: version)
        }
    }
}

public enum SetupPhase: Sendable { case checking, startingEngine, installingKernel }

public struct EnvironmentSetup: Sendable {
    private let probe: EnvironmentProbe
    public init(probe: EnvironmentProbe = EnvironmentProbe()) { self.probe = probe }

    public func prepare(progress: @Sendable (SetupPhase) async -> Void = { _ in }, observed: @Sendable (EnvironmentSnapshot) async -> Void = { _ in }) async throws -> EnvironmentSnapshot {
        await progress(.checking)
        var snapshot = try await probe.inspect()
        await observed(snapshot)
        guard let executable = snapshot.executable else { return snapshot }
        if snapshot.serviceState == .stopped {
            await progress(.startingEngine)
            try await EngineSetup(executable: executable).start()
            snapshot = try await probe.inspect()
            await observed(snapshot)
        }
        if snapshot.state == .missingKernel {
            await progress(.installingKernel)
            try await EngineSetup(executable: executable).installKernel()
            snapshot = try await probe.inspect()
            await observed(snapshot)
        }
        return snapshot
    }
}
