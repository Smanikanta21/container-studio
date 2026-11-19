import Foundation

public struct StudioContainer: Identifiable, Sendable, Equatable {
    public let id: String
    public let image: String
    public var state: String
    public let cpus: Int
    public let memoryBytes: Int64
    public let address: String
    public let ports: [String]
    public var isRunning: Bool { state == "running" }
    public var shortImage: String {
        image.replacingOccurrences(of: "docker.io/library/", with: "")
    }
}

public struct StudioImage: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let bytes: Int64
    public let architecture: String
}

public struct StudioSnapshot: Sendable {
    public var containers: [StudioContainer]
    public let images: [StudioImage]
}

public enum ContainerAction: String, Sendable { case start, stop }

public protocol ContainerBackend: Sendable {
    func snapshot() async throws -> StudioSnapshot
    func logs(id: String) async throws -> String
    func perform(_ action: ContainerAction, id: String) async throws
}

public enum SnapshotDecoder {
    public static func containers(_ data: Data) throws -> [StudioContainer] {
        try JSONDecoder().decode([ContainerDTO].self, from: data).map { dto in
            StudioContainer(
                id: dto.configuration.id, image: dto.configuration.image.reference,
                state: dto.state, cpus: dto.configuration.resources.cpus,
                memoryBytes: dto.configuration.resources.memoryInBytes,
                address: dto.networks.first?.ipv4Address ?? "—",
                ports: (dto.configuration.publishedPorts ?? []).map {
                    "\($0.hostPort) → \($0.containerPort)/\($0.proto)"
                }
            )
        }.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    public static func images(_ data: Data) throws -> [StudioImage] {
        try JSONDecoder().decode([ImageDTO].self, from: data).map { dto in
            StudioImage(
                id: dto.configuration.name, name: dto.configuration.name,
                bytes: dto.variants.reduce(0) { $0 + $1.size },
                architecture: Set(dto.variants.map(\.platform.architecture)).sorted().joined(separator: ", ")
            )
        }.sorted { $0.name < $1.name }
    }
}

private struct ContainerDTO: Decodable {
    struct Configuration: Decodable {
        struct Image: Decodable { let reference: String }
        struct Resources: Decodable { let cpus: Int; let memoryInBytes: Int64 }
        struct Port: Decodable { let hostPort: Int; let containerPort: Int; let proto: String }
        let id: String
        let image: Image
        let resources: Resources
        let publishedPorts: [Port]?
    }
    struct Network: Decodable { let ipv4Address: String? }
    struct LegacyStatus: Decodable { let state: String; let networks: [Network]? }
    let configuration: Configuration
    let state: String
    let networks: [Network]
    enum CodingKeys: String, CodingKey { case configuration, status, networks }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        configuration = try values.decode(Configuration.self, forKey: .configuration)
        // Installed CLI 1.0 uses nested status; this checkout uses a flat status.
        if let status = try? values.decode(String.self, forKey: .status) {
            state = status
            networks = try values.decodeIfPresent([Network].self, forKey: .networks) ?? []
        } else {
            let status = try values.decode(LegacyStatus.self, forKey: .status)
            state = status.state
            networks = status.networks ?? []
        }
    }
}

private struct ImageDTO: Decodable {
    struct Configuration: Decodable { let name: String }
    struct Variant: Decodable {
        struct Platform: Decodable { let architecture: String }
        let size: Int64
        let platform: Platform
    }
    let configuration: Configuration
    let variants: [Variant]
}

public func formattedBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary)
}
