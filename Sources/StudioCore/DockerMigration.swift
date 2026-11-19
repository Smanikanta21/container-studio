import CryptoKit
import Foundation

public struct DockerMount: Sendable, Equatable {
    public let kind: String
    public let destination: String
    public let readOnly: Bool
}

public struct DockerSource: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let image: String
    public let imageID: String
    public let status: String
    public let revision: String
    public let platform: String
    public let executable: String
    public let arguments: [String]
    public let environment: [String]
    public let user: String
    public let workingDirectory: String
    public let ports: [String]
    public let mounts: [DockerMount]
    public let memory: Int64
    public let cpus: Int
    public let readOnly: Bool
    public let blockers: [String]
    public let warnings: [String]
    public var canImport: Bool { blockers.isEmpty }
    public var destinationName: String { String(name.prefix(80)) + "-import-" + id.prefix(8) }

    public static func decode(_ data: Data, platforms: [String: String]) throws -> [DockerSource] {
        guard let values = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw MigrationError.invalidInventory }
        return try values.map { value in
            guard let id = value["Id"] as? String, !id.isEmpty,
                  let rawName = value["Name"] as? String,
                  let imageID = value["Image"] as? String,
                  let config = value["Config"] as? [String: Any],
                  let host = value["HostConfig"] as? [String: Any],
                  let state = value["State"] as? [String: Any] else { throw MigrationError.invalidInventory }
            let name = String(rawName.drop(while: { $0 == "/" }))
            let status = state["Status"] as? String ?? "unknown"
            let platform = platforms[imageID] ?? "unknown"
            let executable = value["Path"] as? String ?? ""
            let env = config["Env"] as? [String] ?? []
            let mounts = (value["Mounts"] as? [[String: Any]] ?? []).map {
                DockerMount(kind: $0["Type"] as? String ?? "unknown", destination: $0["Destination"] as? String ?? "", readOnly: !($0["RW"] as? Bool ?? true))
            }
            var blockers: [String] = [], warnings: [String] = []
            if id.count < 12 || !id.allSatisfy({ "0123456789abcdef".contains($0) }) { blockers.append("Docker did not report a valid container ID.") }
            if !["exited", "created"].contains(status) { blockers.append("Stop this container in Docker, then check again. Imports need a consistent filesystem snapshot.") }
            if platform != "linux/arm64" { blockers.append("This importer requires Linux arm64. Detected \(platform).") }
            if name.isEmpty || !name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "_.-".contains($0)) }) { blockers.append("This container name cannot be used by Apple container.") }
            if executable.isEmpty { blockers.append("Docker did not report the startup executable.") }
            if executable.contains("\0") || (value["Args"] as? [String] ?? []).contains(where: { $0.contains("\0") }) { blockers.append("The startup command contains an unsupported character.") }
            if host["Privileged"] as? Bool == true || !(host["Devices"] as? [Any] ?? []).isEmpty || !(host["DeviceRequests"] as? [Any] ?? []).isEmpty { blockers.append("Privileged containers, device mounts, and GPU requests require manual configuration.") }
            if !(host["SecurityOpt"] as? [String] ?? []).isEmpty || !(host["CapAdd"] as? [String] ?? []).isEmpty || !(host["CapDrop"] as? [String] ?? []).isEmpty { blockers.append("Custom security options and capabilities require manual configuration.") }
            if !(host["Tmpfs"] as? [String: Any] ?? [:]).isEmpty || mounts.contains(where: { !["bind", "volume"].contains($0.kind) }) { blockers.append("Temporary and non-filesystem mounts cannot be copied by this importer.") }
            if mounts.contains(where: { !$0.destination.hasPrefix("/") || $0.destination == "/" || $0.destination.contains(":") || $0.destination.contains(",") || $0.destination.contains("\n") || $0.destination.hasSuffix(".sock") }) { blockers.append("Socket mounts and unsupported mount paths require manual setup.") }
            if env.contains(where: { !$0.contains("=") || $0.contains("\n") || $0.contains("\r") || $0.contains("\0") || $0.hasPrefix("#") }) { blockers.append("An environment value cannot be represented faithfully in an env file.") }
            let nano = (host["NanoCpus"] as? NSNumber)?.int64Value ?? 0
            if nano % 1_000_000_000 != 0 || ((host["CpuQuota"] as? NSNumber)?.int64Value ?? 0) > 0 || !(host["CpusetCpus"] as? String ?? "").isEmpty { blockers.append("Fractional CPU quotas and CPU pinning require manual configuration.") }
            if ["host", "none"].contains(host["NetworkMode"] as? String ?? "") || (host["NetworkMode"] as? String ?? "").hasPrefix("container:") { blockers.append("Host, shared, and disabled networking require manual configuration.") }
            if !(host["Links"] as? [String] ?? []).isEmpty { blockers.append("Docker links require manual networking configuration.") }
            if !(host["Ulimits"] as? [Any] ?? []).isEmpty { blockers.append("Custom ulimits require manual configuration.") }
            let bindings = host["PortBindings"] as? [String: Any] ?? [:]
            var ports: [String] = []
            for key in bindings.keys.sorted() {
                let pieces = key.split(separator: "/")
                guard pieces.count == 2, ["tcp", "udp"].contains(String(pieces[1])), let target = Int(pieces[0]), (1...65535).contains(target), let entries = bindings[key] as? [[String: String]] else { blockers.append("An unsupported port mapping needs manual configuration."); continue }
                for entry in entries {
                    guard let rawPort = entry["HostPort"], let port = Int(rawPort), (1...65535).contains(port) else { blockers.append("Docker-assigned dynamic ports need an explicit host port before importing."); continue }
                    let ip = entry["HostIp"] ?? ""
                    if ip.contains(":") { blockers.append("IPv6 port bindings need manual configuration."); continue }
                    ports.append((ip.isEmpty ? "" : ip + ":") + "\(port):\(key)")
                }
            }
            if !mounts.isEmpty { warnings.append("Mounted files are copied to new local folders. Imported containers do not use Docker's original data. File ownership follows your Mac user and may need adjustment.") }
            let network = host["NetworkMode"] as? String ?? "default"
            if !["default", "bridge", ""].contains(network) { warnings.append("Docker network ‘\(network)’ and service aliases are not imported. Reconfigure service connections in the new workspace.") }
            if let restart = host["RestartPolicy"] as? [String: Any], let policy = restart["Name"] as? String, !["", "no"].contains(policy) { warnings.append("Docker restart policies are not imported. The new container stays stopped until you start it.") }
            if config["Healthcheck"] is [String: Any] { warnings.append("Docker health checks are not imported.") }
            if mounts.count > 1 { warnings.append("Mounts are copied independently. Shared or nested mount layouts may need adjustment.") }
            if mounts.contains(where: { $0.kind == "volume" }) { warnings.append("Volume snapshots are stored as local bind mounts, not managed Apple volumes. Containers sharing a Docker volume receive separate copies.") }
            let memory = (host["Memory"] as? NSNumber)?.int64Value ?? 0
            if memory % 1_048_576 != 0 { blockers.append("Memory limits must use whole MiB for Apple container.") }
            if ((host["MemoryReservation"] as? NSNumber)?.int64Value ?? 0) > 0 || ((host["MemorySwap"] as? NSNumber)?.int64Value ?? 0) > 0 || ((host["CpuShares"] as? NSNumber)?.int64Value ?? 0) > 0 { warnings.append("Memory reservation, swap limits, and CPU shares are not imported.") }
            return DockerSource(id: id, name: name, image: config["Image"] as? String ?? imageID, imageID: imageID, status: status, revision: (state["StartedAt"] as? String ?? "") + "/" + (state["FinishedAt"] as? String ?? ""), platform: platform, executable: executable, arguments: value["Args"] as? [String] ?? [], environment: env, user: config["User"] as? String ?? "", workingDirectory: config["WorkingDir"] as? String ?? "", ports: ports, mounts: mounts, memory: memory, cpus: Int(nano / 1_000_000_000), readOnly: host["ReadonlyRootfs"] as? Bool ?? false, blockers: blockers, warnings: warnings)
        }
    }
}

