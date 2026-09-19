import XCTest

@testable import Roboport

/// Records every tool call and returns canned output.
final class RecordingTool: Tool, @unchecked Sendable {
    let name: String
    let description = "test tool"
    let inputSchema: JSONValue = .object(["type": .string("object")])

    private let lock = NSLock()
    private var _calls: [JSONValue] = []
    private let output: String
    private let failure: Error?

    init(name: String = "echo", output: String = "tool output", failure: Error? = nil) {
        self.name = name
        self.output = output
        self.failure = failure
    }

    var calls: [JSONValue] {
        lock.lock()
        defer { lock.unlock() }
        return _calls
    }

    func execute(_ input: JSONValue, context: ToolContext) async throws -> String {
        lock.lock()
        _calls.append(input)
        lock.unlock()
        if let failure { throw failure }
        return output
    }
}

struct TestError: LocalizedError {
    let errorDescription: String? = "the tool exploded"
}

final class AgentTests: XCTestCase {
    private func makeSession(
        transport: StubTransport, tools: [any Tool] = [], maxIterations: Int = 16
    ) -> Session {
        let model = OpenRouter("m", apiKey: "k", thinking: .off, transport: transport)
        return Session(
            config: AgentConfig(
                model: model, system: "You are a test.",
                toolProviders: [StaticToolProvider(tools)],
                cwd: FileManager.default.temporaryDirectory.path,
                maxIterations: maxIterations, maxRetries: 0))
    }

    private func drain(_ session: Session, _ prompt: String) async throws -> [TurnEvent] {
        var events: [TurnEvent] = []
        for try await event in await session.send(prompt) { events.append(event) }
        return events
    }

    func testPlainTurnRecordsHistory() async throws {
        let transport = StubTransport()
        transport.enqueueStream([Chunk.text("Canberra."), Chunk.stop()])
        let session = makeSession(transport: transport)

        let events = try await drain(session, "capital of Australia?")

        XCTAssertTrue(
            events.contains {
                if case .text(let value) = $0 { return value == "Canberra." }
                return false
            })

        let history = await session.messages
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(history[0].role, .user)
        XCTAssertEqual(history[1].role, .assistant)
        XCTAssertEqual(history[1].text, "Canberra.")
    }

    func testSendsSystemPromptWithoutStoringItInHistory() async throws {
        let transport = StubTransport()
        transport.enqueueStream([Chunk.text("ok"), Chunk.stop()])
        let session = makeSession(transport: transport)

        _ = try await drain(session, "hi")

        let wire = try XCTUnwrap(transport.lastBody["messages"]?.arrayValue)
        XCTAssertEqual(wire[0]["role"]?.stringValue, "system")
        XCTAssertEqual(wire[0]["content"]?.stringValue, "You are a test.")

        let history = await session.messages
        XCTAssertFalse(history.contains { $0.role == .system })
    }

    func testRunsAToolAndFeedsTheResultBack() async throws {
        let transport = StubTransport()
        transport.enqueueStream([
            Chunk.toolCall(id: "c1", name: "echo", arguments: "{\"x\":1}"),
            Chunk.stop("tool_calls"),
        ])
        transport.enqueueStream([Chunk.text("done"), Chunk.stop()])

        let tool = RecordingTool()
        let session = makeSession(transport: transport, tools: [tool])

        let events = try await drain(session, "use the tool")

        let activity = events.compactMap { event -> String? in
            switch event {
            case .modelRequestStarted(let iteration, let attempt):
                return "model.begin \(iteration).\(attempt)"
            case .modelRequestEnded(let iteration, let attempt, let durationMs, let outcome):
                XCTAssertGreaterThanOrEqual(durationMs, 0)
                return "model.end \(iteration).\(attempt) \(outcome)"
            case .toolCall(let id, _, _): return "tool.begin \(id)"
            case .toolResult(let id, _, _, _): return "tool.end \(id)"
            default: return nil
            }
        }
        XCTAssertEqual(
            activity,
            [
                "model.begin 1.1", "model.end 1.1 completed",
                "tool.begin c1", "tool.end c1",
                "model.begin 2.1", "model.end 2.1 completed",
            ])

        XCTAssertEqual(tool.calls.count, 1)
        XCTAssertEqual(tool.calls[0]["x"]?.intValue, 1)

        XCTAssertTrue(
            events.contains {
                if case .toolResult(_, _, let output, let isError) = $0 {
                    return output == "tool output" && !isError
                }
                return false
            })

        // Second request must carry the assistant tool_call and the tool result.
        let second = try XCTUnwrap(transport.captures.last?.body["messages"]?.arrayValue)
        XCTAssertEqual(second.count, 4)  // system, user, assistant, tool
        XCTAssertNotNil(second[2]["tool_calls"])
        XCTAssertEqual(second[3]["role"]?.stringValue, "tool")
        XCTAssertEqual(second[3]["content"]?.stringValue, "tool output")
    }

