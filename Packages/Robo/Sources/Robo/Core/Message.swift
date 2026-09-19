import Foundation

/// One piece of a message. Assistant turns interleave text, reasoning, and tool
/// calls; `toolResult` parts carry a tool's output back on the following turn.
public enum ContentPart: Sendable, Equatable {
    case text(String)
    /// `redactedData` is the provider's opaque reasoning payload. Providers that
    /// require reasoning to be echoed back across a tool call (OpenRouter's
    /// `reasoning_details`) stash it here; everyone else leaves it nil.
    case thinking(text: String, redactedData: String? = nil)
    case toolCall(id: String, name: String, input: JSONValue)
    case toolResult(id: String, name: String, output: String, isError: Bool = false)
}

public struct Message: Sendable, Equatable {
    public enum Role: String, Sendable {
        case system, user, assistant, tool
    }

    public let role: Role
    public let content: [ContentPart]

    public init(role: Role, content: [ContentPart]) {
        self.role = role
        self.content = content
    }

    public init(role: Role, text: String) {
        self.init(role: role, content: [.text(text)])
    }

    /// The message's plain text, ignoring reasoning and tool traffic.
    public var text: String {
        content.compactMap { part in
            if case .text(let value) = part { return value }
            return nil
        }.joined(separator: "\n")
    }
}

/// Why the model stopped producing a message.
public enum StopReason: Sendable, Equatable {
    case endTurn
    case toolUse
    case maxTokens
    case refusal
}

public struct Usage: Sendable, Equatable {
    public var inputTokens: Int
    public var outputTokens: Int

    public init(inputTokens: Int = 0, outputTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

/// A web search result. Some backends answer in prose rather than returning
/// links, in which case the hit carries `text` and no `url`.
public struct SearchHit: Sendable, Equatable {
    public let title: String
    public let url: String?
    public let text: String?

    public init(title: String, url: String? = nil, text: String? = nil) {
        self.title = title
        self.url = url
        self.text = text
    }
}

/// Unified reasoning-effort scale. Each model adapter maps a level onto its own
/// wire format, or drops levels the provider does not support.
public enum ThinkingLevel: String, Sendable, CaseIterable {
    case off, minimal, low, medium, high, xhigh
}
