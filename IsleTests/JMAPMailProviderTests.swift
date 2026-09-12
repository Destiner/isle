//
//  JMAPMailProviderTests.swift
//  IsleTests
//

import Foundation
import MCP
import Roboport
import Testing
@testable import Isle

/// Covers the pure, server-free seams of `JMAPMailProvider`: email parsing, address
/// formatting, mailbox resolution, filter building, and the opaque id codec.
@MainActor
struct JMAPMailProviderTests {
    @Test func readOnlySurfaceDoesNotExposeWrites() {
        let surface = MailTools(
            service: MailService(
                provider: JMAPMailProvider(tokenProvider: { nil })
            ),
            allowedToolNames: MailTools.readOnlyToolNames
        )
        let names = Set(surface.agentTools(allowing: MailTools.readOnlyToolNames).map(\.name))

        #expect(names == ["search_emails", "list_emails", "get_email", "list_mailboxes"])
        #expect(names.isDisjoint(with: ["send_email", "create_draft", "mark_read"]))
    }

    @Test func readOnlySurfaceRejectsWriteDispatch() async {
        let surface = MailTools(
            service: MailService(
                provider: JMAPMailProvider(tokenProvider: { nil })
            ),
            allowedToolNames: MailTools.readOnlyToolNames
        )

        let result = await surface.call(name: "send_email", arguments: nil)
        #expect(result.isError == true)
    }

    private static let session = JMAPClient.Session(
        apiURL: URL(string: "https://api.fastmail.com/jmap/api/")!,
        accountId: "u123",
        accountName: "me@fastmail.com")

    private static let index = MailboxIndex([
        ["id": "mb-inbox", "name": "Inbox", "role": "inbox"],
        ["id": "mb-sent", "name": "Sent", "role": "sent"],
        ["id": "mb-drafts", "name": "Drafts", "role": "drafts"],
        ["id": "mb-junk", "name": "Junk", "role": "junk"],
        ["id": "mb-receipts", "name": "Receipts"],
    ])

    // MARK: - Email parsing

