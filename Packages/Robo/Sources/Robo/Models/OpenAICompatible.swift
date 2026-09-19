import Foundation

/// Per-stream accumulator for providers whose reasoning arrives as a structured
/// payload that must be echoed back verbatim on the next turn. Created fresh per
/// request so concurrent streams on one adapter never share state.
public protocol ReasoningAccumulator: AnyObject {
    /// Consume one streamed delta; return plaintext reasoning to surface, or nil.
    func push(_ delta: [String: JSONValue]) -> String?
    /// The opaque blob to hang off the resulting thinking part, or nil.
    func finish() -> String?
}

/// Chat-completions adapter. Subclasses supply a base URL, credentials, and the
/// provider-specific bits: how `ThinkingLevel` maps onto the request, any extra
/// headers, and how reasoning is read back and replayed.
open class OpenAICompatible: Model, @unchecked Sendable {
    public let modelName: String
    public let apiKey: String
    public let baseURL: String
    public let thinking: ThinkingLevel
    public let transport: any HTTPTransport

    public init(
        modelName: String,
        apiKey: String,
        baseURL: String,
        thinking: ThinkingLevel = .off,
        transport: any HTTPTransport = URLSessionTransport()
    ) {
        self.modelName = modelName
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.thinking = thinking
        self.transport = transport
    }

    // MARK: - Subclass hooks

    /// Map the unified thinking level onto provider request fields. Default is a
    /// no-op, so a server that understands no reasoning fields still works.
    open func applyThinking(_ body: inout [String: JSONValue]) {}

    /// Extra request headers (attribution, routing). Merged after the standard set.
    open func extraHeaders() -> [String: String] { [:] }

    /// Providers whose reasoning is not `reasoning_content`, or that need it
    /// replayed, return an accumulator here.
    open func makeReasoningAccumulator() -> ReasoningAccumulator? { nil }

    /// Last chance to adjust a serialised assistant message — e.g. to reattach a
    /// provider's reasoning payload from the thinking parts it was stashed on.
    open func adaptAssistantWire(
        _ message: [String: JSONValue], thinking: [ContentPart]
    ) -> [String: JSONValue] {
        message
    }

    // MARK: - Streaming

