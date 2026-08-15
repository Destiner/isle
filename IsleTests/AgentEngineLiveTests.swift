//
//  AgentEngineLiveTests.swift
//  IsleTests
//

import Foundation
import MCP
import Roboport
import Testing

@testable import Isle

/// Exercises the real engine against the real provider, including the bridge
/// that exposes Isle's MCP-declared tools in-process.
///
/// Skipped unless `ISLE_OPENROUTER_KEY` is set, so the normal test run stays
/// offline and free. Deliberately uses a synthetic tool rather than the
/// reminder/calendar/mail providers: those would trigger TCC prompts and touch
/// the user's real data.
struct AgentEngineLiveTests {
    private static var apiKey: String? {
        let value = ProcessInfo.processInfo.environment["ISLE_OPENROUTER_KEY"]
        return (value?.isEmpty == false) ? value : nil
    }

    /// An Isle-shaped tool: declared as an MCP `Tool`, dispatched in-process,
    /// bridged through exactly the path the real providers use.
    private static func probeTool(
        recorder: @escaping @Sendable (String) -> Void
    ) -> any Roboport.Tool {
        let declaration = MCP.Tool(
            name: "get_desk_status",
            description:
                "Get the current status of the user's desk. Call this whenever the user asks about their desk.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "detail": [
                        "type": "string",
                        "description": "Optional level of detail.",
                    ]
                ],
            ])
        return MCPBridge.tool(declaration) { arguments in
            recorder(arguments["detail"]?.stringValue ?? "")
            return (
                [.text(text: "{\"tidy\":false,\"mugs\":3}", annotations: nil, _meta: nil)],
                nil
            )
        }
    }

    private static func makeEngine(key: String, tools: [any Roboport.Tool]) -> AgentEngine {
        AgentEngine(
            apiKey: key,
            model: Preferences().model,
            thinking: Preferences().thinking,
            systemPrompt: Preferences().systemPrompt,
            tools: tools,
            cwd: NSTemporaryDirectory(),
            timeout: 120)
    }

    @Test func answersAPlainQuestion() async throws {
        guard let key = Self.apiKey else { return }
        let engine = Self.makeEngine(key: key, tools: [])
        let answer = try await engine.send(
            "Reply with exactly the word: pong", history: [], onTool: { _ in })
        #expect(answer.lowercased().contains("pong"))
    }

    /// The important one: a tool declared the way Isle declares all six must be
    /// callable by the model, and its output must reach the answer.
    @Test func callsABridgedIsleTool() async throws {
        guard let key = Self.apiKey else { return }

        let calls = Locked<[String]>([])
        let engine = Self.makeEngine(
            key: key, tools: [Self.probeTool { detail in calls.mutate { $0.append(detail) } }])

        let events = Locked<[String]>([])
        let answer = try await engine.send(
            "How many mugs are on my desk right now? Use your tools.",
            history: [],
            onTool: { event in
                if case .begin(_, let key) = event { events.mutate { $0.append(key) } }
            })

        #expect(calls.value.count >= 1, "the model should have called the bridged tool")
        #expect(events.value.contains("get_desk_status"), "the pill needs the tool name")
        #expect(answer.contains("3"), "the tool's output should reach the answer: \(answer)")
    }

    /// History is replayed rather than resumed, so a follow-up only works if the
    /// prior turns actually reach the model.
    @Test func carriesHistoryIntoAFollowUp() async throws {
        guard let key = Self.apiKey else { return }
        let engine = Self.makeEngine(key: key, tools: [])
        let answer = try await engine.send(
            "What did I just say my favourite colour was?",
            history: [
                .init(role: .user, text: "My favourite colour is chartreuse."),
                .init(role: .assistant, text: "Noted — chartreuse."),
            ],
            onTool: { _ in })
        #expect(answer.lowercased().contains("chartreuse"))
    }

    @Test func aBadKeyIsReportedAsRejected() async throws {
        guard Self.apiKey != nil else { return }
        let engine = Self.makeEngine(key: "sk-or-v1-definitely-not-a-real-key", tools: [])
        await #expect(throws: Error.self) {
            _ = try await engine.send("hi", history: [], onTool: { _ in })
        }
    }
}

/// Minimal lock so the tool callbacks (which run off the test's task) can record
/// what happened without data races.
private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) { self.storage = value }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func mutate(_ body: (inout Value) -> Void) {
        lock.lock()
        body(&storage)
        lock.unlock()
    }
}
