//
//  AgentEngine.swift
//  Isle
//

import Foundation
import Roboport

/// Runs a turn against the model and returns the assistant's answer.
///
/// This replaces the old `codex exec` subprocess: the agent loop, the tools, and
/// the model call all run in-process now, so there is no CLI to find on `PATH`,
/// no isolated `CODEX_HOME` to maintain, and no localhost MCP hop for Isle's own
/// tools. Context is still carried by us and replayed each turn — the engine is
/// handed the history rather than resuming a server-side session.
struct AgentEngine {
    /// One message in the running conversation.
    struct Turn: Sendable {
        enum Role: String, Sendable { case user, assistant }
        let role: Role
        let text: String

        init(role: Role, text: String) {
            self.role = role
            self.text = text
        }
    }

    /// A tool call surfaced live so the pill can show what's running. `key` is
    /// the tool name, mapped to a label + icon by `ToolPresentation`.
    enum ToolEvent: Sendable {
        case begin(id: String, key: String)
        case end(id: String)
    }

    /// A failed turn, reduced to a short line the pill can show. The underlying
    /// error is logged, never displayed.
    enum EngineError: LocalizedError, Equatable {
        case notConfigured  // no API key in the keychain or environment
        case notAuthorized  // the provider rejected the key
        case usageLimit  // out of credit, or rate limited
        case serviceUnavailable  // network down, or the provider is 5xx
        case timedOut  // the turn outlasted its cap
        case emptyResponse  // finished cleanly but said nothing
        case failed  // anything else

        var errorDescription: String? {
            switch self {
            case .notConfigured: "No API key set"
            case .notAuthorized: "API key rejected"
            case .usageLimit: "Out of credit"
            case .serviceUnavailable: "Can't reach the model"
            case .timedOut: "That took too long"
            case .emptyResponse: "Nothing to say"
            case .failed: "Something went wrong"
            }
        }

        /// Maps a thrown error onto the case the pill should show.
        static func classify(_ error: Error) -> EngineError {
            if let engine = error as? EngineError { return engine }
            if error is CancellationError { return .timedOut }
            if let agent = error as? AgentError {
                switch agent {
                case .iterationLimit: return .timedOut
                case .unknownTool: return .failed
                }
            }
            guard let model = error as? ModelError else { return .failed }
            switch model {
            case .http(let status, _):
                switch status {
                case 401, 403: return .notAuthorized
                case 402, 429: return .usageLimit
                case 500...599: return .serviceUnavailable
                default: return .failed
                }
            case .truncatedStream: return .serviceUnavailable
            case .invalidResponse: return .failed
            }
        }
    }

    private let agent: Agent
    private let timeout: TimeInterval

    /// - Parameters:
    ///   - systemPrompt: Isle's persona. Tool-use guidance is appended, so the
    ///     persona stays the caller's to own.
    ///   - tools: Isle's own tools (reminders, calendar, mail, …) on top of the
    ///     shell and web search.
    init(
        apiKey: String,
        model: String,
        thinking: ThinkingLevel,
        systemPrompt: String,
        tools: [any Roboport.Tool],
        cwd: String,
        timeout: TimeInterval
    ) {
        let openRouter = OpenRouter(
            model, apiKey: apiKey, thinking: thinking, title: "isle")
        self.agent = Agent(
            config: AgentConfig(
                model: openRouter,
                system: "\(systemPrompt)\n\n\(Harness.toolGuidance)",
                toolProviders: [StaticToolProvider(Harness.tools() + tools)],
                cwd: cwd))
        self.timeout = timeout
    }

    /// Runs one turn and returns the answer.
    ///
    /// The whole turn is capped: unlike the old subprocess there is no shell to
    /// kill, so the cap is a task that races the turn and cancels it, which
    /// unwinds the model stream and any running tool.
    func send(
        _ prompt: String,
        history: [Turn],
        onTool: @escaping @Sendable (ToolEvent) -> Void
    ) async throws -> String {
        let session = agent.session(history: history.map(\.message))

        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                var answer = ""
                for try await event in await session.send(prompt) {
                    switch event {
                    case .text(let text):
                        answer += answer.isEmpty ? text : "\n\(text)"
                    case .toolCall(let id, let name, _):
                        onTool(.begin(id: id, key: name))
                    case .toolResult(let id, _, _, _):
                        onTool(.end(id: id))
                    default:
                        break
                    }
                }
                let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { throw EngineError.emptyResponse }
                return trimmed
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw EngineError.timedOut
            }

            // Whichever finishes first wins; cancelling the group tears down the
            // loser, so a completed turn does not leave the timer running.
            guard let result = try await group.next() else { throw EngineError.failed }
            group.cancelAll()
            return result
        }
    }
}

extension AgentEngine.Turn {
    fileprivate var message: Message {
        Message(role: role == .user ? .user : .assistant, text: text)
    }
}
