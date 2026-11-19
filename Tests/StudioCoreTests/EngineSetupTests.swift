import Foundation
import Testing
@testable import StudioCore

@Test func engineStatusSeparatesStoppedReadyAndUnknown() {
    #expect(EngineSetup.state(from: "FIELD VALUE\nstatus running\napiserver.version 1.0.0") == .ready)
    #expect(EngineSetup.state(from: "apiserver is not running and not registered with launchd") == .stopped)
    if case .unavailable = EngineSetup.state(from: "some unrelated status") {} else { Issue.record("Unknown output must not imply readiness") }
}

private func release(_ assets: String, prerelease: Bool = false) -> Data {
    Data("{\"tag_name\":\"1.7.1\",\"draft\":false,\"prerelease\":\(prerelease),\"assets\":[\(assets)]}".utf8)
}
private let signed = "{\"name\":\"container-1.7.1-installer-signed.pkg\",\"browser_download_url\":\"https://github.com/apple/container/releases/download/1.7.1/container-1.7.1-installer-signed.pkg\"}"
private let unsigned = "{\"name\":\"container-installer-unsigned.pkg\",\"browser_download_url\":\"https://github.com/apple/container/releases/download/1.7.1/container-installer-unsigned.pkg\"}"

@Test func selectsSignedApplePackageAndExcludesUnsignedAlternative() throws {
    let asset = try DependencyInstaller.signedInstaller(from: release("\(signed),\(unsigned)"))
    #expect(asset.name == "container-1.7.1-installer-signed.pkg")
    #expect(asset.version == "1.7.1")
    #expect(throws: InstallerError.self) { try DependencyInstaller.signedInstaller(from: release(unsigned)) }
    #expect(throws: InstallerError.self) { try DependencyInstaller.signedInstaller(from: release("\(signed),\(signed)")) }
    #expect(throws: InstallerError.self) { try DependencyInstaller.signedInstaller(from: release(signed, prerelease: true)) }
}

@Test func rejectsUntrustedInstallerLocations() {
    for text in [
        "http://github.com/apple/container/releases/download/1.7.1/container-installer-signed.pkg",
        "https://github.com/other/container/releases/download/1.7.1/container-installer-signed.pkg",
        "https://github.com.evil.example/apple/container/releases/download/1.7.1/container-installer-signed.pkg",
        "https://user:pass@github.com/apple/container/releases/download/1.7.1/container-installer-signed.pkg",
        "https://github.com/apple/container/releases/download/1.7.1/container-installer-signed.pkg?redirect=other",
        "https://github.com/apple/container/releases/download/1.7.1/container-installer-unsigned.pkg",
    ] { #expect(!DependencyInstaller.isOfficial(URL(string: text)!)) }
}

@Test func requiresBothMacOSTrustAndAppleInstallerIdentity() {
    let identity = "    1. Developer ID Installer: Apple Inc. - Containerization (UPBK2H6LZM)"
    let status = "   Status: signed by a developer certificate issued by Apple for distribution"
    #expect(DependencyInstaller.isTrustedAppleSignature("\(status)\n\(identity)"))
    #expect(DependencyInstaller.isTrustedAppleSignature("Status: signed by a certificate trusted by macOS\n\(identity)"))
    #expect(!DependencyInstaller.isTrustedAppleSignature("\(status)\n1. Developer ID Installer: Another Company (UPBK2H6LZM)"))
    #expect(!DependencyInstaller.isTrustedAppleSignature("\(status)\n1. Developer ID Installer: Apple Inc. - Containerization (OTHERTEAM)"))
    #expect(!DependencyInstaller.isTrustedAppleSignature("Status: no signature\n\(identity)"))
    #expect(!DependencyInstaller.isTrustedAppleSignature("\(status)\n\(identity) - Untrusted"))
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["STUDIO_INSTALLER_LIVE_CHECK"] == "1"))
func officialPackageDownloadAndSignatureIntegration() async throws {
    let installer = DependencyInstaller(), asset = try await installer.latest()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("studio-installer-check-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let package = try await installer.downloadAndVerify(asset, directory: directory)
    #expect(FileManager.default.fileExists(atPath: package.path))
    // Deliberately verifies without opening Installer or altering the installed engine.
}
