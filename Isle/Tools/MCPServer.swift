//
//  MCPServer.swift
//  Isle
//

import Foundation
import MCP
import NIOCore
import NIOHTTP1
import NIOPosix

/// A localhost MCP endpoint hosted inside Isle, so Codex can call Isle's own tools
/// (reminders and mail) over Streamable HTTP (`[mcp_servers.reminders] url` in
/// `CodexClient` — one server fronts every provider).
///
/// The MCP SDK's HTTP transport is framework-agnostic — it turns an `HTTPRequest`
/// into an `HTTPResponse` but doesn't listen on a socket — so this wraps it in a
/// small NIO HTTP/1.1 server, mirroring the SDK's own conformance harness (the
/// reference impl that passes MCP conformance). Each Codex `initialize` opens a
/// session with its own `StatefulHTTPServerTransport` + `Server`; the tools all
/// share one `RemindersService`. Because Isle is long-lived, the server stays up
/// across `codex exec` runs — no per-request process spawn.
///
/// EventKit runs in-process here, so the Reminders TCC grant attributes to Isle's
/// own signed identity (like the Reminders grant) rather than to a spawned helper.
actor MCPHTTPServer {
    private let host = "127.0.0.1"
    private let port: Int
    private let endpoint = "/mcp"
    private let reminderTools: ReminderTools?
    private let calendarTools: CalendarTools?
    private let notesTools: NotesTools?
    private let musicTools: MusicTools?
    private let mailTools: MailTools?
    private let browserTools: BrowserTools?

    private var group: MultiThreadedEventLoopGroup?
    private var channel: Channel?
    /// Live sessions, keyed by `MCP-Session-Id`. The `Server` is retained alongside
    /// its transport so its message-handling task keeps running.
    private var sessions: [String: (transport: StatefulHTTPServerTransport, server: Server)] = [:]

    init(port: Int, reminders: RemindersService?, calendar: CalendarService?, notes: NotesService?, music: MusicService?, mail: MailService?, browser: BrowserService?) {
        self.port = port
        self.reminderTools = reminders.map { ReminderTools(service: $0) }
        self.calendarTools = calendar.map { CalendarTools(service: $0) }
        self.notesTools = notes.map { NotesTools(service: $0) }
        self.musicTools = music.map { MusicTools(service: $0) }
        self.mailTools = mail.map { MailTools(service: $0) }
        self.browserTools = browser.map { BrowserTools(service: $0) }
    }

    var mcpEndpoint: String { endpoint }

    /// Binds the listener and serves until the channel closes (i.e. for the app's
    /// lifetime). Call from a detached task — this does not return under normal use.
    func start() async throws {
        // A pool, not a single loop: Codex's streamable-HTTP client opens several
        // connections in quick succession during the handshake (initialize, the
        // `notifications/initialized` POST, the long-lived GET SSE stream) and treats
        // *any* connection failure as fatal — dropping every tool this server exposes.
        // On one event loop those long-lived SSE streams starve the accept path, so a
        // freshly-opened connection can intermittently be refused. A small pool keeps
        // the acceptor loop free of per-connection work.
        let group = MultiThreadedEventLoopGroup(numberOfThreads: max(2, System.coreCount))
        self.group = group

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(HTTPHandler(app: self))
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        let channel = try await bindWithRetry(bootstrap)
        self.channel = channel
        Log.app("mcp.listening", ["port": port])
        try await channel.closeFuture.get()
    }

    /// Bind, retrying briefly on "address already in use". A quick relaunch can
    /// race the previous instance's shutdown, which still holds the listening
    /// socket for a moment — and `SO_REUSEADDR` (set above) only covers a socket
    /// in `TIME_WAIT`, not one a live process is still bound to. So back off and
    /// retry a few times; the old process releases the port as it exits.
    private func bindWithRetry(_ bootstrap: ServerBootstrap,
                               attempts: Int = 10,
                               delay: Duration = .milliseconds(300)) async throws -> Channel {
        for attempt in 1...attempts {
            do {
                return try await bootstrap.bind(host: host, port: port).get()
            } catch {
                guard Self.isAddressInUse(error), attempt < attempts else { throw error }
                Log.app("mcp.bind.retry", ["attempt": attempt, "port": port])
                try? await Task.sleep(for: delay)
            }
        }
        // Unreachable: the loop either returns a channel or throws on the last attempt.
        fatalError("bindWithRetry exited its loop")
    }

    private static func isAddressInUse(_ error: Error) -> Bool {
        (error as? IOError)?.errnoCode == EADDRINUSE
    }

    /// Routes a request to its session's transport, creating a session on `initialize`.
    /// Mirrors the SDK conformance server's routing (inlined `initialize` detection
    /// because the SDK's own classifier is `package`-level and not visible here).
    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        let sessionID = request.header(HTTPHeaderName.sessionID)

        if let sessionID, let session = sessions[sessionID] {
            let response = await session.transport.handleRequest(request)
            if request.method.uppercased() == "DELETE", response.statusCode == 200 {
                await session.transport.disconnect()
                sessions[sessionID] = nil
            }
            return response
        }

        if request.method.uppercased() == "POST", Self.isInitialize(request.body) {
            return await createSession(request)
        }

        if sessionID != nil {
            return .error(statusCode: 404, .invalidRequest("Not Found: session not found or expired"))
        }
        return .error(statusCode: 400, .invalidRequest("Bad Request: missing \(HTTPHeaderName.sessionID) header"))
    }

    private func createSession(_ request: HTTPRequest) async -> HTTPResponse {
        let sessionID = UUID().uuidString
        let transport = StatefulHTTPServerTransport(
            sessionIDGenerator: FixedSessionID(sessionID),
            validationPipeline: StandardValidationPipeline(validators: [
                OriginValidator.localhost(port: port),
                AcceptHeaderValidator(mode: .sseRequired),
                ContentTypeValidator(),
                ProtocolVersionValidator(),
                SessionValidator(),
            ]))
        let server = makeServer()
        do {
            try await server.start(transport: transport)
        } catch {
            await transport.disconnect()
            return .error(statusCode: 500, .internalError("Failed to start MCP session"))
        }
        sessions[sessionID] = (transport, server)

        let response = await transport.handleRequest(request)
        if case .error = response {
            await transport.disconnect()
            sessions[sessionID] = nil
        }
        return response
    }

    private func makeServer() -> Server {
        let server = Server(
            name: "isle-tools",
            version: "1.0.0",
            capabilities: .init(tools: .init(listChanged: false)))
        let reminderTools = self.reminderTools
        let calendarTools = self.calendarTools
        let notesTools = self.notesTools
        let musicTools = self.musicTools
        let mailTools = self.mailTools
        let browserTools = self.browserTools
        Task {
            await server.withMethodHandler(ListTools.self) { _ in
                var tools: [Tool] = []
                if reminderTools != nil { tools += ReminderTools.tools }
                if calendarTools != nil { tools += CalendarTools.tools }
                if notesTools != nil { tools += NotesTools.tools }
                if musicTools != nil { tools += MusicTools.tools }
                if mailTools != nil { tools += MailTools.tools }
                if browserTools != nil { tools += BrowserTools.tools }
                return .init(tools: tools)
            }
            await server.withMethodHandler(CallTool.self) { params in
                if let mailTools, MailTools.toolNames.contains(params.name) {
                    return await mailTools.call(name: params.name, arguments: params.arguments)
                }
                if let calendarTools, CalendarTools.toolNames.contains(params.name) {
                    return await calendarTools.call(name: params.name, arguments: params.arguments)
                }
                if let notesTools, NotesTools.toolNames.contains(params.name) {
                    return await notesTools.call(name: params.name, arguments: params.arguments)
                }
                if let musicTools, MusicTools.toolNames.contains(params.name) {
                    return await musicTools.call(name: params.name, arguments: params.arguments)
                }
                if let browserTools, BrowserTools.toolNames.contains(params.name) {
                    return await browserTools.call(name: params.name, arguments: params.arguments)
                }
                if let reminderTools {
                    return await reminderTools.call(name: params.name, arguments: params.arguments)
                }
                return .init(content: [.text(text: "Unknown tool: \(params.name)", annotations: nil, _meta: nil)], isError: true)
            }
        }
        return server
    }

    private static func isInitialize(_ body: Data?) -> Bool {
        guard let body,
            let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return false
        }
        return object["method"] as? String == "initialize"
    }
}