    @Test func parseEmailHeaderRow() throws {
        let email: [String: Any] = [
            "id": "M42",
            "subject": "Hello",
            "from": [["name": "Ann", "email": "a@b.com"]],
            "receivedAt": "2026-07-02T09:00:00Z",
            "mailboxIds": ["mb-inbox": true],
            "keywords": [:],  // no $seen → unread
        ]
        let dto = try #require(JMAPMailProvider.parseEmail(
            email, index: Self.index, session: Self.session, includeBody: false))
        #expect(dto.subject == "Hello")
        #expect(dto.sender == "Ann <a@b.com>")
        #expect(dto.date == "2026-07-02T09:00:00Z")
        #expect(dto.mailbox == "Inbox")
        #expect(dto.account == "me@fastmail.com")
        #expect(dto.unread == true)
        #expect(dto.to == nil)     // headers-only
        #expect(dto.body == nil)

        // The id is opaque base64 of {accountId, emailId}.
        let ref = try JMAPMailProvider.decodeID(dto.id)
        #expect(ref.accountId == "u123")
        #expect(ref.emailId == "M42")
    }

    @Test func parseEmailSeenIsRead() throws {
        let email: [String: Any] = [
            "id": "M1", "subject": "S", "from": [["email": "x@y.com"]],
            "receivedAt": "2026-07-02T09:00:00Z", "mailboxIds": ["mb-inbox": true],
            "keywords": ["$seen": true],
        ]
        let dto = try #require(JMAPMailProvider.parseEmail(
            email, index: Self.index, session: Self.session, includeBody: false))
        #expect(dto.unread == false)
        #expect(dto.sender == "x@y.com")  // no name → bare address
    }

    @Test func parseEmailWithBody() throws {
        let email: [String: Any] = [
            "id": "M7", "subject": "Body", "from": [["email": "a@b.com"]],
            "receivedAt": "2026-07-02T09:00:00Z", "mailboxIds": ["mb-receipts": true],
            "keywords": ["$seen": true],
            "to": [["name": "Bo", "email": "bo@x.com"], ["email": "cc0@x.com"]],
            "cc": [["email": "carol@x.com"]],
            "textBody": [["partId": "p1"], ["partId": "p2"]],
            "bodyValues": ["p1": ["value": "line one"], "p2": ["value": "line two"]],
        ]
        let dto = try #require(JMAPMailProvider.parseEmail(
            email, index: Self.index, session: Self.session, includeBody: true))
        #expect(dto.to == "Bo <bo@x.com>, cc0@x.com")
        #expect(dto.cc == "carol@x.com")
        #expect(dto.body == "line one\nline two")
        #expect(dto.mailbox == "Receipts")
    }

    @Test func parseEmailRejectsMissingID() {
        #expect(JMAPMailProvider.parseEmail(
            ["subject": "no id"], index: Self.index, session: Self.session, includeBody: false) == nil)
    }

    @Test func mailboxNamePrefersInboxWhenFiledInMany() {
        // A message in both Inbox and Receipts reports as Inbox.
        let name = JMAPMailProvider.mailboxName(
            from: ["mb-receipts": true, "mb-inbox": true], index: Self.index)
        #expect(name == "Inbox")
    }

    // MARK: - Mailbox resolution

    @Test func resolveMailboxIdDefaultsToInbox() {
        #expect(JMAPMailProvider.resolveMailboxId(nil, index: Self.index) == "mb-inbox")
        #expect(JMAPMailProvider.resolveMailboxId("", index: Self.index) == "mb-inbox")
        #expect(JMAPMailProvider.resolveMailboxId("Inbox", index: Self.index) == "mb-inbox")
    }

    @Test func resolveMailboxIdMapsSpecialNamesToRoles() {
        #expect(JMAPMailProvider.resolveMailboxId("sent", index: Self.index) == "mb-sent")
        #expect(JMAPMailProvider.resolveMailboxId("Drafts", index: Self.index) == "mb-drafts")
        #expect(JMAPMailProvider.resolveMailboxId("spam", index: Self.index) == "mb-junk")
    }

    @Test func resolveMailboxIdByName() {
        #expect(JMAPMailProvider.resolveMailboxId("Receipts", index: Self.index) == "mb-receipts")
        #expect(JMAPMailProvider.resolveMailboxId("nope", index: Self.index) == nil)
    }

    // MARK: - Filter building

    @Test func filterInMailboxOnly() {
        let filter = JMAPMailProvider.filter(inMailbox: "mb-inbox", text: nil, unreadOnly: false)
        #expect(filter["inMailbox"] as? String == "mb-inbox")
        #expect(filter["operator"] == nil)  // single condition, not wrapped
    }

    @Test func filterComposesTextAndUnread() {
        let filter = JMAPMailProvider.filter(inMailbox: "mb-inbox", text: "invoice", unreadOnly: true)
        #expect(filter["operator"] as? String == "AND")
        let conditions = try? #require(filter["conditions"] as? [[String: Any]])
        #expect(conditions?.count == 3)
        // The text clause is an OR over subject/from.
        let textClause = conditions?.first { $0["operator"] as? String == "OR" }
        #expect(textClause != nil)
        // Unread maps to notKeyword $seen.
        let unreadClause = conditions?.first { ($0["notKeyword"] as? String) == "$seen" }
        #expect(unreadClause != nil)
    }

    // MARK: - Draft object

    @Test func draftObjectShape() {
        let identity = Identity(id: "id1", email: "me@fastmail.com", name: "Me")
        let object = JMAPMailProvider.draftObject(
            to: ["a@x.com", "b@x.com"], cc: [], bcc: [], subject: "Hi", body: "Yo",
            draftsId: "mb-drafts", from: identity)
        #expect((object["mailboxIds"] as? [String: Bool])?["mb-drafts"] == true)
        #expect((object["keywords"] as? [String: Bool])?["$draft"] == true)
        #expect((object["to"] as? [[String: String]])?.count == 2)
        #expect(object["cc"] == nil)  // empty recipients omitted
        #expect((object["from"] as? [[String: String]])?.first?["name"] == "Me")
    }

    // MARK: - Response parsing / errors

    @Test func resultSurfacesMethodError() throws {
        let responses: [[Any]] = [["error", ["type": "invalidArguments", "description": "bad"], "q"]]
        #expect(throws: MailError.self) {
            _ = try JMAPMailProvider.result(responses, callId: "q")
        }
    }

    @Test func resultReturnsMatchingCall() throws {
        let responses: [[Any]] = [
            ["Email/query", ["ids": ["M1"]], "q"],
            ["Email/get", ["list": [["id": "M1"]]], "g"],
        ]
        let get = try JMAPMailProvider.result(responses, callId: "g")
        #expect((get["list"] as? [[String: Any]])?.count == 1)
    }

    @Test func checkSetErrorsThrowsOnNotCreated() {
        let result: [String: Any] = ["notCreated": ["draft": ["type": "tooLarge"]]]
        #expect(throws: MailError.self) {
            try JMAPMailProvider.checkSetErrors(result, key: "notCreated")
        }
    }

    @Test func checkSetErrorsPassesWhenEmpty() throws {
        try JMAPMailProvider.checkSetErrors(["created": ["draft": ["id": "M9"]]], key: "notCreated")
    }
}
