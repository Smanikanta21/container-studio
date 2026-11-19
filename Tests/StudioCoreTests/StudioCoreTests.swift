import Foundation
import Testing
@testable import StudioCore

@Test func decodesBothContainerSchemas() throws {
    let configuration = #"""
    "configuration":{"id":"web","image":{"reference":"docker.io/library/node:22"},"resources":{"cpus":2,"memoryInBytes":536870912},"publishedPorts":[{"hostPort":3000,"containerPort":80,"proto":"tcp"}]}
    """#
    let legacy = "[{\(configuration),\"status\":{\"state\":\"running\",\"networks\":[{\"ipv4Address\":\"192.168.64.2\"}]}}]"
    let current = "[{\(configuration),\"status\":\"running\",\"networks\":[{\"ipv4Address\":\"192.168.64.2\"}]}]"
    let a = try SnapshotDecoder.containers(Data(legacy.utf8))
    let b = try SnapshotDecoder.containers(Data(current.utf8))
    #expect(a == b)
    #expect(a.first?.ports == ["3000 → 80/tcp"])
    #expect(a.first?.memoryBytes == 536_870_912)
    #expect(a.first?.isRunning == true)
}

@Test func unknownStateIsPreservedAndMalformedSnapshotFails() throws {
    let json = #"[{"configuration":{"id":"web","image":{"reference":"node"},"resources":{"cpus":1,"memoryInBytes":1}},"status":"starting"}]"#
    let container = try #require(SnapshotDecoder.containers(Data(json.utf8)).first)
    #expect(container.state == "starting")
    #expect(!container.isRunning)
    #expect(throws: (any Error).self) { try SnapshotDecoder.containers(Data("[{\"status\":\"running\"}]".utf8)) }
}

@Test func imageVariantsAreSummedAndArchitecturesDeduplicated() throws {
    let json = #"[{"configuration":{"name":"example:latest"},"variants":[{"size":100,"platform":{"architecture":"arm64"}},{"size":200,"platform":{"architecture":"amd64"}}]}]"#
    let image = try #require(SnapshotDecoder.images(Data(json.utf8)).first)
    #expect(image.bytes == 300)
    #expect(image.architecture == "amd64, arm64")
}

@Test func processArgumentsArePassedLiterally() async throws {
    let runner = ProcessRunner(executable: URL(fileURLWithPath: "/usr/bin/printf"))
    let output = try await runner.run(["%s", "$(echo unexpected); space ' quote"])
    #expect(String(decoding: output, as: UTF8.self) == "$(echo unexpected); space ' quote")
}

@Test func processTimesOut() async throws {
    let runner = ProcessRunner(executable: URL(fileURLWithPath: "/bin/sleep"))
    await #expect(throws: CommandError.timedOut) { try await runner.run(["5"], timeout: 0.05) }
}

@Test func excessiveOutputIsBounded() async throws {
    let runner = ProcessRunner(executable: URL(fileURLWithPath: "/usr/bin/yes"))
    await #expect(throws: CommandError.outputLimit) { try await runner.run([], outputLimit: 1024) }
}

@Test func processCancellationTerminatesChild() async throws {
    let runner = ProcessRunner(executable: URL(fileURLWithPath: "/bin/sleep"))
    let task = Task { try await runner.run(["5"]) }
    try await Task.sleep(for: .milliseconds(50))
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
}

@Test func stderrIsDrainedAndReported() async throws {
    let runner = ProcessRunner(executable: URL(fileURLWithPath: "/bin/sh"))
    do {
        _ = try await runner.run(["-c", "printf 'failure detail' >&2; exit 7"])
        Issue.record("Expected a nonzero exit")
    } catch CommandError.failed(let code, let detail) {
        #expect(code == 7)
        #expect(detail == "failure detail")
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["STUDIO_LIVE_CHECK"] == "1"))
func liveReadOnlyIntegration() async throws {
    let executable = try #require(CLIBackend.discover())
    let backend = CLIBackend(executable: executable)
    let snapshot = try await backend.snapshot()
    #expect(Set(snapshot.containers.map(\.id)).count == snapshot.containers.count)
    if let container = snapshot.containers.first { _ = try await backend.logs(id: container.id) }
}

@Test func scriptRunsOnlyThroughContainerShell() throws {
    let script = "echo '$HOME'; printf '%s\\n' \"$(whoami)\"\nexit 3"
    #expect(try ContainerTools.scriptArguments(id: "--odd name", shell: "/bin/sh", script: script) == ["exec", "--", "--odd name", "/bin/sh", "-c", script])
    #expect(throws: ContainerToolError.self) { try ContainerTools.scriptArguments(id: "web", shell: "/bin/sh", script: " \n") }
    #expect(throws: ContainerToolError.self) { try ContainerTools.scriptArguments(id: "web", shell: "/host/shell", script: "pwd") }
    #expect(throws: ContainerToolError.self) { try ContainerTools.scriptArguments(id: "web", shell: "/bin/sh", script: String(repeating: "a", count: 131_073)) }
}

@Test func detailedLogsAreBoundedAndChooseSource() {
    #expect(ContainerTools.logsArguments(id: "--web", lines: 99999, boot: true) == ["logs", "--boot", "-n", "5000", "--", "--web"])
    #expect(ContainerTools.logsArguments(id: "web", lines: -1) == ["logs", "-n", "1", "--", "web"])
}

@Test func terminalCommandQuotesContainerAndExecutable() throws {
    let command = try ContainerTools.terminalCommand(executable: URL(fileURLWithPath: "/a path/cli'file"), id: "web'; echo leaked", shell: "/bin/sh")
    let output = try awaitShellArgument(command)
    #expect(output == "/a path/cli'file\nexec\n--interactive\n--tty\n--\nweb'; echo leaked\n/bin/sh\n")
}

private func awaitShellArgument(_ command: String) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", "set -- " + command + "; printf '%s\\n' \"$@\""]
    let pipe = Pipe(); process.standardOutput = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    return String(decoding: data, as: UTF8.self)
}

@Test func commandResultRetainsBothStreamsAndFailureExit() async throws {
    let result = try await ProcessRunner(executable: URL(fileURLWithPath: "/bin/sh"))
        .runResult(["-c", "printf 'out'; printf 'err' >&2; exit 7"])
    #expect(result.stdout == "out")
    #expect(result.stderr == "err")
    #expect(result.exitCode == 7)
}

@Test func rawProcessOutputPreservesNonTextBytes() async throws {
    let data = try await ProcessRunner(executable: URL(fileURLWithPath: "/bin/sh"))
        .run(["-c", "printf '\\377\\000\\001'"])
    #expect(data == Data([255, 0, 1]))
}
