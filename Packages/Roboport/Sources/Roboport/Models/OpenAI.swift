import Foundation

/// OpenAI's own chat-completions endpoint.
public final class OpenAI: OpenAICompatible, @unchecked Sendable {
    public init(
        _ modelName: String,
        apiKey: String,
        thinking: ThinkingLevel = .off,
        baseURL: String = "https://api.openai.com/v1",
        transport: any HTTPTransport = URLSessionTransport()
    ) {
        super.init(
            modelName: modelName, apiKey: apiKey, baseURL: baseURL,
            thinking: thinking, transport: transport)
    }

    /// Chat Completions caps `reasoning_effort` at `high`, so `xhigh` is clamped
    /// rather than passed through — sending it would error.
    public override func applyThinking(_ body: inout [String: JSONValue]) {
        guard thinking != .off else { return }
        body["reasoning_effort"] = .string(thinking == .xhigh ? "high" : thinking.rawValue)
    }

    public override func searchWeb(_ query: String, maxResults: Int?) async throws -> [SearchHit] {
        let body = JSONValue.object([
            "model": .string(modelName),
            "tools": .array([.object(["type": .string("web_search_preview")])]),
            "input": .string("Search the web for: \(query)"),
        ])

        let (status, data) = try await transport.send(
            makeRequest(path: "/responses", body: body, stream: false))
        guard (200...299).contains(status) else {
            throw ModelError.http(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }

        // Citations ride along as annotations on the output text items.
        var hits: [SearchHit] = []
        var seen = Set<String>()
        var answer = ""
        for item in JSONValue.parse(data)?["output"]?.arrayValue ?? [] {
            for content in item["content"]?.arrayValue ?? [] {
                if let text = content["text"]?.stringValue { answer += text }
                for annotation in content["annotations"]?.arrayValue ?? [] {
                    guard annotation["type"]?.stringValue == "url_citation",
                        let url = annotation["url"]?.stringValue,
                        !seen.contains(url)
                    else { continue }
                    seen.insert(url)
                    hits.append(SearchHit(title: annotation["title"]?.stringValue ?? url, url: url))
                }
            }
        }

        if hits.isEmpty {
            let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [] }
            return [SearchHit(title: "Web search answer", text: trimmed)]
        }

        if let maxResults { return Array(hits.prefix(maxResults)) }
        return hits
    }
}
