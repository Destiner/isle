import Foundation
import MCP

/// Bridging between MCP's wire types and the agent's own.
///
/// Useful beyond the MCP client: a host that already declares its tools as MCP
/// `Tool` values and dispatches them in-process can expose them to the agent
/// without standing up a server and talking to itself over a socket.
public enum MCPBridge {
    /// Flattens tool-call content into the single string the agent hands the
    /// model. Non-text parts are described rather than dropped, so the model can
    /// tell that something came back.
    public static func text(from content: [MCP.Tool.Content]) -> String {
        content.compactMap { item -> String? in
            switch item {
            case .text(let text, _, _):
                return text
            case .image(_, let mimeType, _, _):
                return "(image: \(mimeType))"
            case .audio(_, let mimeType, _, _):
                return "(audio: \(mimeType))"
            case .resource(let resource, _, _):
                return "(resource: \(resource))"
            case .resourceLink(let uri, let name, _, _, _, _):
                return "(resource link: \(name) — \(uri))"
            }
        }.joined(separator: "\n")
    }

    /// Renders a completed tool call as agent-facing output. An in-band failure
    /// is returned as text rather than thrown, so the model can react to it and
    /// pick another approach instead of the turn ending.
    public static func output(content: [MCP.Tool.Content], isError: Bool?) -> String {
        let text = self.text(from: content)
        if isError == true {
            return "Error: \(text.isEmpty ? "the tool reported a failure." : text)"
        }
        return text.isEmpty ? "(no output)" : text
    }

    /// Wraps an MCP tool declaration plus an in-process dispatch closure as an
    /// agent tool.
    public static func tool(
        _ declaration: MCP.Tool,
        invoke: @escaping @Sendable ([String: MCP.Value]) async -> (
            content: [MCP.Tool.Content], isError: Bool?
        )
    ) -> any Tool {
        BasicTool(
            name: declaration.name,
            description: declaration.description ?? "",
            inputSchema: JSONValue(mcp: declaration.inputSchema)
        ) { input, _ in
            let arguments = (input.objectValue ?? [:]).mapValues(\.mcpValue)
            let result = await invoke(arguments)
            return output(content: result.content, isError: result.isError)
        }
    }
}

// MARK: - Value bridging

extension JSONValue {
    public init(mcp value: MCP.Value) {
        switch value {
        case .null: self = .null
        case .bool(let inner): self = .bool(inner)
        case .int(let inner): self = .number(Double(inner))
        case .double(let inner): self = .number(inner)
        case .string(let inner): self = .string(inner)
        case .data(_, let inner): self = .string(inner.base64EncodedString())
        case .array(let inner): self = .array(inner.map { JSONValue(mcp: $0) })
        case .object(let inner): self = .object(inner.mapValues { JSONValue(mcp: $0) })
        }
    }

    public var mcpValue: MCP.Value {
        switch self {
        case .null: return .null
        case .bool(let inner): return .bool(inner)
        case .number(let inner):
            // Keep whole numbers integral: a schema that says "integer" rejects
            // 10.0 where it accepts 10.
            if inner.rounded() == inner, inner.magnitude < 9.007e15 {
                return .int(Int(inner))
            }
            return .double(inner)
        case .string(let inner): return .string(inner)
        case .array(let inner): return .array(inner.map(\.mcpValue))
        case .object(let inner): return .object(inner.mapValues(\.mcpValue))
        }
    }
}
