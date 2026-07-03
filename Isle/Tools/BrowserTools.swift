//
//  BrowserTools.swift
//  Isle
//

import Foundation
import MCP

/// The MCP tool surface for driving Chrome: navigate, read, click, type, evaluate, and
/// screenshot, their JSON-Schema declarations, and the dispatch from a `tools/call` to
/// `BrowserService`. Mirrors `ReminderTools`/`MailTools` — a single JSON text block per
/// result, `Log.tool` as the choke point, errors as `isError`.
nonisolated struct BrowserTools: Sendable {
    let service: BrowserService

    static let tools: [Tool] = [
        Tool(
            name: "browser_navigate",
            description: "Open a URL in the automation browser (the user's installed Chrome, dedicated persistent profile) and return the page's title and visible text.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "url": ["type": "string", "description": "The absolute URL to open, e.g. https://example.com."]
                ],
                "required": ["url"],
            ]),
        Tool(
            name: "browser_read",
            description: "Read the current page: its URL, title, and visible text (or outer HTML). Use before acting so you know what's on screen.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "html": ["type": "boolean", "description": "Return the outer HTML instead of visible text (default false)."]
                ],
            ]),
        Tool(
            name: "browser_click",
            description: "Click the first element matching a CSS selector on the current page.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "selector": ["type": "string", "description": "A CSS selector, e.g. \"button.submit\" or \"#login\"."]
                ],
                "required": ["selector"],
            ]),
        Tool(
            name: "browser_type",
            description: "Type text into a form field (input, textarea, or contenteditable) matched by a CSS selector, optionally submitting its form.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "selector": ["type": "string", "description": "A CSS selector for the field to fill."],
                    "text": ["type": "string", "description": "The text to enter."],
                    "submit": ["type": "boolean", "description": "Submit the field's form after typing (default false)."],
                ],
                "required": ["selector", "text"],
            ]),
        Tool(
            name: "browser_evaluate",
            description: "Run a JavaScript expression in the current page and return its value as JSON.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "expression": ["type": "string", "description": "A JavaScript expression, e.g. document.querySelectorAll('a').length."]
                ],
                "required": ["expression"],
            ]),
        Tool(
            name: "browser_screenshot",
            description: "Capture a PNG screenshot of the current page's viewport and return the file path it was saved to.",
            inputSchema: [
                "type": "object",
                "properties": [:],
            ]),
        Tool(
            name: "browser_show",
            description: "Bring the browser window to the foreground so the user can do something only they can — sign in, solve a CAPTCHA, approve a step. The browser runs invisibly by default; call this when a page needs the user. Optionally pass a url; otherwise the current page is reopened. Chrome stays visible afterward. After calling, tell the user what to do and wait for their next message before continuing.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "url": ["type": "string", "description": "Optional URL to open in the visible window; defaults to the current page."]
                ],
            ]),
        Tool(
            name: "browser_hide",
            description: "Send the browser back to the background (invisible) after the user has finished an interactive step. Any session established while it was visible (e.g. a login) is kept.",
            inputSchema: [
                "type": "object",
                "properties": [:],
            ]),
    ]

    static let toolNames: Set<String> = Set(tools.map(\.name))

    /// Routes a `tools/call` to the matching service method and packages the result.
    /// Any thrown error becomes an `isError` result carrying a readable message.
    /// Every call is logged here — the single choke point for Codex's browser use.
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
            case "browser_navigate":
                // A `data:` URL decodes as MCP's binary `.data` value (not `.string`), so
                // stringValue is nil there — distinguish that from a genuinely absent arg.
                guard let url = arguments?["url"]?.stringValue else {
                    return Self.error(arguments?["url"] == nil
                        ? "Missing required argument: url"
                        : "The url must be a plain http(s) URL string (data: URLs aren't supported).")
                }
                return Self.json(try await service.navigate(url: url))

            case "browser_read":
                return Self.json(try await service.read(html: arguments?["html"]?.boolValue ?? false))

            case "browser_click":
                guard let selector = arguments?["selector"]?.stringValue else { return Self.error("Missing required argument: selector") }
                return Self.json(try await service.click(selector: selector))

            case "browser_type":
                guard let selector = arguments?["selector"]?.stringValue else { return Self.error("Missing required argument: selector") }
                guard let text = arguments?["text"]?.stringValue else { return Self.error("Missing required argument: text") }
                return Self.json(try await service.type(
                    selector: selector, text: text, submit: arguments?["submit"]?.boolValue ?? false))

            case "browser_evaluate":
                guard let expression = arguments?["expression"]?.stringValue else { return Self.error("Missing required argument: expression") }
                return Self.text(try await service.evaluate(expression: expression))

            case "browser_screenshot":
                return Self.json(try await service.screenshot())

            case "browser_show":
                return Self.json(try await service.show(url: arguments?["url"]?.stringValue))

            case "browser_hide":
                return Self.json(try await service.hide())

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
