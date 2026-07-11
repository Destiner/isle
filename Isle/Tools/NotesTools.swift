import Foundation
import MCP

nonisolated struct NotesTools: Sendable {
    let service: NotesService
    static let toolNames: Set<String> = Set(tools.map(\.name))
    static let tools: [Tool] = [
        Tool(name: "list_note_folders", description: "List Apple Notes folders and their ids.", inputSchema: ["type": "object", "properties": [:]]),
        Tool(name: "list_notes", description: "List recent Apple Notes summaries, optionally in one folder. Use get_note for content.", inputSchema: ["type": "object", "properties": ["folder_id": ["type": "string"], "limit": ["type": "integer", "description": "Maximum results (default 20, max 100)."]]]),
        Tool(name: "search_notes", description: "Search Apple Notes' plain-text contents, optionally within a folder.", inputSchema: ["type": "object", "properties": ["query": ["type": "string"], "folder_id": ["type": "string"], "limit": ["type": "integer", "description": "Maximum results (default 20, max 100)."]], "required": ["query"]]),
        Tool(name: "get_note", description: "Get one Apple Note's complete plain-text content by id.", inputSchema: ["type": "object", "properties": ["id": ["type": "string"]], "required": ["id"]]),
        Tool(name: "create_note", description: "Create a new plain-text Apple Note. It is saved immediately.", inputSchema: ["type": "object", "properties": ["title": ["type": "string"], "body": ["type": "string"], "folder_id": ["type": "string", "description": "Optional folder id from list_note_folders."]], "required": ["title", "body"]]),
        Tool(name: "edit_note", description: "Replace a note title and/or body. Supplying body replaces the whole body and its rich formatting.", inputSchema: ["type": "object", "properties": ["id": ["type": "string"], "title": ["type": "string"], "body": ["type": "string"]], "required": ["id"]]),
        Tool(name: "append_to_note", description: "Append plain text to an existing Apple Note without replacing its current content.", inputSchema: ["type": "object", "properties": ["id": ["type": "string"], "text": ["type": "string"]], "required": ["id", "text"]]),
    ]

    func call(name: String, arguments: [String: Value]?) async -> CallTool.Result {
        let start = Date(); let result = await dispatch(name: name, arguments: arguments)
        let chars = result.content.reduce(0) { if case let .text(text, _, _) = $1 { $0 + text.count } else { $0 } }
        await Log.tool(name: name, arguments: Self.jsonObject(arguments), isError: result.isError == true, resultChars: chars, durationMs: Int(Date().timeIntervalSince(start) * 1000))
        return result
    }

    private func dispatch(name: String, arguments: [String: Value]?) async -> CallTool.Result {
        do {
            switch name {
            case "list_note_folders": return Self.json(try await service.folders())
            case "list_notes": return Self.json(try await service.list(folderID: arguments?["folder_id"]?.stringValue, limit: arguments?["limit"]?.intValue ?? 20))
            case "search_notes":
                guard let query = arguments?["query"]?.stringValue else { return Self.error("Missing required argument: query") }
                return Self.json(try await service.search(query: query, folderID: arguments?["folder_id"]?.stringValue, limit: arguments?["limit"]?.intValue ?? 20))
            case "get_note":
                guard let id = arguments?["id"]?.stringValue else { return Self.error("Missing required argument: id") }
                return Self.json(try await service.get(id: id))
            case "create_note":
                guard let title = arguments?["title"]?.stringValue, let body = arguments?["body"]?.stringValue else { return Self.error("Missing required argument: title and body") }
                return Self.json(try await service.create(title: title, body: body, folderID: arguments?["folder_id"]?.stringValue))
            case "edit_note":
                guard let id = arguments?["id"]?.stringValue else { return Self.error("Missing required argument: id") }
                return Self.json(try await service.edit(id: id, title: arguments?["title"]?.stringValue, body: arguments?["body"]?.stringValue))
            case "append_to_note":
                guard let id = arguments?["id"]?.stringValue, let text = arguments?["text"]?.stringValue else { return Self.error("Missing required argument: id and text") }
                return Self.json(try await service.append(id: id, text: text))
            default: return Self.error("Unknown tool: \(name)")
            }
        } catch { return Self.error((error as? LocalizedError)?.errorDescription ?? "\(error)") }
    }
    private static func jsonObject(_ args: [String: Value]?) -> Any { guard let args, let data = try? JSONEncoder().encode(args), let object = try? JSONSerialization.jsonObject(with: data) else { return [String: Any]() }; return object }
    private static func text(_ string: String, isError: Bool = false) -> CallTool.Result { .init(content: [.text(text: string, annotations: nil, _meta: nil)], isError: isError) }
    private static func error(_ message: String) -> CallTool.Result { text(message, isError: true) }
    private static func json<T: Encodable>(_ value: T) -> CallTool.Result { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; guard let data = try? encoder.encode(value), let string = String(data: data, encoding: .utf8) else { return error("Failed to encode result.") }; return text(string) }
}
