//
//  AppleMailProvider.swift
//  Isle
//

import Foundation

/// Drives the user's Mail.app over AppleScript, in-process via `NSAppleScript`.
///
/// In-process on purpose: Apple Events TCC ("Isle wants to control Mail") attributes
/// to the process *sending* the event, so sending from Isle keeps the grant on Isle's
/// signed identity — a spawned `osascript` would misattribute it (same reasoning as
/// the mic/Reminders grants). `NSAppleScript` isn't thread-safe, so every script runs
/// on one dedicated serial queue; each call compiles and runs its own instance there.
///
/// Data marshaling: scripts return a flat string with fields joined by US (unit
/// separator, 0x1F) and records by RS (record separator, 0x1E) — control chars that
/// don't occur in normal headers — which we split back in Swift. `get`'s body is the
/// final field, so any stray separators inside it survive the bounded split.
nonisolated final class AppleMailProvider: MailProvider, @unchecked Sendable {
    private let queue = DispatchQueue(label: "DestinerLabs.Isle.applescript")

    private static let unit = "\u{1F}"
    private static let record = "\u{1E}"

    // MARK: - Reads

    func list(mailbox: String?, account: String?, limit: Int, unreadOnly: Bool) async throws -> [EmailDTO] {
        try await rows(mailbox: mailbox, account: account, limit: limit, whose: whoseClause(query: nil, unreadOnly: unreadOnly))
    }

    func search(query: String, mailbox: String?, account: String?, limit: Int, unreadOnly: Bool) async throws -> [EmailDTO] {
        try await rows(mailbox: mailbox, account: account, limit: limit, whose: whoseClause(query: query, unreadOnly: unreadOnly))
    }

    private func rows(mailbox: String?, account: String?, limit: Int, whose: String) async throws -> [EmailDTO] {
        let box = Self.mailboxExpr(mailbox: mailbox, account: account)
        // Per-message property reads, bounded to `lim`. This is deliberately not the
        // "bulk list" idiom: `messages 1 thru lim` range specifiers aren't supported on
        // the aggregate `inbox`, and forcing a whole-mailbox `get` blows past the ~120s
        // Apple Event timeout. Element access (`item i of msgs`) stays bounded and works
        // on every mailbox — it's ~10 events per message, but reliably so.
        let source = """
        \(Self.prelude)
        tell application "Mail"
            set theBox to \(box)
            set msgs to (messages of theBox\(whose))
            set total to (count of msgs)
            set lim to \(max(0, limit))
            if total < lim then set lim to total
            set out to ""
            repeat with i from 1 to lim
                set m to item i of msgs
                set mb to mailbox of m
                set acc to account of mb
                set out to out & ((id of m) as string) & US & ((subject of m) as string) & US & ((sender of m) as string) & US & my isoDate(date received of m) & US & ((name of mb) as string) & US & ((name of acc) as string) & US & ((read status of m) as string) & RS
            end repeat
            return out
        end tell
        """
        let raw = try await run(source)
        return raw.components(separatedBy: Self.record)
            .filter { !$0.isEmpty }
            .compactMap { Self.parseRow($0) }
    }

    func get(id: String) async throws -> EmailDTO {
        let ref = try Self.decodeID(id)
        let source = """
        \(Self.prelude)
        tell application "Mail"
            set m to (first message of \(Self.messageBox(ref)) whose id is \(ref.id))
            set mb to mailbox of m
            set acc to account of mb
            set toList to ""
            try
                set toList to my joinAddrs(address of to recipients of m)
            end try
            set ccList to ""
            try
                set ccList to my joinAddrs(address of cc recipients of m)
            end try
            return ((subject of m) as string) & US & ((sender of m) as string) & US & toList & US & ccList & US & my isoDate(date received of m) & US & ((name of mb) as string) & US & ((name of acc) as string) & US & ((read status of m) as string) & US & ((content of m) as string)
        end tell
        """
        let raw = try await run(source)
        // Body is the final field: split with a bounded count so any US inside the
        // body doesn't get chopped off.
        let parts = raw.components(separatedBy: Self.unit)
        guard parts.count >= 9 else { throw MailError.notFound }
        let body = parts[8...].joined(separator: Self.unit)
        return EmailDTO(
            id: id, subject: parts[0], sender: parts[1],
            to: parts[2].isEmpty ? nil : parts[2],
            cc: parts[3].isEmpty ? nil : parts[3],
            date: parts[4], mailbox: parts[5], account: parts[6],
            unread: parts[7] == "false", body: body)
    }

    func mailboxes() async throws -> [MailboxDTO] {
        let source = """
        \(Self.prelude)
        tell application "Mail"
            set out to ""
            repeat with acc in accounts
                set accName to (name of acc) as string
                repeat with mb in (mailboxes of acc)
                    set out to out & ((name of mb) as string) & US & accName & US & ((unread count of mb) as string) & RS
                end repeat
            end repeat
            return out
        end tell
        """
        let raw = try await run(source)
        return raw.components(separatedBy: Self.record)
            .filter { !$0.isEmpty }
            .compactMap { row in
                let f = row.components(separatedBy: Self.unit)
                guard f.count == 3, let unread = Int(f[2]) else { return nil }
                return MailboxDTO(name: f[0], account: f[1], unreadCount: unread)
            }
    }

    // MARK: - Writes

    func send(to: [String], cc: [String], bcc: [String], subject: String, body: String) async throws {
        _ = try await run(composeScript(to: to, cc: cc, bcc: bcc, subject: subject, body: body, action: "send msg", visible: false))
    }

    func createDraft(to: [String], cc: [String], bcc: [String], subject: String, body: String) async throws {
        _ = try await run(composeScript(to: to, cc: cc, bcc: bcc, subject: subject, body: body, action: "save msg", visible: true))
    }

    func markRead(id: String, read: Bool) async throws {
        let ref = try Self.decodeID(id)
        let source = """
        tell application "Mail"
            set m to (first message of \(Self.messageBox(ref)) whose id is \(ref.id))
            set read status of m to \(read ? "true" : "false")
        end tell
        """
        _ = try await run(source)
    }

    private func composeScript(
        to: [String], cc: [String], bcc: [String], subject: String, body: String,
        action: String, visible: Bool
    ) -> String {
        func recipients(_ kind: String, _ addrs: [String]) -> String {
            addrs.map { "make new \(kind) at end of \(kind)s with properties {address:\(Self.literal($0))}" }
                .joined(separator: "\n        ")
        }
        return """
        tell application "Mail"
            set msg to make new outgoing message with properties {subject:\(Self.literal(subject)), content:\(Self.literal(body)), visible:\(visible ? "true" : "false")}
            tell msg
                \(recipients("to recipient", to))
                \(recipients("cc recipient", cc))
                \(recipients("bcc recipient", bcc))
            end tell
            \(action)
        end tell
        """
    }

    // MARK: - Script assembly

    /// A `whose` filter for the message fetch, or "" for none.
    private func whoseClause(query: String?, unreadOnly: Bool) -> String {
        var terms: [String] = []
        if unreadOnly { terms.append("(read status is false)") }
        if let query, !query.isEmpty {
            terms.append("((subject contains \(Self.literal(query))) or (sender contains \(Self.literal(query))))")
        }
        guard !terms.isEmpty else { return "" }
        return " whose (" + terms.joined(separator: " and ") + ")"
    }

    /// The mailbox reference to read from: the aggregate `inbox` by default, or a
    /// named mailbox (optionally scoped to an account).
    ///
    /// `internal` (not `private`) for `IsleTests`. Mail's special mailboxes are
    /// app-level *keywords* (`inbox`, `sent mailbox`, …), not mailboxes *named*
    /// "inbox"/"sent" — a literal lookup on those throws "no such object". The model
    /// often passes `mailbox: "inbox"` explicitly, so map the well-known names to
    /// their keywords; everything else is a real named-mailbox lookup.
    static func mailboxExpr(mailbox: String?, account: String?) -> String {
        let acc = account.flatMap { $0.isEmpty ? nil : $0 }
        guard let mailbox, !mailbox.isEmpty else { return "inbox" }
        switch mailbox.lowercased() {
        case "inbox":
            // The aggregate `inbox` keyword can't be scoped to an account, but a
            // per-account IMAP inbox is conventionally "INBOX".
            if let acc { return "mailbox \"INBOX\" of account \(literal(acc))" }
            return "inbox"
        case "sent", "sent messages", "sent mail": return "sent mailbox"
        case "drafts": return "drafts mailbox"
        case "trash", "bin", "deleted", "deleted messages": return "trash mailbox"
        case "junk", "spam": return "junk mailbox"
        default:
            if let acc { return "mailbox \(literal(mailbox)) of account \(literal(acc))" }
            return "mailbox \(literal(mailbox))"
        }
    }

    /// The exact mailbox a `MailRef` points at, for by-id lookups.
    private static func messageBox(_ ref: MailRef) -> String {
        "mailbox \(literal(ref.mailbox)) of account \(literal(ref.account))"
    }

    /// Handlers shared by the read scripts: `isoDate` renders a Mail date as local
    /// ISO 8601 (no tz), `joinAddrs` flattens a recipient-address list.
    private static let prelude = """
    set US to (character id 31)
    set RS to (character id 30)
    on pad2(n)
        set s to "0" & (n as string)
        return text -2 thru -1 of s
    end pad2
    on isoDate(d)
        if d is missing value then return ""
        set y to (year of d) as integer
        set mo to (month of d) as integer
        set dy to day of d
        return (y as string) & "-" & my pad2(mo) & "-" & my pad2(dy) & "T" & my pad2(hours of d) & ":" & my pad2(minutes of d) & ":" & my pad2(seconds of d)
    end isoDate
    on joinAddrs(lst)
        set AppleScript's text item delimiters to ", "
        set s to lst as string
        set AppleScript's text item delimiters to ""
        return s
    end joinAddrs
    """

    // MARK: - AppleScript execution

    private func run(_ source: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard let script = NSAppleScript(source: source) else {
                    continuation.resume(throwing: MailError.script("failed to compile")); return
                }
                var errorInfo: NSDictionary?
                let descriptor = script.executeAndReturnError(&errorInfo)
                if let errorInfo {
                    continuation.resume(throwing: Self.mapError(errorInfo)); return
                }
                continuation.resume(returning: descriptor.stringValue ?? "")
            }
        }
    }

    private static func mapError(_ info: NSDictionary) -> MailError {
        let code = (info[NSAppleScript.errorNumber] as? Int) ?? 0
        let message = (info[NSAppleScript.errorMessage] as? String) ?? "unknown error"
        switch code {
        case -1743, -10004: return .notPermitted        // errAEEventNotPermitted / privilege violation
        case -1728: return .notFound                     // errAENoSuchObject
        default: return .script("\(message) (\(code))")
        }
    }

    // MARK: - Row parsing & id codec

    // `internal` (not `private`) so `IsleTests` can exercise the parsing/escaping
    // without a live Mail.app.
    static func parseRow(_ row: String) -> EmailDTO? {
        let f = row.components(separatedBy: unit)
        guard f.count == 7, let numericID = Int(f[0]) else { return nil }
        let account = f[5], mailbox = f[4]
        return EmailDTO(
            id: encodeID(MailRef(account: account, mailbox: mailbox, id: numericID)),
            subject: f[1], sender: f[2], to: nil, cc: nil,
            date: f[3], mailbox: mailbox, account: account,
            unread: f[6] == "false", body: nil)
    }

    private static func encodeID(_ ref: MailRef) -> String {
        guard let data = try? JSONEncoder().encode(ref) else { return "" }
        return data.base64EncodedString()
    }

    private static func decodeID(_ id: String) throws -> MailRef {
        guard let data = Data(base64Encoded: id),
              let ref = try? JSONDecoder().decode(MailRef.self, from: data) else {
            throw MailError.badID(id)
        }
        return ref
    }

    /// Escapes a Swift string into an AppleScript string *expression*. Newlines
    /// become `& linefeed &` joins (AppleScript literals can't hold raw newlines),
    /// and quotes/backslashes are escaped; empty → `""`.
    static func literal(_ s: String) -> String {
        let lines = s.components(separatedBy: "\n").map { line -> String in
            let escaped = line.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }
        return lines.count == 1 ? lines[0] : lines.joined(separator: " & linefeed & ")
    }
}

/// The concrete Mail coordinates behind an opaque `EmailDTO.id`. Mail's per-message
/// numeric `id` is only unique within an account+mailbox, so all three are kept.
nonisolated private struct MailRef: Codable {
    let account: String
    let mailbox: String
    let id: Int
}
