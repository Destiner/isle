//
//  RemindersService.swift
//  Isle
//

import EventKit
import Foundation

/// A reminder flattened to a JSON-friendly value. `EKReminder` isn't `Sendable`,
/// so every reminder that leaves the service is converted to this first — the DTO
/// is what crosses the actor boundary and gets encoded into a tool result.
struct ReminderDTO: Codable, Sendable {
    let id: String
    let title: String
    let notes: String?
    let list: String
    let completed: Bool
    /// ISO 8601 (`yyyy-MM-dd'T'HH:mm:ssZ`), or `nil` when the reminder has no due date.
    let dueDate: String?
    /// EventKit priority: `0` none, `1`–`4` high, `5` medium, `6`–`9` low.
    let priority: Int
}

/// A reminder operation that failed, mapped to a message the model can read back.
enum RemindersError: LocalizedError {
    case accessDenied
    case notFound(String)
    case listNotFound(String)
    case badDate(String)

    var errorDescription: String? {
        switch self {
        case .accessDenied:            "Reminders access hasn't been granted to Isle."
        case .notFound(let id):        "No reminder found with id \(id)."
        case .listNotFound(let name):  "No reminder list named \"\(name)\"."
        case .badDate(let s):          "Couldn't parse \"\(s)\" as a date (use ISO 8601, e.g. 2026-07-05T09:00:00Z)."
        }
    }
}

/// EventKit-backed reminders access, isolated to its own actor so it stays off the
/// main thread and its non-`Sendable` `EKEventStore` is never shared. Every method
/// requests access first (idempotent after the first grant) and returns `ReminderDTO`s.
actor RemindersService {
    private let store = EKEventStore()

    /// Prompts for (or confirms) full reminders access. Throws `.accessDenied` if the
    /// user hasn't granted it. Cheap to call repeatedly once granted.
    func ensureAccess() async throws {
        let granted = try await store.requestFullAccessToReminders()
        guard granted else { throw RemindersError.accessDenied }
    }

    /// Reminders in a list (or across all lists), optionally including completed ones.
    func list(listName: String?, includeCompleted: Bool) async throws -> [ReminderDTO] {
        try await ensureAccess()
        let calendars = try calendars(forListNamed: listName)
        let predicate = includeCompleted
            ? store.predicateForReminders(in: calendars)
            : store.predicateForIncompleteReminders(
                withDueDateStarting: nil, ending: nil, calendars: calendars)
        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: (reminders ?? []).map(Self.dto(from:)))
            }
        }
    }

    /// Reminders whose title or notes contain `query` (case-insensitive).
    func search(query: String, listName: String?, includeCompleted: Bool) async throws -> [ReminderDTO] {
        let all = try await list(listName: listName, includeCompleted: includeCompleted)
        let needle = query.lowercased()
        return all.filter {
            $0.title.lowercased().contains(needle)
                || ($0.notes?.lowercased().contains(needle) ?? false)
        }
    }

    /// A single reminder by its `calendarItemIdentifier`.
    func get(id: String) async throws -> ReminderDTO {
        try await ensureAccess()
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
            throw RemindersError.notFound(id)
        }
        return Self.dto(from: reminder)
    }

    /// Creates a reminder in the named list (or the default list) and returns it.
    func create(
        title: String, notes: String?, dueDate: String?, listName: String?, priority: Int?
    ) async throws -> ReminderDTO {
        try await ensureAccess()
        guard let calendar = try calendars(forListNamed: listName)?.first
            ?? store.defaultCalendarForNewReminders() else {
            throw RemindersError.listNotFound(listName ?? "default")
        }
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = calendar
        reminder.title = title
        reminder.notes = notes
        if let priority { reminder.priority = priority }
        if let dueDate { reminder.dueDateComponents = try Self.components(from: dueDate) }
        try store.save(reminder, commit: true)
        return Self.dto(from: reminder)
    }

    /// Edits an existing reminder; only non-`nil` fields are changed. Returns the updated reminder.
    func edit(
        id: String, title: String?, notes: String?, dueDate: String?,
        completed: Bool?, priority: Int?
    ) async throws -> ReminderDTO {
        try await ensureAccess()
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
            throw RemindersError.notFound(id)
        }
        if let title { reminder.title = title }
        if let notes { reminder.notes = notes }
        if let priority { reminder.priority = priority }
        if let completed { reminder.isCompleted = completed }
        if let dueDate { reminder.dueDateComponents = try Self.components(from: dueDate) }
        try store.save(reminder, commit: true)
        return Self.dto(from: reminder)
    }

    /// Resolves a list name to a `[EKCalendar]` filter for the fetch predicates:
    /// `nil` name → `nil` (all reminder lists); a name → the single matching list,
    /// or `.listNotFound`.
    private func calendars(forListNamed name: String?) throws -> [EKCalendar]? {
        guard let name, !name.isEmpty else { return nil }
        guard let match = store.calendars(for: .reminder)
            .first(where: { $0.title.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw RemindersError.listNotFound(name)
        }
        return [match]
    }

    // MARK: - Conversion (nonisolated: pure, no actor state)

    nonisolated private static func dto(from reminder: EKReminder) -> ReminderDTO {
        var due: String?
        if let components = reminder.dueDateComponents,
            let date = Calendar.current.date(from: components) {
            let formatter = ISO8601DateFormatter()
            due = formatter.string(from: date)
        }
        return ReminderDTO(
            id: reminder.calendarItemIdentifier,
            title: reminder.title ?? "",
            notes: reminder.notes,
            list: reminder.calendar?.title ?? "",
            completed: reminder.isCompleted,
            dueDate: due,
            priority: reminder.priority
        )
    }

    nonisolated private static func components(from string: String) throws -> DateComponents {
        let date = try parseDate(string)
        return Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date)
    }

    /// Accepts full ISO 8601 (with or without fractional seconds / timezone) and a few
    /// common looser forms; local time is assumed when no timezone is given.
    nonisolated private static func parseDate(_ string: String) throws -> Date {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: string) { return date }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: string) { return date }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: string) { return date }
        }
        throw RemindersError.badDate(string)
    }
}
