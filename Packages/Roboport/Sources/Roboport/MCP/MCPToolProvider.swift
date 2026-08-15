import Foundation
import MCP
import System

/// Exposes an external MCP server's tools to the agent.
///
/// Connects lazily on the first `tools()` call and holds the connection for the
/// provider's lifetime, so a long-lived agent pays the handshake once. Tool
/// names are optionally prefixed, since two servers can and do ship tools with
/// the same name.
public actor MCPToolProvider: ToolProvider {
    public enum Transport: Sendable {
        /// Streamable HTTP (or SSE) endpoint.
        case http(URL)
        /// A server spawned as a child process speaking stdio.
        case stdio(executable: String, arguments: [String])
    }

    private let clientName: String
    private let clientVersion: String
    private let transport: Transport
    private let prefix: String?
    private var client: Client?
    private var cached: [any Tool]?

    public init(
        name: String,
        version: String = "1.0.0",
        transport: Transport,
        toolNamePrefix: String? = nil
    ) {
        self.clientName = name
        self.clientVersion = version
        self.transport = transport
        self.prefix = toolNamePrefix
    }

    public func tools() async throws -> [any Tool] {
        if let cached { return cached }

        let client = try await connect()
        var discovered: [any Tool] = []
        var cursor: String?

        // Servers may paginate; keep asking until they stop handing back a cursor.
        repeat {
            let page = try await client.listTools(cursor: cursor)
            for tool in page.tools {
                discovered.append(
                    MCPTool(
                        remoteName: tool.name,
                        exposedName: prefix.map { "\($0)_\(tool.name)" } ?? tool.name,
                        description: tool.description ?? "",
                        inputSchema: JSONValue(mcp: tool.inputSchema),
                        client: client))
            }
            cursor = page.nextCursor
        } while cursor != nil

        cached = discovered
        return discovered
    }

    private func connect() async throws -> Client {
        if let client { return client }
        let client = Client(name: clientName, version: clientVersion)
        switch transport {
        case .http(let url):
            _ = try await client.connect(transport: HTTPClientTransport(endpoint: url))
        case .stdio(let executable, let arguments):
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let input = Pipe()
            let output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            try process.run()
            _ = try await client.connect(
                transport: StdioTransport(
                    input: FileDescriptor(rawValue: output.fileHandleForReading.fileDescriptor),
                    output: FileDescriptor(rawValue: input.fileHandleForWriting.fileDescriptor)))
        }
        self.client = client
        return client
    }

    public func disconnect() async {
        await client?.disconnect()
        client = nil
        cached = nil
    }
}

/// One tool on a connected MCP server.
private struct MCPTool: Tool {
    let remoteName: String
    let exposedName: String
    let toolDescription: String
    let schema: JSONValue
    let client: Client

    init(
        remoteName: String, exposedName: String, description: String, inputSchema: JSONValue,
        client: Client
    ) {
        self.remoteName = remoteName
        self.exposedName = exposedName
        self.toolDescription = description
        self.schema = inputSchema
        self.client = client
    }

    var name: String { exposedName }
    var description: String { toolDescription }
    var inputSchema: JSONValue { schema }

    func execute(_ input: JSONValue, context: ToolContext) async throws -> String {
        let arguments = (input.objectValue ?? [:]).mapValues(\.mcpValue)
        let result = try await client.callTool(name: remoteName, arguments: arguments)
        return MCPBridge.output(content: result.content, isError: result.isError)
    }
}