/// Fixed generator so a session's `Mcp-Session-Id` matches the key we route on.
private struct FixedSessionID: SessionIDGenerator {
    let id: String
    init(_ id: String) { self.id = id }
    func generateSessionID() -> String { id }
}

/// NIO adapter: converts NIO HTTP parts to/from the SDK's framework-agnostic
/// `HTTPRequest`/`HTTPResponse`, delegating all MCP logic to `MCPHTTPServer`.
/// Handles the SSE (`.stream`) response case that the stateful transport uses.
private nonisolated final class HTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let app: MCPHTTPServer
    private var head: HTTPRequestHead?
    private var body: ByteBuffer?

    init(app: MCPHTTPServer) { self.app = app }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            self.head = head
            self.body = context.channel.allocator.buffer(capacity: 0)
        case .body(var chunk):
            self.body?.writeBuffer(&chunk)
        case .end:
            guard let head = self.head else { return }
            let bodyBuffer = self.body
            self.head = nil
            self.body = nil
            nonisolated(unsafe) let ctx = context
            Task { await self.process(head: head, body: bodyBuffer, context: ctx) }
        }
    }

    private func process(head: HTTPRequestHead, body: ByteBuffer?, context: ChannelHandlerContext) async {
        let path = head.uri.split(separator: "?").first.map(String.init) ?? head.uri
        guard path == (await app.mcpEndpoint) else {
            write(.error(statusCode: 404, .invalidRequest("Not Found")), version: head.version, context: context)
            return
        }
        let response = await app.handle(makeRequest(head: head, body: body, path: path))
        write(response, version: head.version, context: context)
    }

    private func makeRequest(head: HTTPRequestHead, body: ByteBuffer?, path: String) -> HTTPRequest {
        var headers: [String: String] = [:]
        for (name, value) in head.headers {
            headers[name] = headers[name].map { "\($0), \(value)" } ?? value
        }
        let data = body.flatMap { buffer -> Data? in
            guard buffer.readableBytes > 0,
                let bytes = buffer.getBytes(at: 0, length: buffer.readableBytes) else { return nil }
            return Data(bytes)
        }
        return HTTPRequest(method: head.method.rawValue, headers: headers, body: data, path: path)
    }

    private func write(_ response: HTTPResponse, version: HTTPVersion, context: ChannelHandlerContext) {
        nonisolated(unsafe) let ctx = context
        let status = HTTPResponseStatus(statusCode: response.statusCode)
        let headers = response.headers

        if case .stream(let stream, _) = response {
            ctx.eventLoop.execute {
                var head = HTTPResponseHead(version: version, status: status)
                for (name, value) in headers { head.headers.add(name: name, value: value) }
                ctx.write(self.wrapOutboundOut(.head(head)), promise: nil)
                ctx.flush()
            }
            Task {
                do {
                    for try await chunk in stream {
                        ctx.eventLoop.execute {
                            var buffer = ctx.channel.allocator.buffer(capacity: chunk.count)
                            buffer.writeBytes(chunk)
                            ctx.writeAndFlush(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                        }
                    }
                } catch {}
                ctx.eventLoop.execute {
                    ctx.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
                }
            }
            return
        }

        let bodyData = response.bodyData
        ctx.eventLoop.execute {
            var head = HTTPResponseHead(version: version, status: status)
            for (name, value) in headers { head.headers.add(name: name, value: value) }
            ctx.write(self.wrapOutboundOut(.head(head)), promise: nil)
            if let bodyData {
                var buffer = ctx.channel.allocator.buffer(capacity: bodyData.count)
                buffer.writeBytes(bodyData)
                ctx.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
            }
            ctx.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
        }
    }
}
