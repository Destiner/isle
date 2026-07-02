//
//  ReminderTools.swift
//  Isle
//

import Foundation
import MCP

/// The MCP tool surface Isle exposes to Codex: the five reminder operations, their
/// JSON-Schema declarations (for `tools/list`), and the dispatch from a `tools/call`
/// to `RemindersService`. Results are returned as a single JSON text block so the
/// model gets structured data it can read back conversationally.
nonisolated struct ReminderTools: Sendable {
    let service: RemindersService

    static let tools: [Tool] = [
        Tool(
            name: "search_reminders",
            description: "Search reminders whose title or notes contain the given text.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "Text to match in a reminder's title or notes."],
                    "list": ["type": "string", "description": "Optional reminder list name to search within."],
                    "include_completed": ["type": "boolean", "description": "Include completed reminders (default false)."],
                ],
                "required": ["query"],
            ]),
        Tool(
            name: "list_reminders",
            description: "List reminders, optionally limited to one list. Each result includes the list it belongs to.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "list": ["type": "string", "description": "Optional reminder list name; omit to list across all lists."],
                    "include_completed": ["type": "boolean", "description": "Include completed reminders (default false)."],
                ],
            ]),
        Tool(
            name: "get_reminder",
            description: "Get a single reminder's full details by its id.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "The reminder's id (as returned by the other tools)."]
                ],
                "required": ["id"],
            ]),
        Tool(
            name: "create_reminder",
            description: "Create a new reminder.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "title": ["type": "string", "description": "The reminder's title."],
                    "notes": ["type": "string", "description": "Optional notes/body."],
                    "due_date": ["type": "string", "description": "Optional due date in ISO 8601, e.g. 2026-07-05T09:00:00Z."],
                    "list": ["type": "string", "description": "Optional list name; the default list is used when omitted."],
                    "priority": ["type": "integer", "description": "Optional priority: 0 none, 1-4 high, 5 medium, 6-9 low."],
                ],
                "required": ["title"],
            ]),
        Tool(
            name: "edit_reminder",
            description: "Edit an existing reminder. Only the fields you provide are changed.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "The id of the reminder to edit."],
                    "title": ["type": "string", "description": "New title."],
                    "notes": ["type": "string", "description": "New notes/body."],
                    "due_date": ["type": "string", "description": "New due date in ISO 8601."],
                    "completed": ["type": "boolean", "description": "Mark completed (true) or incomplete (false)."],
                    "priority": ["type": "integer", "description": "New priority: 0 none, 1-4 high, 5 medium, 6-9 low."],
                ],
                "required": ["id"],
            ]),
    ]

    /// Routes a `tools/call` to the matching service method and packages the result.
    /// Any thrown error becomes an `isError` result carrying a readable message.
    /// Every call is logged here — the single choke point for Codex's tool use.
    func call(name: String, arguments: [String: Value]?) async -> CallTool.Result {
        let start = Date()
        let result = await dispatch(name: name, arguments: arguments)
        let chars = result.content.reduce(0) { acc, item in
            if case let .text(text, _, _) = item { return acc + text.count }
            return acc
        }
        Log.tool(name: name, arguments: arguments.map { "\($0)" } ?? "{}",
                 isError: result.isError == true, resultChars: chars,
                 durationMs: Int(Date().timeIntervalSince(start) * 1000))
        return result
    }

    private func dispatch(name: String, arguments: [String: Value]?) async -> CallTool.Result {
        do {
            switch name {
            case "search_reminders":
                guard let query = arguments?["query"]?.stringValue else { return Self.error("Missing required argument: query") }
                let result = try await service.search(
                    query: query,
                    listName: arguments?["list"]?.stringValue,
                    includeCompleted: arguments?["include_completed"]?.boolValue ?? false)
                return Self.json(result)

            case "list_reminders":
                let result = try await service.list(
                    listName: arguments?["list"]?.stringValue,
                    includeCompleted: arguments?["include_completed"]?.boolValue ?? false)
                return Self.json(result)

            case "get_reminder":
                guard let id = arguments?["id"]?.stringValue else { return Self.error("Missing required argument: id") }
                return Self.json(try await service.get(id: id))

            case "create_reminder":
                guard let title = arguments?["title"]?.stringValue else { return Self.error("Missing required argument: title") }
                let result = try await service.create(
                    title: title,
                    notes: arguments?["notes"]?.stringValue,
                    dueDate: arguments?["due_date"]?.stringValue,
                    listName: arguments?["list"]?.stringValue,
                    priority: arguments?["priority"]?.intValue)
                return Self.json(result)

            case "edit_reminder":
                guard let id = arguments?["id"]?.stringValue else { return Self.error("Missing required argument: id") }
                let result = try await service.edit(
                    id: id,
                    title: arguments?["title"]?.stringValue,
                    notes: arguments?["notes"]?.stringValue,
                    dueDate: arguments?["due_date"]?.stringValue,
                    completed: arguments?["completed"]?.boolValue,
                    priority: arguments?["priority"]?.intValue)
                return Self.json(result)

            default:
                return Self.error("Unknown tool: \(name)")
            }
        } catch {
            return Self.error((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
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
