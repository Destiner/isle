//
//  CalendarService.swift
//  Isle
//

import EventKit
import Foundation

nonisolated struct CalendarDTO: Codable, Sendable {
    let id: String
    let name: String
    let color: String?
    let writable: Bool
}

nonisolated struct CalendarEventDTO: Codable, Sendable {
    let id: String
    let calendarID: String
    let calendar: String
    let title: String
    let startDate: String
    let endDate: String
    let allDay: Bool
    let location: String?
    let notes: String?
    let url: String?
    let alertMinutesBefore: Int?
    let recurrence: CalendarRecurrenceDTO?
}

nonisolated struct CalendarRecurrenceDTO: Codable, Sendable {
    let frequency: String
    let interval: Int
    let endDate: String?
}

nonisolated struct CalendarRecurrenceInput: Codable, Sendable {
    let frequency: String
    let interval: Int?
    let endDate: String?

    enum CodingKeys: String, CodingKey {
        case frequency
        case interval
        case endDate = "end_date"
    }
}

nonisolated enum CalendarError: LocalizedError {
    case accessDenied
    case notFound(String)
    case calendarNotFound(String)
    case calendarAmbiguous(String)
    case calendarNotWritable(String)
    case badDate(String)
    case invalidRange
    case invalidLimit(Int)
    case invalidRecurrence(String)
    case invalidURL(String)

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            "Calendar access hasn't been granted to Isle."
        case .notFound(let id):
            "No calendar event found with id \(id)."
        case .calendarNotFound(let calendar):
            "No calendar found named or identified by \"\(calendar)\"."
        case .calendarAmbiguous(let calendar):
            "More than one calendar is named \"\(calendar)\"; use its id from list_calendars."
        case .calendarNotWritable(let calendar):
            "The calendar \"\(calendar)\" can't be changed."
        case .badDate(let value):
            "Couldn't parse \"\(value)\" as a date (use ISO 8601, e.g. 2026-07-05T09:00:00Z)."
        case .invalidRange:
            "end_date must be after start_date."
        case .invalidLimit(let limit):
            "limit must be between 1 and 200 (got \(limit))."
        case .invalidRecurrence(let frequency):
            "Unsupported recurrence frequency \"\(frequency)\"; use daily, weekly, monthly, or yearly."
        case .invalidURL(let value):
            "\"\(value)\" isn't a valid URL."
        }
    }
}

