//
//  MailService.swift
//  Isle
//

import Foundation

/// An email flattened to a JSON-friendly value — the shape that crosses the actor
/// boundary and gets encoded into a tool result. `to`/`cc`/`body` are only filled
/// in by `get` (the list/search rows are headers-only to keep them cheap).
struct EmailDTO: Codable, Sendable {
    /// Opaque, provider-scoped handle (base64 of `{account, mailbox, id}`) — the
    /// model passes it straight back to `get_email`/`mark_read`. Not human-readable
    /// on purpose; Mail's own message ids aren't globally stable.
    let id: String
    let subject: String
    let sender: String
    let to: String?
    let cc: String?
    /// ISO 8601, local time (Mail's AppleScript dates carry no timezone).
    let date: String
    let mailbox: String
    let account: String
    let unread: Bool
    let body: String?
}

/// A mailbox with its unread count, per account.
struct MailboxDTO: Codable, Sendable {
    let name: String
    let account: String
    let unreadCount: Int
}

/// A mail operation that failed, mapped to a message the model can read back.
enum MailError: LocalizedError {
    case notPermitted
    case notFound
    case badID(String)
    case script(String)
    /// The active backend isn't set up (e.g. no Fastmail API token).
    case notConfigured(String)
    /// A non-AppleScript backend (JMAP/HTTP) failed — the message is already readable.
    case backend(String)

    var errorDescription: String? {
        switch self {
        case .notPermitted:
            "Isle hasn't been granted Automation access to Mail. Grant it in System Settings › Privacy & Security › Automation, then relaunch Isle."
        case .notFound:
            "No matching message was found (it may have moved or been deleted)."
        case .badID(let id):
            "\"\(id)\" isn't a valid message id (use one returned by search_emails/list_emails)."
        case .script(let message):
            "Mail scripting failed: \(message)"
        case .notConfigured(let message):
            message
        case .backend(let message):
            message
        }
    }
}

/// The backend behind the mail tools. Mail.app is itself the provider abstraction —
/// it fronts whatever accounts (Fastmail, Gmail, iCloud…) the user has configured —
/// so `AppleMailProvider` is the only provider for now; the protocol is the seam a
/// direct Gmail/JMAP client would slot behind later.
protocol MailProvider: Sendable {
    func list(mailbox: String?, account: String?, limit: Int, unreadOnly: Bool) async throws -> [EmailDTO]
    func search(query: String, mailbox: String?, account: String?, limit: Int, unreadOnly: Bool) async throws -> [EmailDTO]
    func get(id: String) async throws -> EmailDTO
    func send(to: [String], cc: [String], bcc: [String], subject: String, body: String) async throws
    func createDraft(to: [String], cc: [String], bcc: [String], subject: String, body: String) async throws
    func markRead(id: String, read: Bool) async throws
    func mailboxes() async throws -> [MailboxDTO]
}

/// Mail access isolated to its own actor (matching `RemindersService`), forwarding to
/// the active provider. Kept separate from the provider so the tool surface never
/// sees which backend is live.
actor MailService {
    private let provider: MailProvider

    init(provider: MailProvider = AppleMailProvider()) {
        self.provider = provider
    }

    func list(mailbox: String?, account: String?, limit: Int, unreadOnly: Bool) async throws -> [EmailDTO] {
        try await provider.list(mailbox: mailbox, account: account, limit: limit, unreadOnly: unreadOnly)
    }
    func search(query: String, mailbox: String?, account: String?, limit: Int, unreadOnly: Bool) async throws -> [EmailDTO] {
        try await provider.search(query: query, mailbox: mailbox, account: account, limit: limit, unreadOnly: unreadOnly)
    }
    func get(id: String) async throws -> EmailDTO { try await provider.get(id: id) }
    func send(to: [String], cc: [String], bcc: [String], subject: String, body: String) async throws {
        try await provider.send(to: to, cc: cc, bcc: bcc, subject: subject, body: body)
    }
    func createDraft(to: [String], cc: [String], bcc: [String], subject: String, body: String) async throws {
        try await provider.createDraft(to: to, cc: cc, bcc: bcc, subject: subject, body: body)
    }
    func markRead(id: String, read: Bool) async throws { try await provider.markRead(id: id, read: read) }
    func mailboxes() async throws -> [MailboxDTO] { try await provider.mailboxes() }
}
