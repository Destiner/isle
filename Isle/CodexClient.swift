//
//  CodexClient.swift
//  Isle
//

import Foundation

/// Sends a prompt to the locally-installed Codex CLI (`codex exec`) and returns
/// the assistant's final message. This reuses the user's existing ChatGPT login
/// that the `codex` CLI already holds, so there are no API keys to wire up.
///
/// The CLI is invoked through an interactive login shell (`zsh -ilc`) so it
/// resolves on the user's PATH and inherits the full environment a terminal
/// would — crucial because `codex` lives in `~/.bun/bin`, which is added in
/// `.zshrc` (interactive), not `.zprofile`, so a plain `-lc` login shell can't
/// find it when the app is launched from Finder/launchd. Any prompt noise the
/// interactive shell emits is harmless: the prompt is fed on stdin and the final
/// message is read back from a temp file (`-o`), not parsed from stdout.
struct CodexClient {
    /// One message in the running conversation, replayed to Codex for context.
    struct Turn {
        enum Role: String { case user = "User", assistant = "Assistant" }
        let role: Role
        let text: String
    }

    enum CodexError: LocalizedError {
        case launchFailed(String)
        case nonZeroExit(code: Int32, stderr: String)
        case emptyResponse

        var errorDescription: String? {
            switch self {
            case .launchFailed(let message): "Couldn't launch Codex: \(message)"
            case .nonZeroExit(_, let stderr):
                "Codex failed: \(stderr.isEmpty ? "unknown error" : stderr)"
            case .emptyResponse: "Codex returned an empty response."
            }
        }
    }

    /// Runs `codex exec` non-interactively and returns its final assistant
    /// message. `history` is the conversation so far (excluding `prompt`), which
    /// is replayed in the request so Codex has the full context — `codex exec`
    /// is one-shot per process, so we carry context ourselves rather than
    /// resuming a session. `effort` is `model_reasoning_effort` (low keeps spoken
    /// Q&A snappy; see `Preferences`). Suspends until the CLI exits.
    func send(_ prompt: String, history: [Turn] = [], effort: String = "low") async throws -> String {
        let composed = composePrompt(latest: prompt, history: history)

        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("isle-codex-\(UUID().uuidString).txt")

        // An empty scratch dir keeps Codex from poking around a real project —
        // we only want a conversational answer.
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("isle-codex-workdir", isDirectory: true)
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // `--dangerously-bypass-approvals-and-sandbox` runs the agent unsandboxed
        // so spoken requests can actually act on the machine ("open my Downloads",
        // launch apps, etc.). Under the default read-only sandbox those commands
        // fail (file writes are "Operation not permitted"; `open` dies with
        // `kLSExecutableIncorrectFormat` because Seatbelt blocks LaunchServices).
        process.arguments = [
            "-ilc",
            "codex exec --skip-git-repo-check --ephemeral "
                + "--dangerously-bypass-approvals-and-sandbox "
                + "--color never -c model_reasoning_effort=\"$ISLE_EFFORT\" "
                + "-C \"$ISLE_WD\" -o \"$ISLE_OUT\" -",
        ]

        var env = ProcessInfo.processInfo.environment
        env["ISLE_OUT"] = outURL.path
        env["ISLE_WD"] = workDir.path
        env["ISLE_EFFORT"] = effort
        process.environment = env

        let stdinPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardError = stderrPipe
        process.standardOutput = Pipe()  // discard the event log; we read `-o`

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { proc in
                let stderr = String(
                    data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                ) ?? ""
                let message = (try? String(contentsOf: outURL, encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                try? FileManager.default.removeItem(at: outURL)

                guard proc.terminationStatus == 0 else {
                    continuation.resume(throwing: CodexError.nonZeroExit(
                        code: proc.terminationStatus, stderr: stderr))
                    return
                }
                guard let message, !message.isEmpty else {
                    continuation.resume(throwing: CodexError.emptyResponse)
                    return
                }
                continuation.resume(returning: message)
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: CodexError.launchFailed(error.localizedDescription))
                return
            }

            let handle = stdinPipe.fileHandleForWriting
            handle.write(Data(composed.utf8))
            try? handle.close()
        }
    }

    /// Builds the request fed to Codex. With no history the prompt is sent as-is
    /// (a bare question answers best); otherwise the prior turns are replayed as
    /// a transcript so Codex can answer the latest message in context.
    private func composePrompt(latest: String, history: [Turn]) -> String {
        guard !history.isEmpty else { return latest }

        var lines = [
            "Continue this conversation, replying only to the final user message. "
                + "Keep your answer conversational and concise.",
            "",
        ]
        for turn in history {
            lines.append("\(turn.role.rawValue): \(turn.text)")
        }
        lines.append("User: \(latest)")
        return lines.joined(separator: "\n")
    }
}
