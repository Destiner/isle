import Foundation

/// What a tool can reach while it runs.
public struct ToolContext: Sendable {
    /// Working directory a run is scoped to. Tools that touch the filesystem or
    /// spawn processes use this rather than the process-wide cwd.
    public let cwd: String

    /// Web search, backed by the session's model. Kept as a closure so a tool
    /// never has to know which provider is behind it.
    public let searchWeb: @Sendable (_ query: String, _ maxResults: Int?) async throws -> [SearchHit]

    public init(
        cwd: String,
        searchWeb: @escaping @Sendable (String, Int?) async throws -> [SearchHit]
    ) {
        self.cwd = cwd
        self.searchWeb = searchWeb
    }
}

/// A model-callable tool. `inputSchema` is a JSON Schema object handed to the
/// provider verbatim; `execute` receives whatever the model actually sent, which
/// is not guaranteed to match it.
public protocol Tool: Sendable {
    var name: String { get }
    var description: String { get }
    var inputSchema: JSONValue { get }
    func execute(_ input: JSONValue, context: ToolContext) async throws -> String
}

/// A tool built from a closure, for callers that don't need a named type.
public struct BasicTool: Tool {
    public let name: String
    public let description: String
    public let inputSchema: JSONValue
    private let handler: @Sendable (JSONValue, ToolContext) async throws -> String

    public init(
        name: String,
        description: String,
        inputSchema: JSONValue,
        execute: @escaping @Sendable (JSONValue, ToolContext) async throws -> String
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.handler = execute
    }

    public func execute(_ input: JSONValue, context: ToolContext) async throws -> String {
        try await handler(input, context)
    }
}

/// A group of tools that share a lifecycle — an MCP server connection, say.
/// Resolved once per session so a provider can connect lazily.
public protocol ToolProvider: Sendable {
    func tools() async throws -> [any Tool]
}

public struct StaticToolProvider: ToolProvider {
    private let value: [any Tool]

    public init(_ tools: [any Tool]) {
        self.value = tools
    }

    public func tools() async throws -> [any Tool] { value }
}
