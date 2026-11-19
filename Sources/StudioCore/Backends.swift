import Foundation

public struct CLIBackend: ContainerBackend {
    private let runner: ProcessRunner
    public init(executable: URL) { runner = ProcessRunner(executable: executable) }

    public static func discover() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["CONTAINER_STUDIO_CLI"] {
            return FileManager.default.isExecutableFile(atPath: override) ? URL(fileURLWithPath: override) : nil
        }
        let paths = ["/usr/local/bin/container", "/opt/homebrew/bin/container"]
            + (environment["PATH"] ?? "").split(separator: ":").map { "\($0)/container" }
        return paths.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    public func snapshot() async throws -> StudioSnapshot {
        async let containers = runner.run(["list", "--all", "--format", "json"])
        async let images = runner.run(["image", "list", "--format", "json"])
        return try await StudioSnapshot(
            containers: SnapshotDecoder.containers(containers), images: SnapshotDecoder.images(images)
        )
    }

    public func logs(id: String) async throws -> String {
        try await logs(id: id, lines: 200, boot: false)
    }

    public func logs(id: String, lines: Int, boot: Bool) async throws -> String {
        let data = try await runner.run(ContainerTools.logsArguments(id: id, lines: lines, boot: boot))
        return String(decoding: data, as: UTF8.self)
    }

    public func runScript(id: String, shell: String, script: String) async throws -> CommandOutput {
        let arguments = try ContainerTools.scriptArguments(id: id, shell: shell, script: script)
        return try await runner.runResult(arguments, timeout: 60, outputLimit: 1_048_576)
    }

    public func perform(_ action: ContainerAction, id: String) async throws {
        _ = try await runner.run([action.rawValue, "--", id], timeout: 30)
    }
}