public enum DockerInventory: Sendable, Equatable {
    case missingCLI
    case unavailable(String)
    case available(context: String, containers: [DockerSource])
}

public enum MigrationError: LocalizedError {
    case invalidInventory, sourceChanged, destinationExists(String), incompatible([String])
    public var errorDescription: String? {
        switch self {
        case .invalidInventory: "Docker returned an inventory that could not be read."
        case .sourceChanged: "The Docker container changed since review. Check again before importing."
        case .destinationExists(let name): "A container named \(name) already exists. No changes were made to it."
        case .incompatible(let reasons): reasons.joined(separator: "\n")
        }
    }
}

public protocol MigrationCommandExecuting: Sendable {
    func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval, outputLimit: Int) async throws -> Data
}
public struct MigrationProcessExecutor: MigrationCommandExecuting {
    public init() {}
    public func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval, outputLimit: Int) async throws -> Data {
        try await ProcessRunner(executable: executable).run(arguments, timeout: timeout, outputLimit: outputLimit)
    }
}

public struct DockerMigrationClient: Sendable {
    public let docker: URL
    public let container: URL
    private let executor: any MigrationCommandExecuting
    public init(docker: URL, container: URL, executor: any MigrationCommandExecuting = MigrationProcessExecutor()) {
        self.docker = docker; self.container = container; self.executor = executor
    }
    public static func discoverDocker(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        if let override = environment["CONTAINER_STUDIO_DOCKER_CLI"] { return FileManager.default.isExecutableFile(atPath: override) ? URL(fileURLWithPath: override) : nil }
        let paths = (environment["PATH"] ?? "").split(separator: ":").map { "\($0)/docker" }
            + ["/usr/local/bin/docker", "/opt/homebrew/bin/docker", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".docker/bin/docker").path, "/Applications/Docker.app/Contents/Resources/bin/docker"]
        return paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }
    private func runDocker(_ args: [String], timeout: TimeInterval = 15) async throws -> Data { try await executor.run(docker, args, timeout: timeout, outputLimit: 16_777_216) }
    public func inventory() async -> DockerInventory {
        do {
            let context = String(decoding: try await runDocker(["context", "show"]), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let endpoint = try await effectiveEndpoint()
            guard endpoint.hasPrefix("unix://") else { return .unavailable("Docker is using a remote endpoint. Switch to a local Docker context, then check again.") }
            _ = try await runDocker(["version", "--format", "{{.Server.Version}}"], timeout: 6)
            let ids = String(decoding: try await runDocker(["container", "ls", "--all", "--quiet"]), as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
            guard !ids.isEmpty else { return .available(context: context, containers: []) }
            let sources = try await inspect(ids)
            return .available(context: context, containers: sources.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
        } catch is CancellationError { return .unavailable("Docker check cancelled.") }
        catch { return .unavailable("Docker could not be reached. Start your local Docker engine, then check again.") }
    }
    private func effectiveEndpoint() async throws -> String {
        if let endpoint = ProcessInfo.processInfo.environment["DOCKER_HOST"], !endpoint.isEmpty { return endpoint }
        return String(decoding: try await runDocker(["context", "inspect", "--format", "{{.Endpoints.docker.Host}}"]), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private func inspect(_ ids: [String]) async throws -> [DockerSource] {
        let data = try await runDocker(["container", "inspect"] + ids)
        guard let values = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw MigrationError.invalidInventory }
        var platforms: [String: String] = [:]
        for image in Set(values.compactMap { $0["Image"] as? String }) {
            platforms[image] = String(decoding: (try? await runDocker(["image", "inspect", image, "--format", "{{.Os}}/{{.Architecture}}"], timeout: 10)) ?? Data(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return try DockerSource.decode(data, platforms: platforms)
    }

    /// Export and copy operations only read Docker. Apple imports are created stopped.
    public func migrate(_ reviewed: DockerSource, directory: URL, progress: @Sendable (String) async -> Void) async throws -> String {
        guard try await effectiveEndpoint().hasPrefix("unix://") else { throw MigrationError.sourceChanged }
        guard let source = try await inspect([reviewed.id]).first, source == reviewed else { throw MigrationError.sourceChanged }
        guard source.canImport else { throw MigrationError.incompatible(source.blockers) }
        let current = try await executor.run(container, ["ls", "--all", "--format", "json"], timeout: 15, outputLimit: 4_194_304)
        if try SnapshotDecoder.containers(current).contains(where: { $0.id == source.destinationName }) { throw MigrationError.destinationExists(source.destinationName) }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let scratch = fm.temporaryDirectory.appendingPathComponent("studio-docker-import-" + UUID().uuidString)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: scratch) }
        await progress("Copying mounted data for \(source.name)…")
        var mountPaths: [URL] = []
        for (index, mount) in source.mounts.enumerated() {
            try Task.checkCancellation()
            let parent = directory.appendingPathComponent("mount-\(index)")
            try fm.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let target = parent.appendingPathComponent("data")
            try await runDocker(["container", "cp", source.id + ":" + mount.destination, target.path], timeout: 1800).discard()
            mountPaths.append(target)
        }
        await progress("Exporting \(source.name)’s filesystem…")
        let filesystem = scratch.appendingPathComponent("filesystem.tar")
        try await runDocker(["container", "export", "--output", filesystem.path, source.id], timeout: 1800).discard()
        try Task.checkCancellation()
        let image = "localhost/container-studio/import:" + UUID().uuidString.lowercased()
        await progress("Preparing a local image for \(source.name)…")
        let archive = try await OCIContainerArchive.make(rootfs: filesystem, image: image, directory: scratch)
        await progress("Loading \(source.name) into Apple container…")
        _ = try await executor.run(container, ["image", "load", "--input", archive.path], timeout: 1800, outputLimit: 4_194_304)
        try Task.checkCancellation()
        // Stop if the source changed or began running during the snapshot.
        guard let latest = try await inspect([source.id]).first, latest == source else { throw MigrationError.sourceChanged }
        await progress("Creating \(source.destinationName)…")
        let envFile = scratch.appendingPathComponent("environment")
        try Data((source.environment.joined(separator: "\n") + "\n").utf8).write(to: envFile, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: envFile.path)
        _ = try await executor.run(container, Self.createArguments(source, image: image, envFile: envFile, mountPaths: mountPaths), timeout: 120, outputLimit: 4_194_304)
        return source.destinationName
    }
    public static func createArguments(_ source: DockerSource, image: String, envFile: URL, mountPaths: [URL]) -> [String] {
        var args = ["create", "--name", source.destinationName, "--arch", "arm64", "--entrypoint", source.executable]
        if !source.environment.isEmpty { args += ["--env-file", envFile.path] }
        if !source.user.isEmpty { args += ["--user", source.user] }
        if !source.workingDirectory.isEmpty { args += ["--workdir", source.workingDirectory] }
        if source.memory > 0 { args += ["--memory", "\(source.memory)"] }
        if source.cpus > 0 { args += ["--cpus", "\(source.cpus)"] }
        if source.readOnly { args += ["--read-only"] }
        for port in source.ports { args += ["--publish", port] }
        for (mount, path) in zip(source.mounts, mountPaths) { args += ["--volume", path.path + ":" + mount.destination + (mount.readOnly ? ":ro" : "")] }
        return args + ["--", image] + source.arguments
    }
}

private extension Data { func discard() {} }

public enum OCIContainerArchive {
    public static func make(rootfs: URL, image: String, directory: URL) async throws -> URL {
        let hash = Task.detached(priority: .utility) { () throws -> String in
            let handle = try FileHandle(forReadingFrom: rootfs); defer { try? handle.close() }
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty { try Task.checkCancellation(); hasher.update(data: chunk) }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
        let layerDigest = try await withTaskCancellationHandler { try await hash.value } onCancel: { hash.cancel() }
        let fm = FileManager.default, oci = directory.appendingPathComponent("oci")
        let blobs = oci.appendingPathComponent("blobs/sha256")
        try fm.createDirectory(at: blobs, withIntermediateDirectories: true)
        let layerSize = try rootfs.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard layerSize > 0 else { throw MigrationError.invalidInventory }
        try fm.moveItem(at: rootfs, to: blobs.appendingPathComponent(layerDigest))
        func blob(_ object: [String: Any]) throws -> (String, Int) {
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            try data.write(to: blobs.appendingPathComponent(digest)); return (digest, data.count)
        }
        let (configDigest, configSize) = try blob(["architecture": "arm64", "os": "linux", "config": ["Entrypoint": [], "Cmd": [], "Env": []], "rootfs": ["type": "layers", "diff_ids": ["sha256:" + layerDigest]]])
        let (manifestDigest, manifestSize) = try blob(["schemaVersion": 2, "mediaType": "application/vnd.oci.image.manifest.v1+json", "config": ["mediaType": "application/vnd.oci.image.config.v1+json", "digest": "sha256:" + configDigest, "size": configSize], "layers": [["mediaType": "application/vnd.oci.image.layer.v1.tar", "digest": "sha256:" + layerDigest, "size": layerSize]]])
        let index: [String: Any] = ["schemaVersion": 2, "manifests": [["mediaType": "application/vnd.oci.image.manifest.v1+json", "digest": "sha256:" + manifestDigest, "size": manifestSize, "platform": ["os": "linux", "architecture": "arm64"], "annotations": ["org.opencontainers.image.ref.name": image]]]]
        try JSONSerialization.data(withJSONObject: index, options: [.sortedKeys]).write(to: oci.appendingPathComponent("index.json"))
        try Data("{\"imageLayoutVersion\":\"1.0.0\"}".utf8).write(to: oci.appendingPathComponent("oci-layout"))
        let output = directory.appendingPathComponent("image.tar")
        _ = try await ProcessRunner(executable: URL(fileURLWithPath: "/usr/bin/tar")).run(["-cf", output.path, "-C", oci.path, "oci-layout", "index.json", "blobs"], timeout: 1800)
        return output
    }
}
