import XCTest

@testable import Robo

/// Builds the SSE chunks a chat-completions provider would stream.
enum Chunk {
    static func text(_ value: String) -> JSONValue {
        .object(["choices": .array([.object(["delta": .object(["content": .string(value)])])])])
    }

    static func reasoning(_ value: String) -> JSONValue {
        .object(["choices": .array([.object(["delta": .object(["reasoning": .string(value)])])])])
    }

    static func stop(_ reason: String = "stop") -> JSONValue {
        .object([
            "choices": .array([
                .object(["delta": .object([:]), "finish_reason": .string(reason)])
            ])
        ])
    }

    static func toolCall(
        index: Int = 0, id: String, name: String, arguments: String
    ) -> JSONValue {
        .object([
            "choices": .array([
                .object([
                    "delta": .object([
                        "tool_calls": .array([
                            .object([
                                "index": .number(Double(index)),
                                "id": .string(id),
                                "function": .object([
                                    "name": .string(name),
                                    "arguments": .string(arguments),
                                ]),
                            ])
                        ])
                    ])
                ])
            ])
        ])
    }
}

func collect(_ model: any Model, _ messages: [Message], tools: [any Tool] = []) async throws
    -> [ModelStreamEvent]
{
    var events: [ModelStreamEvent] = []
    for try await event in model.streamMessage(
        CreateMessageParams(messages: messages, tools: tools))
    {
        events.append(event)
    }
    return events
}

final class OpenRouterTests: XCTestCase {
    private func makeModel(
        _ transport: StubTransport, thinking: ThinkingLevel = .medium
    ) -> OpenRouter {
        OpenRouter(
            "openai/gpt-5.6-luna", apiKey: "test-key", thinking: thinking,
            referer: "https://example.com", title: "isle", transport: transport)
    }

    func testSendsAttributionHeadersAndModel() async throws {
        let transport = StubTransport()
        transport.enqueueStream([Chunk.text("hi"), Chunk.stop()])

        _ = try await collect(makeModel(transport), [Message(role: .user, text: "hello")])

        let capture = try XCTUnwrap(transport.captures.first)
        XCTAssertEqual(capture.url, "https://openrouter.ai/api/v1/chat/completions")
        XCTAssertEqual(capture.headers["authorization"], "Bearer test-key")
        XCTAssertEqual(capture.headers["http-referer"], "https://example.com")
        XCTAssertEqual(capture.headers["x-title"], "isle")
        XCTAssertEqual(capture.body["model"]?.stringValue, "openai/gpt-5.6-luna")
    }

    func testMapsEveryThinkingLevelOntoReasoningEffort() async throws {
        for level in [ThinkingLevel.minimal, .low, .medium, .high, .xhigh] {
            let transport = StubTransport()
            transport.enqueueStream([Chunk.text("ok"), Chunk.stop()])
            _ = try await collect(
                makeModel(transport, thinking: level), [Message(role: .user, text: "hi")])
            XCTAssertEqual(
                transport.lastBody["reasoning"], .object(["effort": .string(level.rawValue)]),
                "level \(level.rawValue)")
        }
    }

    func testOmitsReasoningWhenThinkingIsOff() async throws {
        let transport = StubTransport()
        transport.enqueueStream([Chunk.text("ok"), Chunk.stop()])
        _ = try await collect(
            makeModel(transport, thinking: .off), [Message(role: .user, text: "hi")])
        XCTAssertNil(transport.lastBody["reasoning"])
    }

    func testStreamsReasoningAsThinkingDeltas() async throws {
        let transport = StubTransport()
        transport.enqueueStream([
            Chunk.reasoning("let me "), Chunk.reasoning("think"), Chunk.text("answer"),
            Chunk.stop(),
        ])

        let events = try await collect(makeModel(transport), [Message(role: .user, text: "hi")])

        let deltas = events.compactMap { event -> String? in
            if case .thinkingDelta(let text) = event { return text }
            return nil
        }
        XCTAssertEqual(deltas, ["let me ", "think"])

        let ended = events.contains { event in
            if case .thinkingEnd(let text, _) = event { return text == "let me think" }
            return false
        }
        XCTAssertTrue(ended)
    }

