import Foundation
import Testing
@testable import StudioCore

@Test func terminalArgumentsAreInteractiveAndIsolateContainerID() throws {
    #expect(try ContainerTools.terminalArguments(id: "--odd name", shell: "/bin/sh") == ["exec", "--interactive", "--tty", "--", "--odd name", "/bin/sh"])
}

@Test func containerFileNamesPreserveSpacesNewlinesAndHiddenFiles() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for name in [".hidden", "space name", "line\nbreak", "quote'file"] {
        try Data("text".utf8).write(to: root.appendingPathComponent(name))
    }
    try FileManager.default.createDirectory(at: root.appendingPathComponent("folder"), withIntermediateDirectories: true)
    let data = try await runFileScript(ContainerFilesystem.listScript, [root.path])
    let files = try ContainerFilesystem.decodeEntries(data)
    #expect(files.first?.name == "folder")
    #expect(Set(files.map(\.name)) == [".hidden", "space name", "line\nbreak", "quote'file", "folder"])
}

@Test func fileSavePreservesTextAndRejectsExternalChanges() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("config 'file")
    try "original\n".write(to: file, atomically: true, encoding: .utf8)
    let initial = try ContainerFilesystem.decodeText(await runFileScript(ContainerFilesystem.readScript, [file.path]))
    let edited = "value=$(touch /should-not-run)\nquote='x'\n"
    _ = try await runFileScript(ContainerFilesystem.saveScript, [file.path, initial.checksum, edited])
    #expect(try String(contentsOf: file, encoding: .utf8) == edited)
    let refreshed = try ContainerFilesystem.decodeText(await runFileScript(ContainerFilesystem.readScript, [file.path]))
    try "external".write(to: file, atomically: true, encoding: .utf8)
    await #expect(throws: CommandError.self) { try await runFileScript(ContainerFilesystem.saveScript, [file.path, refreshed.checksum, "overwritten"]) }
    #expect(try String(contentsOf: file, encoding: .utf8) == "external")
}

@Test func fileEditorRejectsBinaryAndOversizedFiles() async throws {
    #expect(throws: CocoaError.self) { try ContainerFilesystem.decodeText(Data("checksum\0binary\0text".utf8)) }
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    try Data(repeating: 65, count: 65_537).write(to: file)
    await #expect(throws: CommandError.self) { try await runFileScript(ContainerFilesystem.readScript, [file.path]) }
}

private func runFileScript(_ script: String, _ values: [String]) async throws -> Data {
    try await ProcessRunner(executable: URL(fileURLWithPath: "/bin/sh")).run(["-c", script, "studio-files"] + values)
}

@Test func fileSaveRejectsSymbolicLinks() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appendingPathComponent("target")
    let link = root.appendingPathComponent("link")
    try "original".write(to: target, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    let contents = try ContainerFilesystem.decodeText(await runFileScript(ContainerFilesystem.readScript, [link.path]))
    await #expect(throws: CommandError.self) { try await runFileScript(ContainerFilesystem.saveScript, [link.path, contents.checksum, "modified"]) }
    #expect(try String(contentsOf: target, encoding: .utf8) == "original")
}
