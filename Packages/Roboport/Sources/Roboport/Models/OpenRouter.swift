import Foundation

/// OpenRouter: the whole catalogue behind one key. Model names are the full
/// `author/slug`.
public final class OpenRouter: OpenAICompatible, @unchecked Sendable {
    private let referer: String?
    private let title: String?

    public init(
        _ modelName: String,
        apiKey: String,
        thinking: ThinkingLevel = .off,
        /// Sent as `HTTP-Referer` / `X-Title`; OpenRouter uses them for usage
        /// attribution on its dashboards.
        referer: String? = nil,
        title: String? = nil,
        baseURL: String = "https://openrouter.ai/api/v1",
        transport: any HTTPTransport = URLSessionTransport()
    ) {
        self.referer = referer
        self.title = title
        super.init(
            modelName: modelName, apiKey: apiKey, baseURL: baseURL,
            thinking: thinking, transport: transport)
    }

    public override func extraHeaders() -> [String: String] {
        var headers: [String: String] = [:]
        if let referer { headers["http-referer"] = referer }
        if let title { headers["x-title"] = title }
        return headers
    }

    /// OpenRouter normalises reasoning across providers behind one `reasoning`
    /// object whose `effort` accepts exactly the unified scale, so every level
    /// passes straight through. `off` sends nothing at all, leaving a
    /// non-reasoning model's request untouched.
    public override func applyThinking(_ body: inout [String: JSONValue]) {
        guard thinking != .off else { return }
        body["reasoning"] = .object(["effort": .string(thinking.rawValue)])
    }

    public override func makeReasoningAccumulator() -> ReasoningAccumulator? {
        OpenRouterReasoning()
    }

    /// Reasoning models lose the thread across a tool call unless their
    /// `reasoning_details` come back verbatim, so replay the blob the
    /// accumulator stashed on the thinking part.
    public override func adaptAssistantWire(
        _ message: [String: JSONValue], thinking: [ContentPart]
    ) -> [String: JSONValue] {
        var details: [JSONValue] = []
        for part in thinking {
            guard case .thinking(_, let redacted) = part, let redacted else { continue }
            // A blob from another provider, or a truncated one: the turn is
            // still valid without it, so drop it rather than fail the request.
            guard let parsed = JSONValue.parse(redacted)?.arrayValue else { continue }
            details.append(contentsOf: parsed)
        }
        guard !details.isEmpty else { return message }
        var updated = message
        updated["reasoning_details"] = .array(details)
        return updated
    }

    /// The `web` plugin runs the search server-side and returns OpenAI-style
    /// `url_citation` annotations alongside a synthesised answer.
    public override func searchWeb(_ query: String, maxResults: Int?) async throws -> [SearchHit] {
        var plugin: [String: JSONValue] = ["id": .string("web")]
        if let maxResults { plugin["max_results"] = .number(Double(maxResults)) }

        let body = JSONValue.object([
            "model": .string(modelName),
            "plugins": .array([.object(plugin)]),
            "messages": .array([
                .object([
                    "role": .string("user"),
                    "content": .string(
                        "Search the web for: \(query). Summarise the most relevant results."),
                ])
            ]),
        ])

        let (status, data) = try await transport.send(
            makeRequest(path: "/chat/completions", body: body, stream: false))
        guard (200...299).contains(status) else {
            throw ModelError.http(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }

        let message = JSONValue.parse(data)?["choices"]?.arrayValue?.first?["message"]

        var hits: [SearchHit] = []
        var seen = Set<String>()
        for annotation in message?["annotations"]?.arrayValue ?? [] {
            guard let citation = annotation["url_citation"],
                let url = citation["url"]?.stringValue,
                !seen.contains(url)
            else { continue }
            seen.insert(url)
            hits.append(
                SearchHit(
                    title: citation["title"]?.stringValue ?? url,
                    url: url,
                    text: citation["content"]?.stringValue))
        }

        // Some upstreams answer without citations; surface the prose rather
        // than reporting an empty search.
        if hits.isEmpty {
            let answer = message?["content"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let answer, !answer.isEmpty else { return [] }
            return [SearchHit(title: "Web search answer", text: answer)]
        }

        if let maxResults { return Array(hits.prefix(maxResults)) }
        return hits
    }
}

/// OpenRouter streams `reasoning_details` as partial entries keyed by `index`,
/// alongside a plaintext `reasoning` string. Merge the entries so the complete
/// payload can be replayed next turn, and surface the plaintext (falling back to
/// whatever text the details carry) as thinking deltas.
final class OpenRouterReasoning: ReasoningAccumulator {
    /// Fields that stream incrementally and must be appended; everything else on
    /// an entry is last-write-wins.
    private static let textFields: Set<String> = ["text", "summary"]

    private var byIndex: [Int: [String: JSONValue]] = [:]
    private var order: [Int] = []

    func push(_ delta: [String: JSONValue]) -> String? {
        var text: String?
        if let plain = delta["reasoning"]?.stringValue, !plain.isEmpty { text = plain }

        for entry in delta["reasoning_details"]?.arrayValue ?? [] {
            guard let raw = entry.objectValue else { continue }
            let index = raw["index"]?.intValue ?? 0
            if byIndex[index] == nil {
                byIndex[index] = ["index": .number(Double(index))]
                order.append(index)
            }
            for (key, value) in raw {
                if Self.textFields.contains(key), let chunk = value.stringValue {
                    let previous = byIndex[index]?[key]?.stringValue ?? ""
                    byIndex[index]?[key] = .string(previous + chunk)
                    // Only stand in for the plaintext channel when it's absent.
                    if text == nil, !chunk.isEmpty { text = chunk }
                } else {
                    byIndex[index]?[key] = value
                }
            }
        }

        return text
    }

    func finish() -> String? {
        guard !order.isEmpty else { return nil }
        let merged = order.compactMap { byIndex[$0] }.map { JSONValue.object($0) }
        return JSONValue.array(merged).encodedString()
    }
}