    func testAToolFailureIsReportedToTheModelRatherThanEndingTheTurn() async throws {
        let transport = StubTransport()
        transport.enqueueStream([
            Chunk.toolCall(id: "c1", name: "echo", arguments: "{}"),
            Chunk.stop("tool_calls"),
        ])
        transport.enqueueStream([Chunk.text("recovered"), Chunk.stop()])

        let tool = RecordingTool(failure: TestError())
        let session = makeSession(transport: transport, tools: [tool])

        let events = try await drain(session, "go")

        let failed = events.contains {
            if case .toolResult(_, _, let output, let isError) = $0 {
                return isError && output.contains("the tool exploded")
            }
            return false
        }
        XCTAssertTrue(failed, "the failure should reach the model as an error result")
        XCTAssertTrue(
            events.contains {
                if case .text(let value) = $0 { return value == "recovered" }
                return false
            })
    }

    func testAnUnknownToolIsReportedInBand() async throws {
        let transport = StubTransport()
        transport.enqueueStream([
            Chunk.toolCall(id: "c1", name: "nope", arguments: "{}"),
            Chunk.stop("tool_calls"),
        ])
        transport.enqueueStream([Chunk.text("ok"), Chunk.stop()])

        let session = makeSession(transport: transport, tools: [RecordingTool()])
        let events = try await drain(session, "go")

        XCTAssertTrue(
            events.contains {
                if case .toolResult(_, _, let output, let isError) = $0 {
                    return isError && output.contains("nope")
                }
                return false
            })
    }

    func testStopsAtTheIterationLimit() async {
        let transport = StubTransport()
        for _ in 0..<4 {
            transport.enqueueStream([
                Chunk.toolCall(id: "c", name: "echo", arguments: "{}"),
                Chunk.stop("tool_calls"),
            ])
        }
        let session = makeSession(
            transport: transport, tools: [RecordingTool()], maxIterations: 3)

        do {
            _ = try await drain(session, "loop forever")
            XCTFail("expected the iteration limit to trip")
        } catch {
            guard case .iterationLimit(let limit)? = error as? AgentError else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertEqual(limit, 3)
        }
    }

    func testRetriesATransientFailureThenSucceeds() async throws {
        let transport = FailingTransport(status: 429, succeedAfter: 2)
        let model = OpenRouter("m", apiKey: "k", transport: transport)
        let session = Session(
            config: AgentConfig(
                model: model, system: "s", toolProviders: [], maxIterations: 4, maxRetries: 2))

        var texts: [String] = []
        var starts: [Int] = []
        var outcomes: [String] = []
        for try await event in await session.send("hi") {
            if case .text(let value) = event { texts.append(value) }
            if case .modelRequestStarted(let iteration, let attempt) = event {
                XCTAssertEqual(iteration, 1)
                starts.append(attempt)
            }
            if case .modelRequestEnded(_, _, let durationMs, let outcome) = event {
                XCTAssertGreaterThanOrEqual(durationMs, 0)
                outcomes.append(outcome)
            }
        }

        XCTAssertEqual(starts, [1, 2, 3])
        XCTAssertEqual(outcomes, ["failed", "failed", "completed"])
        XCTAssertEqual(texts, ["recovered"])
        XCTAssertEqual(transport.attempts, 3, "two failures then a success")
    }

    func testDoesNotRetryANonRetryableFailure() async {
        let transport = FailingTransport(status: 401)
        let model = OpenRouter("m", apiKey: "k", transport: transport)
        let session = Session(
            config: AgentConfig(model: model, system: "s", maxIterations: 4, maxRetries: 3))

        do {
            for try await _ in await session.send("hi") {}
            XCTFail("expected the 401 to surface")
        } catch {
            XCTAssertEqual(transport.attempts, 1, "a 401 must not be retried")
        }
    }

    func testHistoryCanBeSeededAndCleared() async throws {
        let transport = StubTransport()
        transport.enqueueStream([Chunk.text("ok"), Chunk.stop()])
        let session = makeSession(transport: transport)

        await session.setHistory([
            Message(role: .user, text: "earlier"),
            Message(role: .assistant, text: "reply"),
        ])
        _ = try await drain(session, "follow up")

        let wire = try XCTUnwrap(transport.lastBody["messages"]?.arrayValue)
        XCTAssertEqual(wire.count, 4)  // system + 2 seeded + new user
        XCTAssertEqual(wire[1]["content"]?.stringValue, "earlier")

        await session.clearHistory()
        let cleared = await session.messages
        XCTAssertTrue(cleared.isEmpty)
    }
}
