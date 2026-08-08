//
//  Log.swift
//  Isle
//

import Foundation
import os

/// Isle's single logging facade. Every diagnostic — Codex runs, MCP tool calls,
/// conversation turns, lifecycle — goes through here so there's one place that
/// decides the format, the destination, and whether logging runs.
///
/// **Debug-only.** In Release builds the whole thing compiles to no-ops and never
/// touches the disk, so nothing ships in a distributed build. In Debug it's on by
/// default; the `ISLE_LOG` env var (`0`/`1`) or `Preferences.enableLogging`
/// (via `configure`) can flip it. Env var wins.
///
/// **Output.** Structured JSONL to files under
/// `~/Library/Application Support/Isle/logs/` (the real record — greppable,
/// `jq`-able, per-conversation), mirrored as a compact line to `os_log` so a live
/// run can be watched in Console.app or
/// `log stream --predicate 'subsystem == "DestinerLabs.Isle"'`.
///
/// Every line shares an envelope — `ts`, `level`, `cat`, `event`, and (for
/// conversation-scoped events) `conv` + `turn` — plus event-specific fields.
enum Log {

    enum Level: String { case debug, info, warn, error }

    // MARK: - Gating

    #if DEBUG
    /// Effective on/off. Seeded from the env var (default on in Debug); Preferences
    /// can lower it later via `configure`. Written once at launch, read widely —
    /// benign for a debug tool.
    nonisolated(unsafe) static var isEnabled: Bool = envDefault

    private static var envDefault: Bool {
        switch ProcessInfo.processInfo.environment["ISLE_LOG"]?.lowercased() {
        case "0", "false", "no": return false
        default: return true
        }
    }

    /// Reconcile the compile default with `Preferences.enableLogging`. The
    /// `ISLE_LOG` env var, if set, always wins so it can force logging on/off for a
    /// single launch without a rebuild.
    static func configure(enabled prefEnabled: Bool) {
        switch ProcessInfo.processInfo.environment["ISLE_LOG"]?.lowercased() {
        case "1", "true", "yes": isEnabled = true
        case "0", "false", "no": isEnabled = false
        default: isEnabled = prefEnabled
        }
    }
    #else
    static let isEnabled = false
    static func configure(enabled: Bool) {}
    #endif

    // MARK: - Conversation / turn context
    //
    // The pill handles one conversation and one turn at a time, so "current"
    // context is global. Events auto-tag themselves with it; set from the main
    // actor but read while building lines off-main, so guarded by a lock.

    private static let lock = NSLock()
    private static var currentConv: String?
    private static var currentTurn: String?

    /// Opens a new conversation: mints an id, tags following events with it, and
    /// starts a fresh log file. Idempotent-friendly — a no-op if one is already
    /// open, so callers can lazily ensure a conversation exists.
    static func beginConversation() {
        guard isEnabled else { return }
        lock.lock()
        if currentConv != nil { lock.unlock(); return }
        let id = shortID()
        currentConv = id
        currentTurn = nil
        lock.unlock()
        LogWriter.shared.beginConversation(stamp: fileStamp(), id: id)
        emit(.conversation, cat: "turn", event: "conversation.begin", level: .info, [:])
    }

    /// Closes the current conversation (on idle-clear). The next `beginTurn`
    /// opens a fresh one.
    static func endConversation() {
        guard isEnabled else { return }
        lock.lock()
        let had = currentConv != nil
        lock.unlock()
        guard had else { return }
        emit(.conversation, cat: "turn", event: "conversation.end", level: .info, [:])
        lock.lock(); currentConv = nil; currentTurn = nil; lock.unlock()
        LogWriter.shared.endConversation()
    }

    /// Records a user message, opening a conversation if none is live and starting
    /// a new turn.
    static func turnUser(text: String) {
        guard isEnabled else { return }
        beginConversation()
        let id = shortID()
        lock.lock(); currentTurn = id; lock.unlock()
        emit(.conversation, cat: "turn", event: "user", level: .info,
             ["text": text, "chars": text.count])
    }

    /// Records the assistant's answer, closing the turn. Events that fire between
    /// turns then log against the conversation with no `turn`, rather than being
    /// mis-tagged to the one that just ended.
    static func turnAssistant(text: String) {
        guard isEnabled else { return }
        emit(.conversation, cat: "turn", event: "assistant", level: .info,
             ["text": text, "chars": text.count])
        lock.lock(); currentTurn = nil; lock.unlock()
    }

