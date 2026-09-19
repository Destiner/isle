//
//  IsleTests.swift
//  IsleTests
//
//  Created by Timur Badretdinov on 29/06/2026.
//

import Foundation
import MCP
import Robo
import Testing

@testable import Isle

/// Covers `AgentEngine.EngineError.classify` — the mapping that turns a failed
/// turn into the short line the pill shows. The pill has one line and no way to
/// ask a question, so a wrong mapping is the difference between "API key
/// rejected" (actionable) and "Something went wrong" (not).
struct EngineErrorClassifyTests {
    typealias E = AgentEngine.EngineError

    @Test func authFailuresAreDistinctFromBilling() {
        #expect(E.classify(ModelError.http(status: 401, body: "")) == .notAuthorized)
        #expect(E.classify(ModelError.http(status: 403, body: "")) == .notAuthorized)
        // 402 and 429 both mean "the key is fine, you just can't spend right now".
        #expect(E.classify(ModelError.http(status: 402, body: "")) == .usageLimit)
        #expect(E.classify(ModelError.http(status: 429, body: "")) == .usageLimit)
    }

    @Test func serverFaultsReadAsUnreachable() {
        #expect(E.classify(ModelError.http(status: 500, body: "")) == .serviceUnavailable)
        #expect(E.classify(ModelError.http(status: 503, body: "")) == .serviceUnavailable)
        // A stream that stops mid-answer is a transport fault, not a bad request.
        #expect(E.classify(ModelError.truncatedStream) == .serviceUnavailable)
    }

    @Test func unclassifiedHTTPFallsBackToFailed() {
        #expect(E.classify(ModelError.http(status: 400, body: "")) == .failed)
        #expect(E.classify(ModelError.http(status: 404, body: "")) == .failed)
        #expect(E.classify(ModelError.invalidResponse("nonsense")) == .failed)
    }

    @Test func runawayToolLoopsReadAsATimeout() {
        // Both mean "it never got to an answer", which is what the user sees.
        #expect(E.classify(AgentError.iterationLimit(16)) == .timedOut)
        #expect(E.classify(CancellationError()) == .timedOut)
    }

    @Test func anUnknownToolIsAnInternalFault() {
        #expect(E.classify(AgentError.unknownTool("nope")) == .failed)
    }

    @Test func anEngineErrorPassesThroughUnchanged() {
        #expect(E.classify(E.notConfigured) == .notConfigured)
        #expect(E.classify(E.emptyResponse) == .emptyResponse)
    }

    @Test func unrecognisedErrorsDegradeToFailed() {
        struct Weird: Error {}
        #expect(E.classify(Weird()) == .failed)
    }

    @Test func everyCaseHasADisplayString() {
        let cases: [E] = [
            .notConfigured, .notAuthorized, .usageLimit, .serviceUnavailable,
            .timedOut, .emptyResponse, .failed,
        ]
        for value in cases {
            #expect(value.errorDescription?.isEmpty == false)
        }
    }
}

/// The bridge that exposes Isle's MCP-declared tools to the agent in-process.
struct IsleToolBridgeTests {
    @Test func wrapsEveryDeclaredToolWithItsSchema() {
        let tools = ReminderTools(service: RemindersService()).agentTools()
        #expect(tools.count == ReminderTools.tools.count)

        let names = Set(tools.map(\.name))
        #expect(names == Set(ReminderTools.tools.map(\.name)))

        // The schema has to survive the bridge, or the model calls tools blind.
        let search = tools.first { $0.name == "search_reminders" }
        #expect(search?.inputSchema["type"]?.stringValue == "object")
        #expect(search?.inputSchema["properties"]?["query"] != nil)
    }

    @Test func disabledProvidersContributeNoTools() {
        #expect(IsleToolSet.tools(from: IsleToolSet.Providers()).isEmpty)
    }

    @Test func enabledProvidersAreMerged() {
        let providers = IsleToolSet.Providers(
            reminders: ReminderTools(service: RemindersService()),
            notes: NotesTools(service: NotesService()))
        let names = Set(IsleToolSet.tools(from: providers).map(\.name))
        #expect(names.isSuperset(of: Set(ReminderTools.tools.map(\.name))))
        #expect(names.isSuperset(of: Set(NotesTools.tools.map(\.name))))
    }
}
