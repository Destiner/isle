//
//  ChatStore.swift
//  Isle
//

import Foundation
import SwiftData

/// One persisted turn (user or assistant) in a saved chat. A plain Codable value
/// stored inside `Chat.turns`; mirrors `CodexClient.Turn` but stays decoupled
/// from it so the persistence layer doesn't depend on the agent layer.
struct StoredTurn: Codable, Equatable {
    enum Role: String, Codable { case user, assistant }
    var role: Role
    var text: String
}

/// A saved conversation. The turns are Isle's own transcript (user + assistant
/// text) — `codex exec` is one-shot and carries no resumable session, so
/// reinstating a chat just means replaying this transcript back through Codex
/// (see `CodexClient.composePrompt`). There's nothing Codex-side to restore.
@Model
final class Chat {
    @Attribute(.unique) var id: UUID
    /// When the chat's first message was sent — the age shown in the switcher.
    var startedAt: Date
    /// Last time a turn was added — how the recent list is ordered.
    var updatedAt: Date
    var turns: [StoredTurn]

    init(id: UUID, startedAt: Date, updatedAt: Date, turns: [StoredTurn]) {
        self.id = id
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.turns = turns
    }
}

/// A lightweight, SwiftData-free projection of a saved chat for the switcher
/// list, so the UI layer never touches `@Model` types.
struct ChatSummary: Identifiable, Equatable {
    let id: UUID
    let firstUserMessage: String
    let startedAt: Date
}

/// The full transcript of a saved chat, returned when reinstating it.
struct ChatRecord {
    let id: UUID
    let startedAt: Date
    let turns: [StoredTurn]
}

/// Persists recent chats so the pill can switch between them (press ↑ in the
/// empty new-chat state). Backed by SwiftData but built imperatively — the app
/// has no real SwiftUI scene, so there's no `.modelContainer`/`@Query` to lean
/// on. Confined to the main actor: the data is tiny (a handful of short chats),
/// so a single main-context is plenty and keeps it simple.
///
/// Resilient by design — if the store can't be opened (or a query fails), every
/// method degrades to a no-op / empty result so the pill keeps working without
/// chat history rather than crashing.
@MainActor
final class ChatStore {
    private let container: ModelContainer?

    init() {
        do {
            // Keep the store alongside Isle's other data under Application Support.
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true)
                .appendingPathComponent("Isle", isDirectory: true)
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            let config = ModelConfiguration(url: support.appendingPathComponent("chats.store"))
            container = try ModelContainer(for: Chat.self, configurations: config)
        } catch {
            Log.error("chatstore.init", "\(error)")
            container = nil
        }
    }

    /// The most-recently-active chats, newest first (by `updatedAt`). Empty when
    /// the store is unavailable or nothing's saved yet.
    func recentSummaries(limit: Int) -> [ChatSummary] {
        guard let context = container?.mainContext else { return [] }
        var descriptor = FetchDescriptor<Chat>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        descriptor.fetchLimit = limit
        guard let chats = try? context.fetch(descriptor) else { return [] }
        return chats.map { chat in
            ChatSummary(
                id: chat.id,
                firstUserMessage: chat.turns.first(where: { $0.role == .user })?.text ?? "…",
                startedAt: chat.startedAt)
        }
    }

    /// The full transcript of a saved chat, for reinstating it.
    func record(id: UUID) -> ChatRecord? {
        guard let chat = fetch(id: id) else { return nil }
        return ChatRecord(id: chat.id, startedAt: chat.startedAt, turns: chat.turns)
    }

    /// Insert or update a chat's transcript, bumping `updatedAt`. Called after
    /// each answer lands, so the live chat is saved incrementally (crash-safe).
    func save(id: UUID, startedAt: Date, turns: [StoredTurn]) {
        guard let context = container?.mainContext else { return }
        if let chat = fetch(id: id) {
            chat.turns = turns
            chat.updatedAt = Date()
        } else {
            context.insert(Chat(id: id, startedAt: startedAt, updatedAt: Date(), turns: turns))
        }
        try? context.save()
    }

    /// Fetch a chat by id. Scans rather than using a `#Predicate` — the store
    /// holds only a handful of chats, so an in-memory find is trivial and dodges
    /// UUID-in-predicate edge cases.
    private func fetch(id: UUID) -> Chat? {
        guard let context = container?.mainContext else { return nil }
        return (try? context.fetch(FetchDescriptor<Chat>()))?.first { $0.id == id }
    }
}