    // MARK: - Codex

    static func codexRequest(model: String, effort: String, historyTurns: Int, prompt: String) {
        guard isEnabled else { return }
        emit(.conversation, cat: "codex", event: "request", level: .info,
             ["model": model, "effort": effort, "historyTurns": historyTurns,
              "promptChars": prompt.count, "prompt": prompt])
    }

    static func codexResponse(chars: Int, durationMs: Int) {
        guard isEnabled else { return }
        emit(.conversation, cat: "codex", event: "response", level: .info,
             ["chars": chars, "durationMs": durationMs])
    }

    static func codexError(_ kind: String, exitCode: Int32? = nil, stderr: String? = nil,
                           events: String? = nil, durationMs: Int) {
        guard isEnabled else { return }
        var fields: [String: Any] = ["kind": kind, "durationMs": durationMs]
        if let exitCode { fields["exitCode"] = Int(exitCode) }
        if let stderr, !stderr.isEmpty { fields["stderr"] = stderr }
        if let events, !events.isEmpty { fields["events"] = events }
        emit(.conversation, cat: "codex", event: "error", level: .error, fields)
    }

    // MARK: - Tools (MCP)

    /// `arguments` is a Foundation JSON object (dict/array/scalar), embedded as a
    /// nested object so it stays queryable (`jq '.arguments.query'`).
    static func tool(name: String, arguments: Any, isError: Bool, resultChars: Int, durationMs: Int) {
        guard isEnabled else { return }
        emit(.conversation, cat: "tool", event: "call",
             level: isError ? .warn : .info,
             ["tool": name, "arguments": arguments, "isError": isError,
              "resultChars": resultChars, "durationMs": durationMs])
    }

    // MARK: - App lifecycle

    static func app(_ event: String, level: Level = .info, _ fields: [String: Any] = [:]) {
        guard isEnabled else { return }
        emit(.app, cat: "app", event: event, level: level, fields)
    }

    /// General error sink for the scattered failure sites. App-scoped.
    static func error(_ event: String, _ message: String) {
        guard isEnabled else { return }
        emit(.app, cat: "app", event: event, level: .error, ["message": message])
    }

    // MARK: - Emit

    private enum Scope { case app, conversation }

    private static func emit(_ scope: Scope, cat: String, event: String, level: Level, _ fields: [String: Any]) {
        var conv: String?
        var turn: String?
        if scope == .conversation {
            lock.lock()
            conv = currentConv
            turn = currentTurn
            lock.unlock()
        }

        guard let line = jsonLine(cat: cat, event: event, level: level,
                                  timestamp: iso.string(from: Date()),
                                  conv: conv, turn: turn, fields: fields) else { return }

        switch scope {
        case .app: LogWriter.shared.writeApp(line)
        case .conversation: LogWriter.shared.writeConversation(line)
        }

        let logger = Logger(subsystem: "DestinerLabs.Isle", category: cat)
        switch level {
        case .debug: logger.debug("\(line, privacy: .public)")
        case .info: logger.info("\(line, privacy: .public)")
        case .warn: logger.warning("\(line, privacy: .public)")
        case .error: logger.error("\(line, privacy: .public)")
        }
    }

    /// Builds one JSONL line: the caller's `fields` plus the shared envelope
    /// (`ts`/`level`/`cat`/`event`, and `conv`/`turn` when set). Keys are sorted so
    /// the format is stable. Pure and deterministic (timestamp passed in) so it's
    /// unit-testable without touching the disk. Returns `nil` if `fields` holds a
    /// non-JSON value.
    static func jsonLine(cat: String, event: String, level: Level, timestamp: String,
                         conv: String?, turn: String?, fields: [String: Any]) -> String? {
        var obj = fields
        obj["ts"] = timestamp
        obj["level"] = level.rawValue
        obj["cat"] = cat
        obj["event"] = event
        if let conv { obj["conv"] = conv }
        if let turn { obj["turn"] = turn }
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else { return nil }
        return line
    }

    // MARK: - Formatting

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        return f
    }()

    private static func fileStamp() -> String { stampFormatter.string(from: Date()) }

    private static func shortID() -> String {
        String(UUID().uuidString.prefix(8)).lowercased()
    }
}
