//
//  MailToolsTests.swift
//  IsleTests
//

import Foundation
import Testing
@testable import Isle

/// Covers the pure, Mail-free seams of `AppleMailProvider`: the AppleScript string
/// escaping and the delimited-row parsing (including the opaque id it encodes).
struct AppleMailProviderTests {
    private static let US = "\u{1F}"

    // MARK: - AppleScript literal escaping

    @Test func literalQuotesAndEscapes() {
        #expect(AppleMailProvider.literal("hi") == "\"hi\"")
        #expect(AppleMailProvider.literal("") == "\"\"")
    }

    @Test func literalEscapesQuotesAndBackslashes() {
        #expect(AppleMailProvider.literal("say \"hi\"") == "\"say \\\"hi\\\"\"")
        #expect(AppleMailProvider.literal("a\\b") == "\"a\\\\b\"")
    }

    @Test func literalSplitsNewlinesIntoLinefeedJoins() {
        // AppleScript string literals can't hold raw newlines — they become joins.
        #expect(AppleMailProvider.literal("a\nb") == "\"a\" & linefeed & \"b\"")
    }

    // MARK: - Mailbox resolution

    @Test func mailboxExprDefaultsToInboxKeyword() {
        // No mailbox, or "inbox" by name, must resolve to the aggregate keyword —
        // not a named lookup `mailbox "inbox"`, which throws "no such object".
        #expect(AppleMailProvider.mailboxExpr(mailbox: nil, account: nil) == "inbox")
        #expect(AppleMailProvider.mailboxExpr(mailbox: "inbox", account: nil) == "inbox")
        #expect(AppleMailProvider.mailboxExpr(mailbox: "Inbox", account: "") == "inbox")
    }

    @Test func mailboxExprMapsSpecialNamesToKeywords() {
        #expect(AppleMailProvider.mailboxExpr(mailbox: "sent", account: nil) == "sent mailbox")
        #expect(AppleMailProvider.mailboxExpr(mailbox: "Drafts", account: nil) == "drafts mailbox")
        #expect(AppleMailProvider.mailboxExpr(mailbox: "trash", account: nil) == "trash mailbox")
        #expect(AppleMailProvider.mailboxExpr(mailbox: "spam", account: nil) == "junk mailbox")
    }

    @Test func mailboxExprNamedAndAccountScoped() {
        #expect(AppleMailProvider.mailboxExpr(mailbox: "Receipts", account: nil) == "mailbox \"Receipts\"")
        #expect(AppleMailProvider.mailboxExpr(mailbox: "Receipts", account: "Fastmail")
            == "mailbox \"Receipts\" of account \"Fastmail\"")
        // "inbox" + account → the per-account IMAP inbox, not the aggregate keyword.
        #expect(AppleMailProvider.mailboxExpr(mailbox: "inbox", account: "Fastmail")
            == "mailbox \"INBOX\" of account \"Fastmail\"")
    }

    // MARK: - Row parsing

    @Test func parseRowBuildsDTOAndOpaqueID() throws {
        let row = ["42", "Hello", "Ann <a@b.com>", "2026-07-02T09:00:00",
                   "INBOX", "Fastmail", "false"].joined(separator: Self.US)
        let dto = try #require(AppleMailProvider.parseRow(row))
        #expect(dto.subject == "Hello")
        #expect(dto.sender == "Ann <a@b.com>")
        #expect(dto.mailbox == "INBOX")
        #expect(dto.account == "Fastmail")
        #expect(dto.unread == true)          // read status "false" → unread
        #expect(dto.body == nil)             // rows are headers-only

        // The id is opaque base64 of {account, mailbox, id} — decode and check.
        let data = try #require(Data(base64Encoded: dto.id))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["id"] as? Int == 42)
        #expect(json["mailbox"] as? String == "INBOX")
        #expect(json["account"] as? String == "Fastmail")
    }

    @Test func parseRowReadStatusTrueIsNotUnread() throws {
        let row = ["1", "S", "sender", "2026-07-02T09:00:00", "INBOX", "Acc", "true"]
            .joined(separator: Self.US)
        let dto = try #require(AppleMailProvider.parseRow(row))
        #expect(dto.unread == false)
    }

    @Test func parseRowRejectsMalformed() {
        #expect(AppleMailProvider.parseRow("too\u{1F}few\u{1F}fields") == nil)
        let nonNumericID = ["x", "S", "snd", "d", "mb", "acc", "false"]
            .joined(separator: Self.US)
        #expect(AppleMailProvider.parseRow(nonNumericID) == nil)
    }
}
