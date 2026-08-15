import Foundation

/// One event from a model's streaming response.
public enum ModelStreamEvent: Sendable, Equatable {
    case textDelta(String)
    case textEnd(String)
    case thinkingDelta(String)
    case thinkingEnd(text: String, redactedData: String?)
    case toolCall(id: String, name: String, input: JSONValue)
    case messageEnd(id: String, stopReason: StopReason, usage: Usage)
}

public struct CreateMessageParams: Sendable {
    public let messages: [Message]
    public let tools: [any Tool]
    public let maxTokens: Int?

    public init(messages: [Message], tools: [any Tool] = [], maxTokens: Int? = nil) {
        self.messages = messages
        self.tools = tools
        self.maxTokens = maxTokens
    }
}

/// A provider adapter. Everything above this line is provider-agnostic; each
/// conformance converts to and from its own wire format, including how it maps
/// `ThinkingLevel`.
public protocol Model: Sendable {
    func streamMessage(_ params: CreateMessageParams) -> AsyncThrowingStream<ModelStreamEvent, Error>

    /// Backs the `web_search` tool. Return `[]` when the provider has no search.
    func searchWeb(_ query: String, maxResults: Int?) async throws -> [SearchHit]
}

public enum ModelError: LocalizedError, Equatable {
    case http(status: Int, body: String)
    case truncatedStream
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .http(let status, let body):
            let trimmed = body.count > 400 ? String(body.prefix(400)) + "…" : body
            return "Model request failed (\(status)): \(trimmed)"
        case .truncatedStream:
            return "The response ended mid-stream."
        case .invalidResponse(let detail):
            return "Unexpected response from the model: \(detail)"
        }
    }

    /// Whether retrying the same request could plausibly succeed. 408/429 and
    /// 5xx are transient; a 4xx is a request the provider will keep rejecting.
    public var isRetryable: Bool {
        switch self {
        case .http(let status, _):
            return status == 408 || status == 429 || (500...599).contains(status)
        case .truncatedStream:
            return true
        case .invalidResponse:
            return false
        }
    }
}