    public func streamMessage(
        _ params: CreateMessageParams
    ) -> AsyncThrowingStream<ModelStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.run(params, into: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(
        _ params: CreateMessageParams,
        into continuation: AsyncThrowingStream<ModelStreamEvent, Error>.Continuation
    ) async throws {
        var body: [String: JSONValue] = [
            "model": .string(modelName),
            "messages": .array(serialize(params.messages)),
            "stream": .bool(true),
            "stream_options": .object(["include_usage": .bool(true)]),
        ]
        if let maxTokens = params.maxTokens {
            body["max_completion_tokens"] = .number(Double(maxTokens))
        }
        if !params.tools.isEmpty {
            body["tools"] = .array(params.tools.map(Self.wireTool))
        }
        applyThinking(&body)

        let response = try await transport.stream(
            makeRequest(path: "/chat/completions", body: .object(body), stream: true))
        guard (200...299).contains(response.status) else {
            throw ModelError.http(
                status: response.status,
                body: String(data: response.body, encoding: .utf8) ?? "")
        }

        var id = ""
        var stopReason = StopReason.endTurn
        var usage = Usage()
        var textBuffer = ""
        var textOpen = false
        var thinkingBuffer = ""
        var thinkingOpen = false
        var sawFinishReason = false
        var builders: [Int: ToolCallBuilder] = [:]
        var builderOrder: [Int] = []
        let reasoning = makeReasoningAccumulator()

        func closeThinking() {
            continuation.yield(
                .thinkingEnd(text: thinkingBuffer, redactedData: reasoning?.finish()))
            thinkingOpen = false
            thinkingBuffer = ""
        }

        for try await payload in response.events {
            guard let chunk = JSONValue.parse(payload)?.objectValue else { continue }

            if id.isEmpty, let chunkID = chunk["id"]?.stringValue { id = chunkID }
            if let chunkUsage = chunk["usage"]?.objectValue {
                if let value = chunkUsage["prompt_tokens"]?.intValue { usage.inputTokens = value }
                if let value = chunkUsage["completion_tokens"]?.intValue {
                    usage.outputTokens = value
                }
            }

            guard let choice = chunk["choices"]?.arrayValue?.first?.objectValue else { continue }

            if let delta = choice["delta"]?.objectValue {
                let reasoningText =
                    reasoning?.push(delta) ?? delta["reasoning_content"]?.stringValue
                if let reasoningText, !reasoningText.isEmpty {
                    thinkingOpen = true
                    thinkingBuffer += reasoningText
                    continuation.yield(.thinkingDelta(reasoningText))
                }

                if let content = delta["content"]?.stringValue, !content.isEmpty {
                    if thinkingOpen { closeThinking() }
                    textOpen = true
                    textBuffer += content
                    continuation.yield(.textDelta(content))
                }

                if let toolCalls = delta["tool_calls"]?.arrayValue {
                    for entry in toolCalls {
                        guard let call = entry.objectValue else { continue }
                        let index = call["index"]?.intValue ?? 0
                        if builders[index] == nil {
                            builders[index] = ToolCallBuilder()
                            builderOrder.append(index)
                        }
                        // Only the first chunk of a call carries its id and
                        // name; later chunks repeat the key as an empty string,
                        // which must not clobber what was already collected.
                        if let value = call["id"]?.stringValue, !value.isEmpty {
                            builders[index]?.id = value
                        }
                        if let function = call["function"]?.objectValue {
                            if let name = function["name"]?.stringValue, !name.isEmpty {
                                builders[index]?.name = name
                            }
                            if let args = function["arguments"]?.stringValue {
                                builders[index]?.arguments += args
                            }
                        }
                    }
                }
            }

            if let finish = choice["finish_reason"]?.stringValue {
                stopReason = Self.mapFinishReason(finish)
                sawFinishReason = true
            }
        }

        // Without a finish_reason the provider hung up early; surfacing the
        // partial text as a complete answer would silently truncate it.
        guard sawFinishReason else { throw ModelError.truncatedStream }

        if textOpen { continuation.yield(.textEnd(textBuffer)) }
        if thinkingOpen { closeThinking() }

        for index in builderOrder {
            guard let builder = builders[index] else { continue }
            continuation.yield(
                .toolCall(
                    id: builder.id,
                    name: builder.name,
                    input: Self.parseArguments(builder.arguments)))
        }

        continuation.yield(.messageEnd(id: id, stopReason: stopReason, usage: usage))
    }

    // MARK: - Requests

    public func makeRequest(path: String, body: JSONValue, stream: Bool) -> URLRequest {
        var request = URLRequest(url: URL(string: baseURL + path)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization")
        if stream {
            request.setValue("text/event-stream", forHTTPHeaderField: "accept")
        }
        for (key, value) in extraHeaders() {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = body.encoded()
        return request
    }

    // MARK: - Serialisation

    public func serialize(_ messages: [Message]) -> [JSONValue] {
        var wire: [JSONValue] = []

        for message in messages {
            switch message.role {
            case .system, .user:
                wire.append(
                    .object([
                        "role": .string(message.role.rawValue),
                        "content": .string(message.text),
                    ]))

            case .assistant:
                var texts: [String] = []
                var toolCalls: [JSONValue] = []
                var thinkingParts: [ContentPart] = []

                for part in message.content {
                    switch part {
                    case .text(let value):
                        texts.append(value)
                    case .toolCall(let id, let name, let input):
                        toolCalls.append(
                            .object([
                                "id": .string(id),
                                "type": .string("function"),
                                "function": .object([
                                    "name": .string(name),
                                    "arguments": .string(input.encodedString()),
                                ]),
                            ]))
                    case .thinking:
                        // No portable chat-completions representation, so the
                        // base drops it; `adaptAssistantWire` gets a chance to
                        // reattach it in the provider's own shape.
                        thinkingParts.append(part)
                    case .toolResult:
                        break
                    }
                }

                var assistant: [String: JSONValue] = [
                    "role": .string("assistant"),
                    "content": texts.isEmpty ? .null : .string(texts.joined(separator: "\n")),
                ]
                if !toolCalls.isEmpty { assistant["tool_calls"] = .array(toolCalls) }
                wire.append(.object(adaptAssistantWire(assistant, thinking: thinkingParts)))

            case .tool:
                for part in message.content {
                    guard case .toolResult(let id, _, let output, _) = part else { continue }
                    wire.append(
                        .object([
                            "role": .string("tool"),
                            "tool_call_id": .string(id),
                            "content": .string(output),
                        ]))
                }
            }
        }

        return wire
    }

    private static func wireTool(_ tool: any Tool) -> JSONValue {
        .object([
            "type": .string("function"),
            "function": .object([
                "name": .string(tool.name),
                "description": .string(tool.description),
                "parameters": tool.inputSchema,
            ]),
        ])
    }

    private static func mapFinishReason(_ reason: String) -> StopReason {
        switch reason {
        case "tool_calls": return .toolUse
        case "length": return .maxTokens
        case "content_filter": return .refusal
        default: return .endTurn
        }
    }

    /// Tool arguments arrive as a JSON string. A model occasionally emits
    /// something unparseable; pass it through as a string rather than failing
    /// the turn, so the tool can reject it with a message the model can read.
    private static func parseArguments(_ raw: String) -> JSONValue {
        if raw.isEmpty { return .object([:]) }
        return JSONValue.parse(raw) ?? .string(raw)
    }

    public func searchWeb(_ query: String, maxResults: Int?) async throws -> [SearchHit] { [] }
}

private struct ToolCallBuilder {
    var id: String = ""
    var name: String = ""
    var arguments: String = ""
}
