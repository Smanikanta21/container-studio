import Foundation

public enum ContainerToolError: Error, LocalizedError {
    case emptyScript, scriptTooLarge, unsupportedShell

    public var errorDescription: String? {
        switch self {
        case .emptyScript: "Enter a script to run inside this container."
        case .scriptTooLarge: "Scripts must be smaller than 128 KB."
        case .unsupportedShell: "Choose /bin/sh or /bin/bash. The shell must exist in the container."
        }
    }
}

public enum ContainerTools {
    public static let maximumScriptBytes = 131_072

    public static func logsArguments(id: String, lines: Int = 200, boot: Bool = false) -> [String] {
        ["logs"] + (boot ? ["--boot"] : []) + ["-n", String(min(max(lines, 1), 5000)), "--", id]
    }

    public static func scriptArguments(id: String, shell: String, script: String) throws -> [String] {
        try validateShell(shell)
        guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ContainerToolError.emptyScript }
        guard script.utf8.count <= maximumScriptBytes else { throw ContainerToolError.scriptTooLarge }
        // Pass the script to the container shell; a host shell never interprets it.
        return ["exec", "--", id, shell, "-c", script]
    }

    public static func terminalCommand(executable: URL, id: String, shell: String) throws -> String {
        return ([executable.path] + (try terminalArguments(id: id, shell: shell)))
            .map(shellQuote).joined(separator: " ")
    }

    public static func terminalArguments(id: String, shell: String) throws -> [String] {
        try validateShell(shell)
        return ["exec", "--interactive", "--tty", "--", id, shell]
    }

    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func validateShell(_ shell: String) throws {
        guard ["/bin/sh", "/bin/bash"].contains(shell) else { throw ContainerToolError.unsupportedShell }
    }
}
