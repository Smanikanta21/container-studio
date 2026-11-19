import CryptoKit
import Foundation
import Testing
@testable import StudioCore

private func fixture(status: String = "exited", host: [String: Any] = [:], mounts: [[String: Any]] = [], env: [String] = ["VALUE=a b;$HOME"] ) throws -> Data {
    let item: [String: Any] = ["Id": "abc123def456", "Name": "/database", "Image": "sha256:image", "Path": "/bin/service", "Args": ["--serve", "a b"], "Config": ["Image": "local/database:latest", "Env": env, "User": "1000", "WorkingDir": "/work"], "State": ["Status": status, "StartedAt": "2026-01-01", "FinishedAt": "2026-01-02"], "HostConfig": host, "Mounts": mounts]
    return try JSONSerialization.data(withJSONObject: [item], options: [.sortedKeys])
}
private func source(_ data: Data) throws -> DockerSource { try #require(DockerSource.decode(data, platforms: ["sha256:image": "linux/arm64"]).first) }

@Test func dockerInventoryKeepsConfigurationAndLiteralArguments() throws {
    let value = try source(fixture(host: ["Memory": 536870912, "NanoCpus": 2_000_000_000, "PortBindings": ["5432/tcp": [["HostIp": "127.0.0.1", "HostPort": "5543"]]]], mounts: [["Type": "volume", "Destination": "/data", "RW": false]]))
    #expect(value.canImport)
    #expect(value.ports == ["127.0.0.1:5543:5432/tcp"])
    #expect(value.environment == ["VALUE=a b;$HOME"])
    let arguments = DockerMigrationClient.createArguments(value, image: "localhost/test:tag", envFile: URL(fileURLWithPath: "/tmp/private env"), mountPaths: [URL(fileURLWithPath: "/tmp/copied data")])
    #expect(arguments.contains("/tmp/copied data:/data:ro"))
    #expect(arguments.contains("/tmp/private env"))
    #expect(!arguments.contains(value.environment[0]))
    #expect(Array(arguments.suffix(4)) == ["--", "localhost/test:tag", "--serve", "a b"])
    #expect(!arguments.contains("start"))
    #expect(arguments.contains("536870912"))
}
@Test func runningAndUnsupportedDockerSourcesAreBlocked() throws {
    #expect(!(try source(fixture(status: "running"))).canImport)
    #expect(!(try source(fixture(host: ["Privileged": true]))).canImport)
    #expect(!(try source(fixture(host: ["NanoCpus": 500_000_000]))).canImport)
    #expect(!(try source(fixture(host: ["NetworkMode": "host"]))).canImport)
    #expect(!(try source(fixture(env: ["SECRET=a\nb"]))).canImport)
    #expect(!(try source(fixture(mounts: [["Type": "bind", "Destination": "/var/run/docker.sock", "RW": true]]))).canImport)
    #expect(!(try DockerSource.decode(fixture(), platforms: ["sha256:image": "linux/amd64"])[0]).canImport)
}
@Test func dockerNetworkAndDataDifferencesRequireVisibleNotes() throws {
    let value = try source(fixture(host: ["NetworkMode": "compose_default", "RestartPolicy": ["Name": "always"]], mounts: [["Type": "volume", "Destination": "/data", "RW": true]]))
    #expect(value.canImport)
    #expect(value.warnings.contains { $0.contains("service aliases") })
    #expect(value.warnings.contains { $0.contains("restart policies") })
    #expect(value.warnings.contains { $0.contains("separate copies") })
}

private actor MigrationExecutor: MigrationCommandExecuting {
    var calls: [(String, [String])] = []
    let data: Data
    let endpoint: String
    var revisionCount = 0
    var changesOnReview = false
    var destinationCollision = false
    init(data: Data, endpoint: String = "unix:///tmp/docker.sock", changesOnReview: Bool = false, destinationCollision: Bool = false) { self.data = data; self.endpoint = endpoint; self.changesOnReview = changesOnReview; self.destinationCollision = destinationCollision }
    func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval, outputLimit: Int) async throws -> Data {
        calls.append((executable.lastPathComponent, arguments))
        if arguments == ["context", "show"] { return Data("desktop-linux\n".utf8) }
        if arguments.first == "context" { return Data(endpoint.utf8) }
        if arguments.first == "version" { return Data("28.0".utf8) }
        if arguments.starts(with: ["container", "ls"]) { return Data("abc123def456\n".utf8) }
        if arguments.starts(with: ["container", "inspect"]) {
            revisionCount += 1
            if changesOnReview && revisionCount > 1 { return try fixture(status: "running") }
            return data
        }
        if arguments.starts(with: ["image", "inspect"]) { return Data("linux/arm64\n".utf8) }
        if arguments.first == "ls" {
            if destinationCollision {
                return Data("[{\"configuration\":{\"id\":\"database-import-abc123de\",\"image\":{\"reference\":\"fixture\"}},\"status\":\"stopped\"}]".utf8)
            }
            return Data("[]".utf8)
        }
        if arguments.starts(with: ["container", "export"]), let at = arguments.firstIndex(of: "--output") {
            try Data("fixture layer".utf8).write(to: URL(fileURLWithPath: arguments[at+1]))
        }
        if arguments.starts(with: ["container", "cp"]), let path = arguments.last {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            try Data("copied data".utf8).write(to: URL(fileURLWithPath: path).appendingPathComponent("data.txt"))
        }
        return Data()
    }
    func recorded() -> [(String, [String])] { calls }
}
@Test func dockerDetectionRejectsRemoteContextsBeforeReadingContainers() async throws {
    let executor = MigrationExecutor(data: try fixture(), endpoint: "ssh://remote")
    let client = DockerMigrationClient(docker: URL(fileURLWithPath: "/docker"), container: URL(fileURLWithPath: "/container"), executor: executor)
    let inventory = await client.inventory()
    guard case .unavailable = inventory else { Issue.record("Remote context should be unavailable"); return }
    let calls = await executor.recorded()
    #expect(!calls.contains { $0.1.first == "version" || $0.1.first == "container" })
}
@Test func dockerMigrationCopiesDataCreatesStoppedAndNeverMutatesOriginal() async throws {
    let data = try fixture(mounts: [["Type": "volume", "Destination": "/data", "RW": true]])
    let executor = MigrationExecutor(data: data)
    let client = DockerMigrationClient(docker: URL(fileURLWithPath: "/docker"), container: URL(fileURLWithPath: "/container"), executor: executor)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = try await client.migrate(source(data), directory: root) { _ in }
    #expect(destination == "database-import-abc123de")
    let calls = await executor.recorded()
    #expect(calls.contains { $0.1.starts(with: ["container", "cp"]) })
    #expect(calls.contains { $0.1.starts(with: ["image", "load"]) })
    #expect(calls.filter { $0.1.first == "create" }.count == 1)
    #expect(!calls.contains { ["start", "stop", "rm", "delete", "commit", "run"].contains($0.1.first ?? "") || ($0.1.count > 1 && ["start", "stop", "rm", "commit", "run"].contains($0.1[1])) })
    let command = try #require(calls.first { $0.1.first == "create" }?.1)
    let envIndex = try #require(command.firstIndex(of: "--env-file"))
    #expect(!FileManager.default.fileExists(atPath: command[envIndex+1]))
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("mount-0/data/data.txt").path))
}
@Test func changedSourceAndDestinationCollisionsDoNotCreateContainers() async throws {
    for collision in [false, true] {
        let data = try fixture()
        let executor = MigrationExecutor(data: data, changesOnReview: !collision, destinationCollision: collision)
        let client = DockerMigrationClient(docker: URL(fileURLWithPath: "/docker"), container: URL(fileURLWithPath: "/container"), executor: executor)
        _ = await client.inventory()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        do { _ = try await client.migrate(source(data), directory: root) { _ in }; Issue.record("Expected a safe rejection") }
        catch {}
        let calls = await executor.recorded()
        #expect(!calls.contains { $0.1.first == "create" || $0.1.starts(with: ["image", "load"]) })
    }
}
@Test func generatedOCIArchiveHasValidContentDigestsAndEmptyStartupDefaults() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let layer = Data("fixture layer bytes".utf8), file = root.appendingPathComponent("rootfs.tar")
    try layer.write(to: file)
    let archive = try await OCIContainerArchive.make(rootfs: file, image: "localhost/fixture:tag", directory: root)
    #expect(FileManager.default.fileExists(atPath: archive.path))
    let index = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("oci/index.json"))) as? [String: Any])
    let manifests = try #require(index["manifests"] as? [[String: Any]])
    let digest = try #require(manifests[0]["digest"] as? String)
    let blob = try Data(contentsOf: root.appendingPathComponent("oci/blobs/sha256/" + String(digest.dropFirst(7))))
    #expect("sha256:" + SHA256.hash(data: blob).map { String(format: "%02x", $0) }.joined() == digest)
    let manifest = try #require(JSONSerialization.jsonObject(with: blob) as? [String: Any])
    let layers = try #require(manifest["layers"] as? [[String: Any]])
    #expect(layers[0]["digest"] as? String == "sha256:" + SHA256.hash(data: layer).map { String(format: "%02x", $0) }.joined())
    let config = try #require(manifest["config"] as? [String: Any])
    let configDigest = try #require(config["digest"] as? String)
    let configData = try Data(contentsOf: root.appendingPathComponent("oci/blobs/sha256/" + String(configDigest.dropFirst(7))))
    let json = try #require(JSONSerialization.jsonObject(with: configData) as? [String: Any])
    let startup = try #require(json["config"] as? [String: Any])
    #expect((startup["Cmd"] as? [String]) == [])
    #expect((startup["Env"] as? [String]) == [])
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["STUDIO_DOCKER_TARGET_LIVE"] == "1"))
func migrationArchiveLoadsAndCreatesStoppedOnRealAppleEngine() async throws {
    let cli = try #require(CLIBackend.discover())
    let runner = ProcessRunner(executable: cli)
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("studio-migration-target-" + UUID().uuidString)
    try fm.createDirectory(at: root.appendingPathComponent("tree/bin"), withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let binary = root.appendingPathComponent("tree/bin/fixture")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: binary)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
    let rootfs = root.appendingPathComponent("rootfs.tar")
    _ = try await ProcessRunner(executable: URL(fileURLWithPath: "/usr/bin/tar")).run(["-cf", rootfs.path, "-C", root.appendingPathComponent("tree").path, "bin"])
    let token = UUID().uuidString.lowercased(), image = "localhost/container-studio/qa:" + token
    let name = "studio-migration-qa-" + token
    let archive = try await OCIContainerArchive.make(rootfs: rootfs, image: image, directory: root)
    var created = false, loaded = false
    do {
        _ = try await runner.run(["image", "load", "--input", archive.path], timeout: 120)
        loaded = true
        _ = try await runner.run(["create", "--name", name, "--arch", "arm64", "--entrypoint", "/bin/fixture", "--", image], timeout: 120)
        created = true
        let snapshot = try await CLIBackend(executable: cli).snapshot()
        let imported = try #require(snapshot.containers.first { $0.id == name })
        #expect(!imported.isRunning)
        _ = try await runner.run(["delete", "--", name], timeout: 30)
        created = false
        _ = try await runner.run(["image", "delete", "--", image], timeout: 30)
        loaded = false
    } catch {
        if created { _ = try? await runner.run(["delete", "--", name], timeout: 30) }
        if loaded { _ = try? await runner.run(["image", "delete", "--", image], timeout: 30) }
        throw error
    }
}
