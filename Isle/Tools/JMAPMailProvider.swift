//
//  JMAPMailProvider.swift
//  Isle
//

import Foundation

/// A `MailProvider` backed by Fastmail's JMAP API instead of Mail.app + AppleScript.
///
/// JMAP is built to fix IMAP's chattiness: a "list 20 headers" is one HTTP request
/// (an `Email/query` chained to an `Email/get` via a back-reference), where the
/// AppleScript path did ~10 Apple Events *per message*. It also hands us stable
/// server-assigned email ids, mailbox `role`s (so the special-name mapping is a
/// lookup, not a keyword table), and real UTC dates — so most of the Apple-era
/// workarounds evaporate.
///
/// An `actor`: it caches the mailbox index and sending identity (both change
/// rarely) across calls without a data race. The token is resolved lazily so a
/// missing one surfaces as a readable `MailError.notConfigured` on first use rather
/// than a launch crash. All response parsing is `static` and pure (testable without
/// a live server, mirroring `AppleMailProvider.parseRow`).
actor JMAPMailProvider: MailProvider {
    /// Email properties fetched for the cheap list/search rows (headers only).
    nonisolated private static let headerProperties: [String] =
        ["id", "mailboxIds", "keywords", "from", "subject", "receivedAt"]
    /// Plus the recipients and body, fetched only by `get`.
    nonisolated private static let fullProperties: [String] =
        headerProperties + ["to", "cc", "bodyValues", "textBody"]

    /// Resolves the bearer token on first use, not at construction — so a launch
    /// never touches the Keychain (that read, and any prompt, is deferred to the
    /// first mail tool call, which runs off-main on this actor).
    private let tokenProvider: @Sendable () -> String?
    private var client: JMAPClient?
    private var cachedIndex: MailboxIndex?
    private var cachedIdentity: Identity?

    init(tokenProvider: @escaping @Sendable () -> String?) {
        self.tokenProvider = tokenProvider
    }

    /// Lazily builds the transport, or throws a readable error if no token is set.
    private func requireClient() throws -> JMAPClient {
        if let client { return client }
        guard let token = tokenProvider(), !token.isEmpty else {
            throw MailError.notConfigured(
                "No Fastmail API token configured. Store it in the Keychain (service \"\(Keychain.service)\", "
                + "account \"\(FastmailCredentials.keychainAccount)\") or set the ISLE_JMAP_TOKEN env var.")
        }
        let client = JMAPClient(token: token)
        self.client = client
        return client
    }

    private func session() async throws -> JMAPClient.Session {
        try await requireClient().session()
    }

    /// Runs one JMAP request (a list of `[name, args, callId]` method calls) and
    /// returns the raw `methodResponses` array.
    private func run(using capabilities: [String], _ methodCalls: [[Any]]) async throws -> [[Any]] {
        let client = try requireClient()
        let body: [String: Any] = ["using": capabilities, "methodCalls": methodCalls]
        let data = try await client.post(try JSONSerialization.data(withJSONObject: body))
        return try Self.methodResponses(from: data)
    }

    // MARK: - Reads

    func list(mailbox: String?, account: String?, limit: Int, unreadOnly: Bool) async throws -> [EmailDTO] {
        let session = try await session()
        let index = try await mailboxIndex()
        guard let mailboxId = Self.resolveMailboxId(mailbox, index: index) else { throw MailError.notFound }
        return try await queryAndGet(
            session: session, index: index,
            filter: Self.filter(inMailbox: mailboxId, text: nil, unreadOnly: unreadOnly),
            limit: limit)
    }

    func search(query: String, mailbox: String?, account: String?, limit: Int, unreadOnly: Bool) async throws -> [EmailDTO] {
        let session = try await session()
        let index = try await mailboxIndex()
        // Parity with the AppleScript path: scoped to the inbox by default, matching
        // subject OR sender (JMAP `text` would also search bodies).
        guard let mailboxId = Self.resolveMailboxId(mailbox, index: index) else { throw MailError.notFound }
        return try await queryAndGet(
            session: session, index: index,
            filter: Self.filter(inMailbox: mailboxId, text: query, unreadOnly: unreadOnly),
            limit: limit)
    }

    /// The shared `Email/query` → `Email/get` (headers) round-trip, one HTTP request
    /// via the `#ids` back-reference.
    @discardableResult
    private func queryAndGet(
        session: JMAPClient.Session, index: MailboxIndex, filter: [String: Any], limit: Int
    ) async throws -> [EmailDTO] {
        let calls: [[Any]] = [
            ["Email/query", [
                "accountId": session.accountId,
                "filter": filter,
                "sort": [["property": "receivedAt", "isAscending": false]],
                "limit": max(0, limit),
            ], "q"],
            ["Email/get", [
                "accountId": session.accountId,
                "#ids": ["resultOf": "q", "name": "Email/query", "path": "/ids"],
                "properties": Self.headerProperties,
            ], "g"],
        ]
        let responses = try await run(using: [JMAPClient.coreCapability, JMAPClient.mailCapability], calls)
        let result = try Self.result(responses, callId: "g")
        guard let emails = result["list"] as? [[String: Any]] else {
            throw MailError.backend("Malformed Email/get response.")
        }
        return emails.compactMap {
            Self.parseEmail($0, index: index, session: session, includeBody: false)
        }
    }

    func get(id: String) async throws -> EmailDTO {
        let ref = try Self.decodeID(id)
        let session = try await session()
        let index = try await mailboxIndex()
        let calls: [[Any]] = [
            ["Email/get", [
                "accountId": session.accountId,
                "ids": [ref.emailId],
                "properties": Self.fullProperties,
                "fetchTextBodyValues": true,
            ], "g"],
        ]
        let responses = try await run(using: [JMAPClient.coreCapability, JMAPClient.mailCapability], calls)
        let result = try Self.result(responses, callId: "g")
        guard let first = (result["list"] as? [[String: Any]])?.first,
              let dto = Self.parseEmail(first, index: index, session: session, includeBody: true) else {
            throw MailError.notFound
        }
        return dto
    }

    func mailboxes() async throws -> [MailboxDTO] {
        let session = try await session()
        let calls: [[Any]] = [
            ["Mailbox/get", [
                "accountId": session.accountId,
                "ids": NSNull(),
                "properties": ["id", "name", "role", "unreadEmails"],
            ], "m"],
        ]
        let responses = try await run(using: [JMAPClient.coreCapability, JMAPClient.mailCapability], calls)
        let result = try Self.result(responses, callId: "m")
        guard let list = result["list"] as? [[String: Any]] else {
            throw MailError.backend("Malformed Mailbox/get response.")
        }
        return list.compactMap { mb in
            guard let name = mb["name"] as? String else { return nil }
            let unread = (mb["unreadEmails"] as? NSNumber)?.intValue ?? 0
            return MailboxDTO(name: name, account: session.accountName, unreadCount: unread)
        }
    }

    // MARK: - Writes

    func markRead(id: String, read: Bool) async throws {
        let ref = try Self.decodeID(id)
        let session = try await session()
        // JMAP keyword patch: set `$seen` true to mark read, `null` to remove it.
        let patch: [String: Any] = read ? ["keywords/$seen": true] : ["keywords/$seen": NSNull()]
        let calls: [[Any]] = [
            ["Email/set", [
                "accountId": session.accountId,
                "update": [ref.emailId: patch],
            ], "s"],
        ]
        let responses = try await run(using: [JMAPClient.coreCapability, JMAPClient.mailCapability], calls)
        try Self.checkSetErrors(try Self.result(responses, callId: "s"), key: "notUpdated")
    }

    func createDraft(to: [String], cc: [String], bcc: [String], subject: String, body: String) async throws {
        let session = try await session()
        let index = try await mailboxIndex()
        guard let draftsId = index.roleToId["drafts"] else { throw MailError.backend("No Drafts mailbox found.") }
        let identity = try await identity()
        let email = Self.draftObject(
            to: to, cc: cc, bcc: bcc, subject: subject, body: body, draftsId: draftsId, from: identity)
        let calls: [[Any]] = [
            ["Email/set", ["accountId": session.accountId, "create": ["draft": email]], "c"],
        ]
        let responses = try await run(using: [JMAPClient.coreCapability, JMAPClient.mailCapability], calls)
        try Self.checkSetErrors(try Self.result(responses, callId: "c"), key: "notCreated")
    }

    func send(to: [String], cc: [String], bcc: [String], subject: String, body: String) async throws {
        let session = try await session()
        let index = try await mailboxIndex()
        guard let draftsId = index.roleToId["drafts"] else { throw MailError.backend("No Drafts mailbox found.") }
        let sentId = index.roleToId["sent"]
        let identity = try await identity()

        // Create the message as a draft, then submit it. On success, move it out of
        // Drafts into Sent and clear `$draft` (chained in one request via the `#draft`
        // creation reference and `onSuccessUpdateEmail`).
        let email = Self.draftObject(
            to: to, cc: cc, bcc: bcc, subject: subject, body: body, draftsId: draftsId, from: identity)
        let envelope: [String: Any] = [
            "mailFrom": ["email": identity.email],
            "rcptTo": (to + cc + bcc).map { ["email": $0] },
        ]
        var onSuccess: [String: Any] = ["keywords/$draft": NSNull()]
        if let sentId {
            onSuccess["mailboxIds/\(sentId)"] = true
            onSuccess["mailboxIds/\(draftsId)"] = NSNull()
        }
        let calls: [[Any]] = [
            ["Email/set", ["accountId": session.accountId, "create": ["draft": email]], "e"],
            ["EmailSubmission/set", [
                "accountId": session.accountId,
                "create": ["sub": [
                    "emailId": "#draft",
                    "identityId": identity.id,
                    "envelope": envelope,
                ]],
                "onSuccessUpdateEmail": ["#sub": onSuccess],
            ], "s"],
        ]
        let responses = try await run(
            using: [JMAPClient.coreCapability, JMAPClient.mailCapability, JMAPClient.submissionCapability], calls)
        try Self.checkSetErrors(try Self.result(responses, callId: "e"), key: "notCreated")
        try Self.checkSetErrors(try Self.result(responses, callId: "s"), key: "notCreated")
    }

    // MARK: - Cached lookups (mailboxes, sending identity)

    /// Mailbox id ⇄ name and role → id maps, fetched once. Mailboxes change rarely,
    /// so caching per provider instance avoids a `Mailbox/get` on every list/search.
    private func mailboxIndex() async throws -> MailboxIndex {
        if let cachedIndex { return cachedIndex }
        let session = try await session()
        let calls: [[Any]] = [
            ["Mailbox/get", [
                "accountId": session.accountId,
                "ids": NSNull(),
                "properties": ["id", "name", "role"],
            ], "m"],
        ]
        let responses = try await run(using: [JMAPClient.coreCapability, JMAPClient.mailCapability], calls)
        let result = try Self.result(responses, callId: "m")
        guard let list = result["list"] as? [[String: Any]] else {
            throw MailError.backend("Malformed Mailbox/get response.")
        }
        let index = MailboxIndex(list)
        cachedIndex = index
        return index
    }

    /// The account's sending identity (`identityId` + from address), fetched once.
    private func identity() async throws -> Identity {
        if let cachedIdentity { return cachedIdentity }
        let session = try await session()
        let calls: [[Any]] = [
            ["Identity/get", ["accountId": session.accountId], "i"],
        ]
        let responses = try await run(
            using: [JMAPClient.coreCapability, JMAPClient.submissionCapability], calls)
        let result = try Self.result(responses, callId: "i")
        guard let list = result["list"] as? [[String: Any]], !list.isEmpty else {
            throw MailError.backend("No sending identity found for this account.")
        }
        // Prefer the identity whose address matches the account; else the first.
        let chosen = list.first { ($0["email"] as? String)?.lowercased() == session.accountName.lowercased() }
            ?? list[0]
        let identity = Identity(
            id: chosen["id"] as? String ?? "",
            email: chosen["email"] as? String ?? session.accountName,
            name: chosen["name"] as? String ?? "")
        cachedIdentity = identity
        return identity
    }

    // MARK: - Request building (pure)

    /// An `Email/query` filter: an `inMailbox` scope, optional subject-OR-sender text
    /// match, optional unread-only — AND-composed only when more than one applies.
    nonisolated static func filter(inMailbox mailboxId: String, text: String?, unreadOnly: Bool) -> [String: Any] {
        var conditions: [[String: Any]] = [["inMailbox": mailboxId]]
        if let text, !text.isEmpty {
            conditions.append(["operator": "OR", "conditions": [["subject": text], ["from": text]]])
        }
        if unreadOnly { conditions.append(["notKeyword": "$seen"]) }
        return conditions.count == 1 ? conditions[0] : ["operator": "AND", "conditions": conditions]
    }

    /// A JMAP `Email` create object (a draft in `draftsId`, keyword `$draft`). Shared
    /// by `createDraft` and `send` — the latter clears `$draft` on submission.
    nonisolated static func draftObject(
        to: [String], cc: [String], bcc: [String], subject: String, body: String,
        draftsId: String, from: Identity
    ) -> [String: Any] {
        var object: [String: Any] = [
            "mailboxIds": [draftsId: true],
            "keywords": ["$draft": true, "$seen": true],
            "from": from.name.isEmpty ? [["email": from.email]] : [["name": from.name, "email": from.email]],
            "subject": subject,
            "bodyValues": ["body": ["value": body]],
            "textBody": [["partId": "body", "type": "text/plain"]],
        ]
        if !to.isEmpty { object["to"] = to.map { ["email": $0] } }
        if !cc.isEmpty { object["cc"] = cc.map { ["email": $0] } }
        if !bcc.isEmpty { object["bcc"] = bcc.map { ["email": $0] } }
        return object
    }

    // MARK: - Response parsing (pure)

    /// The `methodResponses` array from a JMAP reply, or a `backend` error.
    nonisolated static func methodResponses(from data: Data) throws -> [[Any]] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let responses = json["methodResponses"] as? [[Any]] else {
            throw MailError.backend("Malformed JMAP response.")
        }
        return responses
    }

    /// The result object for a given `callId`, mapping a method-level `error` (or a
    /// missing response) to a readable `MailError`.
    nonisolated static func result(_ responses: [[Any]], callId: String) throws -> [String: Any] {
        for entry in responses where entry.count >= 3 {
            guard let id = entry[2] as? String, id == callId else { continue }
            guard let object = entry[1] as? [String: Any] else {
                throw MailError.backend("Malformed JMAP method response.")
            }
            if (entry[0] as? String) == "error" {
                let type = object["type"] as? String ?? "unknown"
                let description = object["description"] as? String ?? ""
                throw MailError.backend("JMAP error: \(type) \(description)".trimmingCharacters(in: .whitespaces))
            }
            return object
        }
        throw MailError.backend("No JMAP response for call \(callId).")
    }

    /// Surfaces per-item failures from an `Email/set` / `EmailSubmission/set`
    /// (`notCreated` / `notUpdated`, keyed by the item id).
    nonisolated static func checkSetErrors(_ result: [String: Any], key: String) throws {
        guard let failures = result[key] as? [String: Any], !failures.isEmpty else { return }
        if let error = failures.values.first as? [String: Any] {
            let type = error["type"] as? String ?? "unknown"
            let description = error["description"] as? String ?? ""
            throw MailError.backend("JMAP \(key): \(type) \(description)".trimmingCharacters(in: .whitespaces))
        }
        throw MailError.backend("JMAP \(key).")
    }

    /// Maps a JMAP `Email` object to an `EmailDTO`. Rows are headers-only; `get`
    /// passes `includeBody` to also fill `to`/`cc`/`body`.
    nonisolated static func parseEmail(
        _ email: [String: Any], index: MailboxIndex, session: JMAPClient.Session, includeBody: Bool
    ) -> EmailDTO? {
        guard let emailId = email["id"] as? String else { return nil }
        let keywords = email["keywords"] as? [String: Any] ?? [:]
        var to: String?, cc: String?, body: String?
        if includeBody {
            to = nilIfEmpty(formatAddresses(email["to"]))
            cc = nilIfEmpty(formatAddresses(email["cc"]))
            body = extractTextBody(email)
        }
        return EmailDTO(
            id: encodeID(JMAPRef(accountId: session.accountId, emailId: emailId)),
            subject: email["subject"] as? String ?? "",
            sender: formatAddresses(email["from"]),
            to: to, cc: cc,
            date: email["receivedAt"] as? String ?? "",
            mailbox: mailboxName(from: email["mailboxIds"], index: index),
            account: session.accountName,
            // `$seen` present-and-true means read; anything else is unread.
            unread: (keywords["$seen"] as? Bool) != true,
            body: body)
    }

    /// A JMAP `[{name, email}]` list rendered as `Name <email>` (or bare `email`),
    /// comma-joined — matching the AppleScript sender/recipient shape.
    nonisolated static func formatAddresses(_ value: Any?) -> String {
        guard let addresses = value as? [[String: Any]] else { return "" }
        return addresses.map { address in
            let email = address["email"] as? String ?? ""
            if let name = address["name"] as? String, !name.isEmpty { return "\(name) <\(email)>" }
            return email
        }.joined(separator: ", ")
    }

    /// The display name of the mailbox an email lives in — preferring the inbox when
    /// a message is filed in several mailboxes, else any.
    nonisolated static func mailboxName(from value: Any?, index: MailboxIndex) -> String {
        guard let ids = (value as? [String: Any])?.keys, !ids.isEmpty else { return "" }
        if let inboxId = index.roleToId["inbox"], ids.contains(inboxId) {
            return index.idToName[inboxId] ?? ""
        }
        guard let first = ids.first else { return "" }
        return index.idToName[first] ?? ""
    }

    /// Concatenates the plain-text body parts, resolving each `textBody` part's
    /// `partId` against the fetched `bodyValues`.
    nonisolated static func extractTextBody(_ email: [String: Any]) -> String {
        guard let bodyValues = email["bodyValues"] as? [String: Any] else { return "" }
        let parts = email["textBody"] as? [[String: Any]] ?? []
        let pieces = parts.compactMap { part -> String? in
            guard let partId = part["partId"] as? String,
                  let value = (bodyValues[partId] as? [String: Any])?["value"] as? String else { return nil }
            return value
        }
        return pieces.joined(separator: "\n")
    }

    /// Maps the tool's mailbox argument to a mailbox id: the special names resolve by
    /// `role`, everything else by (case-insensitive) name; `nil`/empty → the inbox.
    nonisolated static func resolveMailboxId(_ name: String?, index: MailboxIndex) -> String? {
        guard let name, !name.isEmpty else { return index.roleToId["inbox"] }
        switch name.lowercased() {
        case "inbox": return index.roleToId["inbox"]
        case "sent", "sent messages", "sent mail": return index.roleToId["sent"]
        case "drafts": return index.roleToId["drafts"]
        case "trash", "bin", "deleted", "deleted messages": return index.roleToId["trash"]
        case "junk", "spam": return index.roleToId["junk"]
        case "archive", "all mail": return index.roleToId["archive"]
        default: return index.nameToId[name.lowercased()]
        }
    }

    private nonisolated static func nilIfEmpty(_ string: String) -> String? { string.isEmpty ? nil : string }

    // MARK: - Opaque id codec

    private nonisolated static func encodeID(_ ref: JMAPRef) -> String {
        (try? JSONEncoder().encode(ref))?.base64EncodedString() ?? ""
    }

    nonisolated static func decodeID(_ id: String) throws -> JMAPRef {
        guard let data = Data(base64Encoded: id),
              let ref = try? JSONDecoder().decode(JMAPRef.self, from: data) else {
            throw MailError.badID(id)
        }
        return ref
    }
}

