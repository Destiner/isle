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
///
/// Codex runs against an Isle-owned `CODEX_HOME` (see `ensureCodexHome`) so it
/// loads Isle's own `AGENTS.md` (`systemPrompt`) instead of the user's personal
/// `~/.codex/AGENTS.md` and `config.toml`, which are tuned for coding sessions,
/// not spoken Q&A. The ChatGPT login is shared by symlinking `auth.json` back to
/// the real `~/.codex`, so there are still no API keys to wire up.
struct CodexClient {
    /// System prompt written to the isolated `CODEX_HOME`'s `AGENTS.md`. See
    /// `Preferences.systemPrompt`.
    var systemPrompt: String = Preferences().systemPrompt

    /// Model passed to `codex exec` via `-c model`. Set here rather than
    /// inherited, because the isolated home has no `~/.codex/config.toml`. See
    /// `Preferences.codexModel`.
    var model: String = Preferences().codexModel

    /// Streamable-HTTP URL of Isle's in-process MCP server (`MCPHTTPServer`). When
    /// set, `ensureCodexHome()` writes an `[mcp_servers.reminders]` entry so Codex
    /// can call Isle's reminder tools; when `nil`, any stale entry is removed.
    var mcpReminderURL: String? = nil

    /// One message in the running conversation, replayed to Codex for context.
    struct Turn {
        enum Role: String { case user = "User", assistant = "Assistant" }
        let role: Role
        let text: String
    }

    /// A failed Codex run, mapped to a short, human-readable line for the pill.
    /// The raw stderr is logged (not shown) — these are display strings, so the
    /// full banner never reaches the user. `classify(exitCode:stderr:)` picks the
    /// case from common Codex failure signatures; anything unrecognized is `.failed`.
    enum CodexError: LocalizedError, Equatable {
        case launchFailed         // the process couldn't even start (e.g. no zsh)
        case notInstalled         // codex isn't on PATH (zsh exits 127)
        case usageLimit           // hit the ChatGPT/Codex usage cap
        case notAuthenticated     // needs `codex login`
        case modelUnavailable     // unknown/unsupported model
        case serviceUnavailable   // network down / OpenAI 5xx
        case failed               // an unrecognized non-zero exit
        case emptyResponse        // exited cleanly but wrote no message

        var errorDescription: String? {
            switch self {
            case .launchFailed:       "Couldn't start Codex"
            case .notInstalled:       "Codex CLI not found"
            case .usageLimit:         "Codex usage limit reached"
            case .notAuthenticated:   "Codex isn't signed in"
            case .modelUnavailable:   "Codex model unavailable"
            case .serviceUnavailable: "Can't reach Codex"
            case .failed:             "Codex failed"
            case .emptyResponse:      "Codex had nothing to say"
            }
        }

        /// Maps a non-zero `codex exec` run to a display case by scanning stderr
        /// for well-known markers. Order matters: the usage-limit / auth checks run
        /// before the broad `model` check because Codex's startup banner always
        /// prints `model: …`, which would otherwise swallow more specific failures.
        static func classify(exitCode: Int32, stderr: String) -> CodexError {
            let lower = stderr.lowercased()
            if exitCode == 127 || lower.contains("command not found") { return .notInstalled }
            if lower.contains("usage limit") || lower.contains("rate limit")
                || lower.contains("429") { return .usageLimit }
            if lower.contains("not logged in") || lower.contains("codex login")
                || lower.contains("unauthorized") || lower.contains("401") {
                return .notAuthenticated
            }
            if lower.contains("model") && (lower.contains("not found")
                || lower.contains("does not exist") || lower.contains("unknown")
                || lower.contains("unsupported") || lower.contains("not supported")) {
                return .modelUnavailable
            }
            if lower.contains("connection") || lower.contains("network")
                || lower.contains("timed out") || lower.contains("timeout")
                || lower.contains("502") || lower.contains("503")
                || lower.contains("service unavailable") { return .serviceUnavailable }
            return .failed
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
        Log.codexRequest(model: model, effort: effort, historyTurns: history.count, prompt: composed)
        let start = Date()
        func elapsedMs() -> Int { Int(Date().timeIntervalSince(start) * 1000) }

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
                + "--color never -c model=\"$ISLE_MODEL\" "
                + "-c model_reasoning_effort=\"$ISLE_EFFORT\" "
                + "-C \"$ISLE_WD\" -o \"$ISLE_OUT\" -",
        ]

