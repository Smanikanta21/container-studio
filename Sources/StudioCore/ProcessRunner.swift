import Darwin
import Foundation

public enum CommandError: Error, LocalizedError, Sendable, Equatable {
    case missingCLI, timedOut, outputLimit, failed(Int32, String)
    public var errorDescription: String? {
        switch self {
        case .missingCLI: "Apple's container CLI was not found. Install it, or set CONTAINER_STUDIO_CLI to its executable path."
        case .timedOut: "The container command timed out. Check the engine in Terminal and try Refresh."
        case .outputLimit: "The command exceeded the 4 MB output limit. Narrow the request and try again."
        case .failed(let code, let message): "Command failed (\(code)). \(message)"
        }
    }
}

public struct CommandOutput: Sendable, Equatable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
}

private struct RawCommandOutput: Sendable {
    let stdout: Data
    let stderr: Data
    let exitCode: Int32
}

public struct ProcessRunner: Sendable {
    public let executable: URL
    public init(executable: URL) { self.executable = executable }

    public func run(_ arguments: [String], timeout: TimeInterval = 10, outputLimit: Int = 4_194_304) async throws -> Data {
        let result = try await collect(arguments, timeout: timeout, outputLimit: outputLimit)
        guard result.exitCode == 0 else {
            let diagnostic = result.stderr.isEmpty ? result.stdout : result.stderr
            throw CommandError.failed(result.exitCode, String(decoding: diagnostic.prefix(4096), as: UTF8.self))
        }
        return result.stdout
    }

    public func runResult(_ arguments: [String], timeout: TimeInterval = 10, outputLimit: Int = 4_194_304) async throws -> CommandOutput {
        let result = try await collect(arguments, timeout: timeout, outputLimit: outputLimit)
        return CommandOutput(stdout: String(decoding: result.stdout, as: UTF8.self), stderr: String(decoding: result.stderr, as: UTF8.self), exitCode: result.exitCode)
    }

    private func collect(_ arguments: [String], timeout: TimeInterval, outputLimit: Int) async throws -> RawCommandOutput {
        let job = CommandJob(executable: executable, arguments: arguments, outputLimit: outputLimit)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                // A blocking wait must not occupy Swift's cooperative executor.
                // A private serial dispatch queue permits GCD to service pipe reads
                // while many callers are suspended awaiting their commands.
                let queue = DispatchQueue(label: "dev.containerstudio.command", qos: .utility)
                queue.async { continuation.resume(with: Result { try job.execute(timeout: timeout) }) }
            }
        } onCancel: {
            job.cancel(CancellationError())
        }
    }
}

// Process and pipe reads stay off the main actor. The lock protects cancellation,
// output budgets and launch/exit races across the two pipe readers and the caller.
private final class CommandJob: @unchecked Sendable {
    // Pipe readers and waitUntilExit block worker threads. Deadlines and forced
    // termination must have their own queue so concurrent reads cannot starve them.
    private static let lifecycleQueue = DispatchQueue(label: "dev.containerstudio.process-lifecycle", qos: .userInitiated)
    private let process = Process()
    private let lock = NSLock()
    private let outputLimit: Int
    private var failure: (any Error)?
    private var finished = false
    private var started = false
    private var output = Data()
    private var errors = Data()

    init(executable: URL, arguments: [String], outputLimit: Int) {
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        self.outputLimit = outputLimit
    }

    func cancel(_ error: any Error) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        if failure == nil { failure = error }
        if started && process.isRunning { process.terminate() }
        lock.unlock()
        Self.lifecycleQueue.asyncAfter(deadline: .now() + 0.3) { [self] in
            lock.lock()
            if !finished && started && process.isRunning { kill(process.processIdentifier, SIGKILL) }
            lock.unlock()
        }
    }

    func execute(timeout: TimeInterval) throws -> RawCommandOutput {
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        lock.lock()
        if let failure { lock.unlock(); throw failure }
        do { try process.run(); started = true; lock.unlock() }
        catch { finished = true; lock.unlock(); throw error }

        let timer = DispatchWorkItem { [weak self] in self?.cancel(CommandError.timedOut) }
        Self.lifecycleQueue.asyncAfter(deadline: .now() + timeout, execute: timer)
        let readers = DispatchGroup()
        for (pipe, isError) in [(stdout, false), (stderr, true)] {
            readers.enter()
            DispatchQueue.global(qos: .utility).async { [self] in
                defer { readers.leave(); try? pipe.fileHandleForReading.close() }
                do {
                    while let chunk = try pipe.fileHandleForReading.read(upToCount: 65_536), !chunk.isEmpty {
                        lock.lock()
                        let remaining = max(0, outputLimit - output.count - errors.count)
                        if isError { errors.append(chunk.prefix(remaining)) }
                        else { output.append(chunk.prefix(remaining)) }
                        lock.unlock()
                        if chunk.count > remaining { cancel(CommandError.outputLimit) }
                    }
                } catch { cancel(error) }
            }
        }
        process.waitUntilExit()
        readers.wait()
        timer.cancel()
        lock.lock()
        finished = true
        let error = failure
        let result = output
        let detail = errors
        lock.unlock()
        if let error { throw error }
        return RawCommandOutput(stdout: result, stderr: detail, exitCode: process.terminationStatus)
    }
}
