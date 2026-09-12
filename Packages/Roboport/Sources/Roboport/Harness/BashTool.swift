import Foundation

#if os(macOS)
/// Runs a shell command in the session's working directory.
///
/// The command is **not sandboxed**: it runs with the host process's full
/// privileges and TCC identity. That is a deliberate choice for a desktop
/// assistant that is expected to act on the machine, and it means a misheard or
/// misunderstood instruction runs with the same reach the user has. Do not
/// expose this tool in a context where the prompt is untrusted.
public struct BashTool: Tool {
    public let name = "bash"
    public let description = """
        Execute a shell command on the user's Mac and return its output. Use this \
        for anything that needs the local machine: inspecting files, launching \
        apps, querying system state. Prefer a purpose-built tool when one exists.
        """

    public let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "command": .object([
                "type": .string("string"),
                "description": .string("The shell command to run."),
            ]),
            "timeout": .object([
                "type": .string("number"),
                "description": .string(
                    "Optional timeout in seconds (default 60, maximum 300)."),
            ]),
        ]),
        "required": .array([.string("command")]),
    ])

    /// Output handed back to the model, truncated so one `find /` cannot swamp
    /// the context window.
    private let maxOutputBytes: Int
    private let defaultTimeout: TimeInterval
    private let maxTimeout: TimeInterval

    public init(
        maxOutputBytes: Int = 30_000,
        defaultTimeout: TimeInterval = 60,
        maxTimeout: TimeInterval = 300
    ) {
        self.maxOutputBytes = maxOutputBytes
        self.defaultTimeout = defaultTimeout
        self.maxTimeout = maxTimeout
    }

    public func execute(_ input: JSONValue, context: ToolContext) async throws -> String {
        guard let command = input["command"]?.stringValue, !command.isEmpty else {
            return "Error: `command` is required."
        }
        let requested = input["timeout"]?.doubleValue ?? defaultTimeout
        let timeout = min(max(requested, 1), maxTimeout)

        let result = try await Shell.run(command, cwd: context.cwd, timeout: timeout)
        return format(result)
    }

    private func format(_ result: Shell.Result) -> String {
        var sections: [String] = []
        let stdout = truncate(result.stdout)
        let stderr = truncate(result.stderr)

        if !stdout.isEmpty { sections.append(stdout) }
        if !stderr.isEmpty { sections.append("stderr:\n\(stderr)") }
        if result.timedOut {
            sections.append("(killed: exceeded the timeout)")
        } else if result.exitCode != 0 {
            sections.append("(exit code \(result.exitCode))")
        }

        // An empty result still needs to say something, or the model reads the
        // blank string as a failure and retries.
        if sections.isEmpty { return "(no output)" }
        return sections.joined(separator: "\n")
    }

    private func truncate(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count > maxOutputBytes else { return trimmed }
        let prefix = String(trimmed.prefix(maxOutputBytes))
        return prefix + "\n… (truncated)"
    }
}

/// Runs a command under `/bin/zsh -lc`, capturing output with a hard timeout.
public enum Shell {
    public struct Result: Sendable {
        public let stdout: String
        public let stderr: String
        public let exitCode: Int32
        public let timedOut: Bool
    }

    public static func run(
        _ command: String, cwd: String, timeout: TimeInterval
    ) async throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        // Drain both pipes concurrently. Reading them in sequence deadlocks as
        // soon as a command fills the other pipe's ~64 KB buffer.
        let collector = OutputCollector()
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            collector.appendOut(data)
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            collector.appendErr(data)
        }

        try process.run()

        let timedOut = await withTaskCancellationHandler {
            await waitForExit(process, timeout: timeout)
        } onCancel: {
            terminateTree(process)
        }

        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil

        return Result(
            stdout: collector.stdoutText(),
            stderr: collector.stderrText(),
            exitCode: process.terminationStatus,
            timedOut: timedOut)
    }

    /// Returns true when the process had to be killed for exceeding `timeout`.
    private static func waitForExit(_ process: Process, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() >= deadline {
                terminateTree(process)
                // Give the kill a moment to land so terminationStatus is settled.
                try? await Task.sleep(nanoseconds: 100_000_000)
                return true
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }

    /// Kill children first, then the shell itself: `zsh -lc` may have spawned a
    /// pipeline, and killing only the shell orphans it.
    private static func terminateTree(_ process: Process) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier

        let lookup = Process()
        lookup.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        lookup.arguments = ["-P", "\(pid)"]
        let pipe = Pipe()
        lookup.standardOutput = pipe
        lookup.standardError = Pipe()
        if (try? lookup.run()) != nil {
            lookup.waitUntilExit()
            let output =
                String(
                    data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            for line in output.split(separator: "\n") {
                if let child = pid_t(line.trimmingCharacters(in: .whitespaces)) {
                    kill(child, SIGKILL)
                }
            }
        }
        kill(pid, SIGKILL)
    }
}

/// Thread-safe accumulator for the two pipe readers, which fire on separate
/// queues.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()

    func appendOut(_ data: Data) {
        lock.lock()
        out.append(data)
        lock.unlock()
    }

    func appendErr(_ data: Data) {
        lock.lock()
        err.append(data)
        lock.unlock()
    }

    func stdoutText() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: out, encoding: .utf8) ?? ""
    }

    func stderrText() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: err, encoding: .utf8) ?? ""
    }
}
#endif