/// EventKit-backed calendar access. EventKit objects are kept inside this actor;
/// callers only receive Sendable DTOs suitable for MCP JSON responses.
actor CalendarService {
    private let store = EKEventStore()

    func ensureAccess() async throws {
        let granted = try await store.requestFullAccessToEvents()
        guard granted else { throw CalendarError.accessDenied }
    }

    func calendars() async throws -> [CalendarDTO] {
        try await ensureAccess()
        return store.calendars(for: .event)
            .map(Self.calendarDTO(from:))
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func list(
        startDate: String?, endDate: String?, calendar: String?, query: String?, limit: Int
    ) async throws -> [CalendarEventDTO] {
        guard (1...200).contains(limit) else { throw CalendarError.invalidLimit(limit) }
        try await ensureAccess()
        let start = try startDate.map(Self.parseDate) ?? Date()
        let end = try endDate.map(Self.parseDate) ?? Calendar.current.date(byAdding: .day, value: 7, to: start)!
        guard end > start else { throw CalendarError.invalidRange }
        let calendars = try resolveCalendars(calendar)
        let events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: calendars))
        let needle = query?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return events
            .filter { event in
                guard let needle, !needle.isEmpty else { return true }
                return [event.title, event.location, event.notes]
                    .compactMap { $0?.lowercased() }
                    .contains { $0.contains(needle) }
            }
            .sorted { $0.startDate < $1.startDate }
            .prefix(limit)
            .map(Self.dto(from:))
    }

    func get(id: String) async throws -> CalendarEventDTO {
        try await ensureAccess()
        guard let event = store.event(withIdentifier: id) else { throw CalendarError.notFound(id) }
        return Self.dto(from: event)
    }

    func create(
        title: String, startDate: String, endDate: String, calendar: String?, location: String?,
        notes: String?, url: String?, allDay: Bool, alertMinutesBefore: Int?, recurrence: CalendarRecurrenceInput?
    ) async throws -> CalendarEventDTO {
        try await ensureAccess()
        let start = try Self.parseDate(startDate)
        let end = try Self.parseDate(endDate)
        guard end > start else { throw CalendarError.invalidRange }
        let target = try writableCalendar(named: calendar)

        let event = EKEvent(eventStore: store)
        event.calendar = target
        event.title = title
        event.startDate = start
        event.endDate = end
        event.location = location
        event.notes = notes
        event.isAllDay = allDay
        if let url { event.url = try Self.url(from: url) }
        if let alertMinutesBefore { event.addAlarm(EKAlarm(relativeOffset: TimeInterval(-alertMinutesBefore * 60))) }
        if let recurrence { event.addRecurrenceRule(try Self.recurrenceRule(from: recurrence)) }
        try store.save(event, span: .thisEvent, commit: true)
        return Self.dto(from: event)
    }

    func edit(
        id: String, title: String?, startDate: String?, endDate: String?, calendar: String?, location: String?,
        notes: String?, url: String?, allDay: Bool?, alertMinutesBefore: Int?, recurrence: CalendarRecurrenceInput?,
        clearRecurrence: Bool, span: EKSpan
    ) async throws -> CalendarEventDTO {
        try await ensureAccess()
        guard let event = store.event(withIdentifier: id) else { throw CalendarError.notFound(id) }
        if let title { event.title = title }
        if let startDate { event.startDate = try Self.parseDate(startDate) }
        if let endDate { event.endDate = try Self.parseDate(endDate) }
        guard event.endDate > event.startDate else { throw CalendarError.invalidRange }
        if let calendar { event.calendar = try writableCalendar(named: calendar) }
        if let location { event.location = location.isEmpty ? nil : location }
        if let notes { event.notes = notes.isEmpty ? nil : notes }
        if let url { event.url = url.isEmpty ? nil : try Self.url(from: url) }
        if let allDay { event.isAllDay = allDay }
        if let alertMinutesBefore {
            event.alarms?.forEach(event.removeAlarm)
            event.addAlarm(EKAlarm(relativeOffset: TimeInterval(-alertMinutesBefore * 60)))
        }
        if clearRecurrence { event.recurrenceRules?.forEach(event.removeRecurrenceRule) }
        if let recurrence {
            event.recurrenceRules?.forEach(event.removeRecurrenceRule)
            event.addRecurrenceRule(try Self.recurrenceRule(from: recurrence))
        }
        try store.save(event, span: span, commit: true)
        return Self.dto(from: event)
    }

    private func resolveCalendars(_ nameOrID: String?) throws -> [EKCalendar]? {
        guard let nameOrID, !nameOrID.isEmpty else { return nil }
        if let calendar = store.calendars(for: .event)
            .first(where: { $0.calendarIdentifier == nameOrID }) {
            return [calendar]
        }
        let matches = store.calendars(for: .event).filter {
            $0.title.caseInsensitiveCompare(nameOrID) == .orderedSame
        }
        guard !matches.isEmpty else { throw CalendarError.calendarNotFound(nameOrID) }
        guard matches.count == 1 else { throw CalendarError.calendarAmbiguous(nameOrID) }
        return matches
    }

    private func writableCalendar(named nameOrID: String?) throws -> EKCalendar {
        let calendar = try resolveCalendars(nameOrID)?.first ?? store.defaultCalendarForNewEvents
        guard let calendar else { throw CalendarError.calendarNotFound(nameOrID ?? "default") }
        guard calendar.allowsContentModifications else { throw CalendarError.calendarNotWritable(calendar.title) }
        return calendar
    }

    nonisolated private static func calendarDTO(from calendar: EKCalendar) -> CalendarDTO {
        CalendarDTO(
            id: calendar.calendarIdentifier,
            name: calendar.title,
            color: calendar.cgColor.flatMap(hex(from:)),
            writable: calendar.allowsContentModifications)
    }

    nonisolated private static func dto(from event: EKEvent) -> CalendarEventDTO {
        CalendarEventDTO(
            id: event.eventIdentifier,
            calendarID: event.calendar.calendarIdentifier,
            calendar: event.calendar.title,
            title: event.title ?? "",
            startDate: iso(event.startDate),
            endDate: iso(event.endDate),
            allDay: event.isAllDay,
            location: event.location,
            notes: event.notes,
            url: event.url?.absoluteString,
            alertMinutesBefore: (event.alarms?.first).map { Int(-$0.relativeOffset / 60) },
            recurrence: event.recurrenceRules?.first.map(recurrenceDTO(from:)))
    }

    nonisolated private static func recurrenceDTO(from rule: EKRecurrenceRule) -> CalendarRecurrenceDTO {
        let frequency: String = switch rule.frequency {
        case .daily: "daily"
        case .weekly: "weekly"
        case .monthly: "monthly"
        case .yearly: "yearly"
        @unknown default: "unknown"
        }
        return CalendarRecurrenceDTO(
            frequency: frequency,
            interval: rule.interval,
            endDate: rule.recurrenceEnd?.endDate.map(iso))
    }

    nonisolated private static func recurrenceRule(from input: CalendarRecurrenceInput) throws -> EKRecurrenceRule {
        let frequency: EKRecurrenceFrequency
        switch input.frequency.lowercased() {
        case "daily": frequency = .daily
        case "weekly": frequency = .weekly
        case "monthly": frequency = .monthly
        case "yearly": frequency = .yearly
        default: throw CalendarError.invalidRecurrence(input.frequency)
        }
        let interval = input.interval ?? 1
        guard interval > 0 else { throw CalendarError.invalidRecurrence("interval must be greater than zero") }
        let end = try input.endDate.map { EKRecurrenceEnd(end: try parseDate($0)) }
        return EKRecurrenceRule(recurrenceWith: frequency, interval: interval, end: end)
    }

    nonisolated private static func url(from string: String) throws -> URL {
        guard let url = URL(string: string), url.scheme != nil else { throw CalendarError.invalidURL(string) }
        return url
    }

    nonisolated private static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

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
        throw CalendarError.badDate(string)
    }
}

private extension CalendarService {
    nonisolated static func hex(from color: CGColor) -> String? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let rgb = color.converted(to: space, intent: .defaultIntent, options: nil),
              let components = rgb.components, components.count >= 3 else { return nil }
        return String(format: "#%02X%02X%02X", Int(components[0] * 255), Int(components[1] * 255), Int(components[2] * 255))
    }
}
