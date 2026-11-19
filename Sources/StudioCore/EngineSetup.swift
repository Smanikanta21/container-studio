import Foundation

public enum EngineSetupState: Sendable, Equatable {
    case checking, missingCLI, stopped, missingKernel, ready, unavailable(String), unsupported(String)
}

public struct EngineSetup: Sendable {
    private let runner: ProcessRunner
    public init(executable: URL) { runner = ProcessRunner(executable: executable) }

    public static func state(from output: String) -> EngineSetupState {
        let text = output.lowercased()
        if text.contains("not running") || text.contains("not registered with launchd") { return .stopped }
        let fields = text.split(whereSeparator: \.isNewline).map { $0.split(whereSeparator: \.isWhitespace) }
        if fields.contains(where: { $0.first == "status" && $0.dropFirst().first == "running" }) { return .ready }
        return .unavailable("The engine status could not be confirmed. Check Apple's container installation and try again.")
    }

    public func status() async throws -> EngineSetupState {
        do { return Self.state(from: String(decoding: try await runner.run(["system", "status"]), as: UTF8.self)) }
        catch CommandError.failed(_, let detail) {
            let state = Self.state(from: detail)
            if state == .stopped { return state }
            throw CommandError.failed(1, detail)
        }
    }

    public func start() async throws {
        // An explicit setup button authorizes installing the recommended kernel.
        // Avoid an interactive terminal prompt inside a GUI process.
        _ = try await runner.run(["system", "start", "--enable-kernel-install"], timeout: 600, outputLimit: 2_097_152)
    }

    public func installKernel() async throws {
        _ = try await runner.run(["system", "kernel", "set", "--recommended"], timeout: 600, outputLimit: 1_048_576)
    }
}

public enum InstallerError: Error, LocalizedError, Sendable {
    case invalidRelease, noSignedInstaller, invalidURL, downloadFailed, invalidSignature
    public var errorDescription: String? {
        switch self {
        case .invalidRelease: "Apple's release information could not be verified. Try again or use the official releases page."
        case .noSignedInstaller: "This Apple container release has no supported signed installer. Use the official releases page."
        case .invalidURL: "The installer URL is not an official Apple container release asset."
        case .downloadFailed: "The Apple container installer could not be downloaded. Check your connection and try again."
        case .invalidSignature: "The installer did not pass Apple's signature and macOS installation checks. It was not opened."
        }
    }
}

public struct InstallerAsset: Sendable, Equatable {
    public let name: String
    public let url: URL
    public let version: String
    public init(name: String, url: URL, version: String) { self.name = name; self.url = url; self.version = version }
}

public struct DependencyInstaller: Sendable {
    public static let releasesURL = URL(string: "https://github.com/apple/container/releases")!
    private static let latestURL = URL(string: "https://api.github.com/repos/apple/container/releases/latest")!
    private struct Release: Decodable {
        let tag_name: String
        let draft: Bool?
        let prerelease: Bool?
        let assets: [Asset]
        struct Asset: Decodable { let name: String; let browser_download_url: URL }
    }
    public init() {}

    public static func isOfficial(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "github.com" && url.user == nil && url.password == nil && url.port == nil
            && url.path.hasPrefix("/apple/container/releases/download/") && url.path.hasSuffix("-installer-signed.pkg")
            && url.query == nil && url.fragment == nil
    }

    public static func signedInstaller(from data: Data) throws -> InstallerAsset {
        guard let release = try? JSONDecoder().decode(Release.self, from: data), release.draft != true, release.prerelease != true else { throw InstallerError.invalidRelease }
        let candidates = release.assets.filter { $0.name.hasSuffix("-installer-signed.pkg") }
        guard candidates.count == 1, let asset = candidates.first else { throw InstallerError.noSignedInstaller }
        guard isOfficial(asset.browser_download_url), asset.browser_download_url.lastPathComponent == asset.name,
              !asset.name.contains("/"), !asset.name.contains("\\") else { throw InstallerError.invalidURL }
        return InstallerAsset(name: asset.name, url: asset.browser_download_url, version: release.tag_name)
    }

    public func latest() async throws -> InstallerAsset {
        var request = URLRequest(url: Self.latestURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ContainerStudio", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 2_097_152 else { throw InstallerError.invalidRelease }
        return try Self.signedInstaller(from: data)
    }

    public static func isTrustedAppleSignature(_ output: String) -> Bool {
        let lines = output.split(whereSeparator: \.isNewline).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let trustedStatus = lines.contains("Status: signed by a developer certificate issued by Apple for distribution")
            || lines.contains("Status: signed by a certificate trusted by macOS")
        // Pin the leaf identity used by Apple's official Containerization release.
        // Gatekeeper independently checks notarization before the package is opened.
        return trustedStatus && lines.contains("1. Developer ID Installer: Apple Inc. - Containerization (UPBK2H6LZM)")
    }

    public func downloadAndVerify(_ asset: InstallerAsset, directory: URL) async throws -> URL {
        guard Self.isOfficial(asset.url), asset.url.lastPathComponent == asset.name else { throw InstallerError.invalidURL }
        var request = URLRequest(url: asset.url); request.timeoutInterval = 300
        let (temporary, response) = try await URLSession.shared.download(for: request)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw InstallerError.downloadFailed }
        try Task.checkCancellation()
        let final = directory.appendingPathComponent(asset.name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: final.path) { try FileManager.default.removeItem(at: final) }
        try FileManager.default.moveItem(at: temporary, to: final)
        do {
            let signature = try await ProcessRunner(executable: URL(fileURLWithPath: "/usr/sbin/pkgutil")).run(["--check-signature", final.path], timeout: 30)
            guard Self.isTrustedAppleSignature(String(decoding: signature, as: UTF8.self)) else { throw InstallerError.invalidSignature }
            _ = try await ProcessRunner(executable: URL(fileURLWithPath: "/usr/sbin/spctl")).run(["--assess", "--type", "install", final.path], timeout: 60)
            try Task.checkCancellation()
            return final
        } catch {
            try? FileManager.default.removeItem(at: final)
            if error is CancellationError { throw error }
            throw InstallerError.invalidSignature
        }
    }
}
