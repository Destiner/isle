//
//  MailTools.swift
//  Isle
//

import Foundation
import MCP

/// The MCP mail surface Isle exposes to Codex: the seven mail operations, their
/// JSON-Schema declarations (for `tools/list`), and the dispatch from a `tools/call`
/// to `MailService`. Mirrors `ReminderTools` — results come back as a single JSON
/// text block, errors as `isError` results with a readable message.
nonisolated struct MailTools: Sendable {
    let service: MailService

    /// Names this provider owns, so the shared server can route `tools/call` to it.
    static let toolNames: Set<String> = Set(tools.map(\.name))

    static let tools: [Tool] = [
        Tool(
            name: "search_emails",
            description: "Search recent emails whose subject or sender contains the given text. Returns headers only (call get_email for the body).",
            inputSchema: [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "Text to match in an email's subject or sender."],
                    "mailbox": ["type": "string", "description": "Optional mailbox: a special name (inbox, sent, drafts, trash, junk) or a name from list_mailboxes. Defaults to the inbox — you can omit it."],
                    "account": ["type": "string", "description": "Optional account name, to disambiguate a mailbox that exists in several accounts."],
                    "limit": ["type": "integer", "description": "Max results (default 20)."],
                    "unread_only": ["type": "boolean", "description": "Only unread emails (default false)."],
                ],
                "required": ["query"],
            ]),
        Tool(
            name: "list_emails",
            description: "List recent emails from a mailbox (the inbox by default). Returns headers only (call get_email for the body).",
            inputSchema: [
                "type": "object",
                "properties": [
                    "mailbox": ["type": "string", "description": "Optional mailbox: a special name (inbox, sent, drafts, trash, junk) or a name from list_mailboxes. Defaults to the inbox — you can omit it."],
                    "account": ["type": "string", "description": "Optional account name to scope the mailbox to."],
                    "limit": ["type": "integer", "description": "Max results (default 20)."],
                    "unread_only": ["type": "boolean", "description": "Only unread emails (default false)."],
                ],
            ]),
        Tool(
            name: "get_email",
            description: "Get a single email's full details, including the plain-text body, by its id.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "The email's id (as returned by search_emails/list_emails)."]
                ],
                "required": ["id"],
            ]),
        Tool(
            name: "send_email",
            description: "Compose and immediately send a new email. Sends right away — there is no confirmation step.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "to": ["type": "string", "description": "Recipient address(es), comma-separated."],
                    "cc": ["type": "string", "description": "Optional cc address(es), comma-separated."],
                    "bcc": ["type": "string", "description": "Optional bcc address(es), comma-separated."],
                    "subject": ["type": "string", "description": "The subject line."],
                    "body": ["type": "string", "description": "The message body (plain text)."],
                ],
                "required": ["to", "subject", "body"],
            ]),
        Tool(
            name: "create_draft",
            description: "Save a new email as a draft in Mail without sending it.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "to": ["type": "string", "description": "Recipient address(es), comma-separated."],
                    "cc": ["type": "string", "description": "Optional cc address(es), comma-separated."],
                    "bcc": ["type": "string", "description": "Optional bcc address(es), comma-separated."],
                    "subject": ["type": "string", "description": "The subject line."],
                    "body": ["type": "string", "description": "The message body (plain text)."],
                ],
                "required": ["to", "subject", "body"],
            ]),
        Tool(
            name: "mark_read",
            description: "Mark an email as read or unread by its id.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "The email's id."],
                    "read": ["type": "boolean", "description": "true to mark read, false to mark unread."],
                ],
                "required": ["id", "read"],
            ]),
        Tool(
            name: "list_mailboxes",
            description: "List all mailboxes across every account, each with its unread count.",
            inputSchema: ["type": "object", "properties": [:]]),
    ]

    /// Routes a `tools/call` to the matching service method and packages the result,
    /// logging every call (the choke point for Codex's mail use).
    func call(name: String, arguments: [String: Value]?) async -> CallTool.Result {
        let start = Date()
        let result = await dispatch(name: name, arguments: arguments)
        let chars = result.content.reduce(0) { acc, item in
            if case let .text(text, _, _) = item { return acc + text.count }
            return acc
        }
        Log.tool(name: name, arguments: Self.jsonObject(arguments),
                 isError: result.isError == true, resultChars: chars,
                 durationMs: Int(Date().timeIntervalSince(start) * 1000))
        return result
    }

    private static func jsonObject(_ arguments: [String: Value]?) -> Any {
        guard let arguments, !arguments.isEmpty,
              let data = try? JSONEncoder().encode(arguments),
              let object = try? JSONSerialization.jsonObject(with: data)
        else { return [String: Any]() }
        return object
    }

    private func dispatch(name: String, arguments: [String: Value]?) async -> CallTool.Result {
        do {
            switch name {
            case "search_emails":
                guard let query = arguments?["query"]?.stringValue else { return Self.error("Missing required argument: query") }
                let result = try await service.search(
                    query: query,
                    mailbox: arguments?["mailbox"]?.stringValue,
                    account: arguments?["account"]?.stringValue,
                    limit: arguments?["limit"]?.intValue ?? 20,
                    unreadOnly: arguments?["unread_only"]?.boolValue ?? false)
                return Self.json(result)

            case "list_emails":
                let result = try await service.list(
                    mailbox: arguments?["mailbox"]?.stringValue,
                    account: arguments?["account"]?.stringValue,
                    limit: arguments?["limit"]?.intValue ?? 20,
                    unreadOnly: arguments?["unread_only"]?.boolValue ?? false)
                return Self.json(result)

            case "get_email":
                guard let id = arguments?["id"]?.stringValue else { return Self.error("Missing required argument: id") }
                return Self.json(try await service.get(id: id))

            case "send_email":
                guard let to = arguments?["to"]?.stringValue,
                      let subject = arguments?["subject"]?.stringValue,
                      let body = arguments?["body"]?.stringValue else {
                    return Self.error("Missing required argument: to, subject, and body are required")
                }
                try await service.send(
                    to: Self.addresses(to),
                    cc: Self.addresses(arguments?["cc"]?.stringValue),
                    bcc: Self.addresses(arguments?["bcc"]?.stringValue),
                    subject: subject, body: body)
                return Self.text("Sent.")

            case "create_draft":
                guard let to = arguments?["to"]?.stringValue,
                      let subject = arguments?["subject"]?.stringValue,
                      let body = arguments?["body"]?.stringValue else {
                    return Self.error("Missing required argument: to, subject, and body are required")
                }
                try await service.createDraft(
                    to: Self.addresses(to),
                    cc: Self.addresses(arguments?["cc"]?.stringValue),
                    bcc: Self.addresses(arguments?["bcc"]?.stringValue),
                    subject: subject, body: body)
                return Self.text("Draft saved.")

            case "mark_read":
                guard let id = arguments?["id"]?.stringValue else { return Self.error("Missing required argument: id") }
                guard let read = arguments?["read"]?.boolValue else { return Self.error("Missing required argument: read") }
                try await service.markRead(id: id, read: read)
                return Self.text(read ? "Marked read." : "Marked unread.")

            case "list_mailboxes":
                return Self.json(try await service.mailboxes())

            default:
                return Self.error("Unknown tool: \(name)")
            }
        } catch {
            return Self.error((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    /// Splits a comma-separated address string into trimmed, non-empty addresses.
    private static func addresses(_ raw: String?) -> [String] {
        guard let raw else { return [] }
        return raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Result packaging

    private static func text(_ string: String, isError: Bool = false) -> CallTool.Result {
        .init(content: [.text(text: string, annotations: nil, _meta: nil)], isError: isError)
    }

    private static func error(_ message: String) -> CallTool.Result {
        text(message, isError: true)
    }

    private static func json<T: Encodable>(_ value: T) -> CallTool.Result {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value), let string = String(data: data, encoding: .utf8) else {
            return error("Failed to encode result.")
        }
        return text(string)
    }
}