        var env = ProcessInfo.processInfo.environment
        // Point Codex at Isle's own config dir so it loads Isle's system prompt,
        // not the user's personal ~/.codex/AGENTS.md (see `ensureCodexHome`).
        env["CODEX_HOME"] = (try? ensureCodexHome().path) ?? env["CODEX_HOME"]
        env["ISLE_OUT"] = outURL.path
        env["ISLE_WD"] = workDir.path
        env["ISLE_EFFORT"] = effort
        env["ISLE_MODEL"] = model
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
                    let classified = CodexError.classify(
                        exitCode: proc.terminationStatus, stderr: stderr)
                    Log.codexError("\(classified)", exitCode: proc.terminationStatus,
                                   stderr: stderr, durationMs: elapsedMs())
                    continuation.resume(throwing: classified)
                    return
                }
                guard let message, !message.isEmpty else {
                    Log.codexError("emptyResponse", exitCode: proc.terminationStatus,
                                   durationMs: elapsedMs())
                    continuation.resume(throwing: CodexError.emptyResponse)
                    return
                }
                Log.codexResponse(chars: message.count, durationMs: elapsedMs())
                continuation.resume(returning: message)
            }

            do {
                try process.run()
            } catch {
                Log.codexError("launchFailed", stderr: "\(error)", durationMs: elapsedMs())
                continuation.resume(throwing: CodexError.launchFailed)
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

    /// Prepares Isle's private Codex config dir and returns it for `CODEX_HOME`.
    /// It holds Isle's `AGENTS.md` (the system prompt, rewritten every run so it
    /// stays the source of truth) and an `auth.json` symlink back to the real
    /// `~/.codex` so the ChatGPT login is shared — no separate `codex login`.
    ///
    /// The symlink is re-created whenever it's missing or no longer points at the
    /// real auth: Codex only rewrites `auth.json` on a token refresh (rare, and
    /// via temp-file-then-rename, which would replace the symlink with a real
    /// file), so restoring it here keeps the shared-login invariant. Isle also
    /// gets its own fresh memories/goals/session state under this home, isolated
    /// from the user's coding sessions.
    /// Returns `toml` with any `[mcp_servers.reminders]` table removed — its header
    /// line plus the key lines up to the next table header (a line starting with
    /// `[`) or end of file — so the block can be re-written without disturbing the
    /// rest of the file.
    private static func removingReminderServer(from toml: String) -> String {
        guard toml.contains("[mcp_servers.reminders]") else { return toml }
        var kept: [Substring] = []
        var skipping = false
        for line in toml.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "[mcp_servers.reminders]" {
                skipping = true
                continue
            }
            if skipping {
                if trimmed.hasPrefix("[") { skipping = false } else { continue }
            }
            kept.append(line)
        }
        return kept.joined(separator: "\n")
    }

    private func ensureCodexHome() throws -> URL {
        let fm = FileManager.default
        let home = try fm.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
            .appendingPathComponent("Isle/codex-home", isDirectory: true)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)

        let agents = home.appendingPathComponent("AGENTS.md")
        try systemPrompt.write(to: agents, atomically: true, encoding: .utf8)

        // Register (or clear) Isle's own MCP tool server. Model/effort still come
        // from the `-c` flags on the command line, so this config only carries the
        // tool server. We strip any existing `[mcp_servers.reminders]` block and
        // re-append a fresh one rather than overwriting the whole file, so config
        // Codex manages in this home (e.g. `[projects.*]` trust entries) survives.
        let config = home.appendingPathComponent("config.toml")
        let existing = (try? String(contentsOf: config, encoding: .utf8)) ?? ""
        var body = Self.removingReminderServer(from: existing)
        if let url = mcpReminderURL {
            if !body.isEmpty && !body.hasSuffix("\n") { body += "\n" }
            body += "[mcp_servers.reminders]\nurl = \"\(url)\"\n"
        }
        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? fm.removeItem(at: config)
        } else {
            try body.write(to: config, atomically: true, encoding: .utf8)
        }

        let realAuth = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
        let link = home.appendingPathComponent("auth.json")
        let dest = try? fm.destinationOfSymbolicLink(atPath: link.path)
        if dest != realAuth.path {
            try? fm.removeItem(at: link)
            try fm.createSymbolicLink(at: link, withDestinationURL: realAuth)
        }
        return home
    }
}
