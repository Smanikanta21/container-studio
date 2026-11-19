import AppKit
import Darwin
import Foundation

@MainActor
enum StudioInstance {
    private static var lockDescriptor: Int32 = -1

    static func acquire() -> Bool {
        if activateExisting() { return false }
        do {
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let directory = support.appendingPathComponent("ContainerStudio", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let descriptor = open(directory.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else { return !activateExisting() }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                close(descriptor)
                _ = activateExisting()
                return false
            }
            // Keep the lock for this process's lifetime. The OS releases it on exit.
            lockDescriptor = descriptor
            return true
        } catch {
            return !activateExisting()
        }
    }

    @discardableResult private static func activateExisting() -> Bool {
        let current = ProcessInfo.processInfo.processIdentifier
        guard let existing = NSWorkspace.shared.runningApplications.first(where: {
            $0.processIdentifier != current && !$0.isTerminated && processIsAlive($0.processIdentifier)
                && ($0.executableURL?.lastPathComponent == "ContainerStudio"
                    || $0.bundleIdentifier == "dev.containerstudio.prototype")
        }) else { return false }
        existing.activate(options: [.activateAllWindows])
        return true
    }

    private static func processIsAlive(_ pid: pid_t) -> Bool {
        // Launch Services can retain a killed Xcode debug target until it is reaped.
        // Such a registration must not prevent a fresh app window from opening.
        var process = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var query: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        if sysctl(&query, 4, &process, &size, nil, 0) == 0 {
            return size > 0 && process.kp_proc.p_stat != SZOMB
        }
        return kill(pid, 0) == 0 || errno == EPERM
    }
}
