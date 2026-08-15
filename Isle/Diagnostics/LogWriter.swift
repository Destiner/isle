//
//  LogWriter.swift
//  Isle
//

import Foundation

/// Serial file appender behind `Log`. Owns the log directory and file handles and
/// does every write on one private queue, so callers from any thread/actor
/// (the agent loop off-main, `ReminderTools` nonisolated, the main actor) can hand
/// it finished JSONL lines without interleaving or locking themselves.
///
/// Two write targets: a single always-open `app.jsonl` for app-scoped events
/// (launch, MCP/ASR, idle-clear) and one `<stamp>-<id>.jsonl` per conversation
/// for turn/codex/tool events. The conversation file is swapped on
/// `beginConversation`; nothing is deleted or rotated.
final class LogWriter: @unchecked Sendable {
    static let shared = LogWriter()

    private let queue = DispatchQueue(label: "DestinerLabs.Isle.log")
    private let directory: URL

    private var appHandle: FileHandle?
    private var convHandle: FileHandle?

    private init() {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        directory = base.appendingPathComponent("Isle/logs", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
    }

    /// Opens a fresh file for a new conversation. `stamp` is a filesystem-safe
    /// timestamp and `id` the short conversation id, so files sort chronologically
    /// (`2026-07-02_143005-a1b2.jsonl`).
    func beginConversation(stamp: String, id: String) {
        queue.async {
            try? self.convHandle?.close()
            self.convHandle = self.open("\(stamp)-\(id).jsonl")
        }
    }

    /// Closes the current conversation file (the next `beginConversation` opens a
    /// new one). Called when the conversation is cleared.
    func endConversation() {
        queue.async {
            try? self.convHandle?.close()
            self.convHandle = nil
        }
    }

    /// Appends one JSONL line to the app-scoped file.
    func writeApp(_ line: String) {
        queue.async {
            if self.appHandle == nil { self.appHandle = self.open("app.jsonl") }
            self.append(line, to: self.appHandle)
        }
    }

    /// Appends one JSONL line to the current conversation file, falling back to
    /// the app file if no conversation is open (shouldn't happen in practice).
    func writeConversation(_ line: String) {
        queue.async {
            let handle = self.convHandle ?? {
                if self.appHandle == nil { self.appHandle = self.open("app.jsonl") }
                return self.appHandle
            }()
            self.append(line, to: handle)
        }
    }

    // MARK: - Queue-confined helpers

    private func open(_ name: String) -> FileHandle? {
        let url = directory.appendingPathComponent(name)
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        let handle = try? FileHandle(forWritingTo: url)
        try? handle?.seekToEnd()
        return handle
    }

    private func append(_ line: String, to handle: FileHandle?) {
        guard let handle, let data = (line + "\n").data(using: .utf8) else { return }
        try? handle.write(contentsOf: data)
    }
}