    func testMergesReasoningDetailsByIndex() async throws {
        let transport = StubTransport()
        transport.enqueueStream([
            .object([
                "choices": .array([
                    .object([
                        "delta": .object([
                            "reasoning": .string("a"),
                            "reasoning_details": .array([
                                .object([
                                    "type": .string("reasoning.summary"),
                                    "index": .number(0), "summary": .string("a"),
                                ])
                            ]),
                        ])
                    ])
                ])
            ]),
            .object([
                "choices": .array([
                    .object([
                        "delta": .object([
                            "reasoning": .string("b"),
                            "reasoning_details": .array([
                                .object(["index": .number(0), "summary": .string("b")])
                            ]),
                        ])
                    ])
                ])
            ]),
            Chunk.text("done"), Chunk.stop(),
        ])

        let events = try await collect(makeModel(transport), [Message(role: .user, text: "hi")])

        let redacted = events.compactMap { event -> String? in
            if case .thinkingEnd(_, let data) = event { return data }
            return nil
        }.first
        let parsed = try XCTUnwrap(JSONValue.parse(try XCTUnwrap(redacted))?.arrayValue)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0]["summary"]?.stringValue, "ab")
        XCTAssertEqual(parsed[0]["type"]?.stringValue, "reasoning.summary")
    }

    func testReplaysReasoningDetailsOnALaterTurn() async throws {
        let transport = StubTransport()
        transport.enqueueStream([Chunk.text("ok"), Chunk.stop()])

        let details = JSONValue.array([
            .object(["type": .string("reasoning.encrypted"), "index": .number(0)])
        ])
        let history: [Message] = [
            Message(role: .user, text: "what time is it"),
            Message(
                role: .assistant,
                content: [
                    .thinking(text: "need the clock", redactedData: details.encodedString()),
                    .toolCall(id: "call_1", name: "bash", input: .object(["command": "date"])),
                ]),
            Message(
                role: .tool,
                content: [.toolResult(id: "call_1", name: "bash", output: "12:00")]),
        ]

        _ = try await collect(makeModel(transport), history)

        let messages = try XCTUnwrap(transport.lastBody["messages"]?.arrayValue)
        XCTAssertEqual(messages[1]["reasoning_details"], details)
        XCTAssertEqual(messages[1]["content"], .null)
        XCTAssertEqual(messages[2]["role"]?.stringValue, "tool")
        XCTAssertEqual(messages[2]["tool_call_id"]?.stringValue, "call_1")
    }

    func testDropsAnUnparseableReasoningBlob() async throws {
        let transport = StubTransport()
        transport.enqueueStream([Chunk.text("ok"), Chunk.stop()])

        _ = try await collect(
            makeModel(transport),
            [
                Message(role: .user, text: "hi"),
                Message(
                    role: .assistant,
                    content: [
                        .thinking(text: "hmm", redactedData: "not-json"), .text("hello"),
                    ]),
            ])

        let messages = try XCTUnwrap(transport.lastBody["messages"]?.arrayValue)
        XCTAssertNil(messages[1]["reasoning_details"])
        XCTAssertEqual(messages[1]["content"]?.stringValue, "hello")
    }

    func testAssemblesStreamedToolCallArguments() async throws {
        let transport = StubTransport()
        transport.enqueueStream([
            Chunk.toolCall(id: "call_1", name: "bash", arguments: "{\"comm"),
            Chunk.toolCall(id: "", name: "", arguments: "and\":\"ls\"}"),
            Chunk.stop("tool_calls"),
        ])

        let events = try await collect(makeModel(transport), [Message(role: .user, text: "hi")])

        let call = events.compactMap { event -> (String, String, JSONValue)? in
            if case .toolCall(let id, let name, let input) = event { return (id, name, input) }
            return nil
        }.first
        let unwrapped = try XCTUnwrap(call)
        XCTAssertEqual(unwrapped.0, "call_1")
        XCTAssertEqual(unwrapped.1, "bash")
        XCTAssertEqual(unwrapped.2["command"]?.stringValue, "ls")

        let stop = events.compactMap { event -> StopReason? in
            if case .messageEnd(_, let reason, _) = event { return reason }
            return nil
        }.first
        XCTAssertEqual(stop, .toolUse)
    }

    func testThrowsWhenTheStreamEndsWithoutAFinishReason() async {
        let transport = StubTransport()
        transport.enqueueStream([Chunk.text("half an ans")])

        do {
            _ = try await collect(makeModel(transport), [Message(role: .user, text: "hi")])
            XCTFail("expected a truncated-stream error")
        } catch {
            XCTAssertEqual(error as? ModelError, .truncatedStream)
        }
    }

    func testSurfacesAnHTTPError() async {
        let model = OpenRouter(
            "openai/gpt-5.6-luna", apiKey: "k", transport: FailingTransport(status: 401))
        do {
            _ = try await collect(model, [Message(role: .user, text: "hi")])
            XCTFail("expected an HTTP error")
        } catch {
            guard case .http(let status, _)? = error as? ModelError else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertEqual(status, 401)
        }
    }

    func testWebSearchReadsCitations() async throws {
        let transport = StubTransport()
        transport.enqueueSend(
            .object([
                "choices": .array([
                    .object([
                        "message": .object([
                            "content": .string("Two results."),
                            "annotations": .array([
                                .object([
                                    "type": .string("url_citation"),
                                    "url_citation": .object([
                                        "url": .string("https://a.example"),
                                        "title": .string("A"),
                                    ]),
                                ]),
                                .object([
                                    "type": .string("url_citation"),
                                    "url_citation": .object([
                                        "url": .string("https://a.example"),
                                        "title": .string("dupe"),
                                    ]),
                                ]),
                            ]),
                        ])
                    ])
                ])
            ]))

        let hits = try await makeModel(transport).searchWeb("robo", maxResults: 5)
        XCTAssertEqual(hits.count, 1, "duplicate urls should collapse")
        XCTAssertEqual(hits[0].url, "https://a.example")
        XCTAssertEqual(transport.lastBody["plugins"]?.arrayValue?.first?["id"]?.stringValue, "web")
    }

    func testWebSearchFallsBackToProse() async throws {
        let transport = StubTransport()
        transport.enqueueSend(
            .object([
                "choices": .array([.object(["message": .object(["content": .string("The answer.")])])])
            ]))

        let hits = try await makeModel(transport).searchWeb("robo", maxResults: nil)
        XCTAssertEqual(hits, [SearchHit(title: "Web search answer", text: "The answer.")])
    }
}

final class OpenAIModelTests: XCTestCase {
    func testClampsXHighToHigh() async throws {
        let transport = StubTransport()
        transport.enqueueStream([Chunk.text("ok"), Chunk.stop()])
        let model = OpenAI("gpt-5.5", apiKey: "k", thinking: .xhigh, transport: transport)
        _ = try await collect(model, [Message(role: .user, text: "hi")])
        XCTAssertEqual(transport.lastBody["reasoning_effort"]?.stringValue, "high")
    }

    func testPassesOtherLevelsThrough() async throws {
        let transport = StubTransport()
        transport.enqueueStream([Chunk.text("ok"), Chunk.stop()])
        let model = OpenAI("gpt-5.5", apiKey: "k", thinking: .medium, transport: transport)
        _ = try await collect(model, [Message(role: .user, text: "hi")])
        XCTAssertEqual(transport.lastBody["reasoning_effort"]?.stringValue, "medium")
    }
}
