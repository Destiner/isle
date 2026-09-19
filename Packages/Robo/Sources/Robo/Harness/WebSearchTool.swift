import Foundation

/// Web search, delegated to whatever the session's model provides.
public struct WebSearchTool: Tool {
    public let name = "web_search"
    public let description = """
        Search the web and return the most relevant results. Use this whenever the \
        answer depends on current or external information rather than something \
        you already know.
        """

    public let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "query": .object([
                "type": .string("string"),
                "description": .string("What to search for."),
            ]),
            "max_results": .object([
                "type": .string("number"),
                "description": .string("Optional cap on the number of results."),
            ]),
        ]),
        "required": .array([.string("query")]),
    ])

    private let defaultMaxResults: Int

    public init(defaultMaxResults: Int = 5) {
        self.defaultMaxResults = defaultMaxResults
    }

    public func execute(_ input: JSONValue, context: ToolContext) async throws -> String {
        guard let query = input["query"]?.stringValue, !query.isEmpty else {
            return "Error: `query` is required."
        }
        let limit = input["max_results"]?.intValue ?? defaultMaxResults
        let hits = try await context.searchWeb(query, limit)

        guard !hits.isEmpty else { return "No results." }

        return hits.map { hit in
            var line = hit.title
            if let url = hit.url { line += "\n\(url)" }
            if let text = hit.text, !text.isEmpty { line += "\n\(text)" }
            return line
        }.joined(separator: "\n\n")
    }
}