/// The concrete JMAP coordinates behind an opaque `EmailDTO.id`. JMAP email ids are
/// stable and account-scoped, so `{accountId, emailId}` is enough — the account is
/// kept so the opaque handle stays valid once Isle grows past a single account.
nonisolated struct JMAPRef: Codable, Sendable {
    let accountId: String
    let emailId: String
}

/// The account's sending identity, cached by `JMAPMailProvider`.
nonisolated struct Identity: Sendable {
    let id: String
    let email: String
    let name: String
}

/// Mailbox lookups derived from one `Mailbox/get`: id → name, role → id, and
/// lowercased-name → id.
nonisolated struct MailboxIndex: Sendable {
    let idToName: [String: String]
    let roleToId: [String: String]
    let nameToId: [String: String]

    init(_ list: [[String: Any]]) {
        var idToName: [String: String] = [:]
        var roleToId: [String: String] = [:]
        var nameToId: [String: String] = [:]
        for mailbox in list {
            guard let id = mailbox["id"] as? String else { continue }
            let name = mailbox["name"] as? String ?? ""
            idToName[id] = name
            nameToId[name.lowercased()] = id
            if let role = mailbox["role"] as? String { roleToId[role] = id }
        }
        self.idToName = idToName
        self.roleToId = roleToId
        self.nameToId = nameToId
    }
}
