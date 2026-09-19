import Foundation

/// What a caller observes while a turn runs.
public enum TurnEvent: Sendable {
    case modelRequestStarted(iteration: Int, attempt: Int)
    case modelRequestEnded(iteration: Int, attempt: Int, durationMs: Int, outcome: String)
    case textDelta(String)
    case text(String)
    case thinkingDelta(String)
    case thinking(String)
    case toolCall(id: String, name: String, input: JSONValue)
    case toolResult(id: String, name: String, output: String, isError: Bool)
    case turnEnd(usage: Usage)
}

public struct AgentConfig: Sendable {
    public var model: any Model
    public var system: String
    public var toolProviders: [any ToolProvider]
    public var cwd: String
    /// Cap on model round trips in one turn. Without it a model that keeps
    /// calling tools loops until the context runs out.
    public var maxIterations: Int
    /// How many times to retry a transient model failure before giving up.
    public var maxRetries: Int

    public init(
        model: any Model,
        system: String,
        toolProviders: [any ToolProvider] = [],
        cwd: String = FileManager.default.temporaryDirectory.path,
        maxIterations: Int = 16,
        maxRetries: Int = 2
    ) {
        self.model = model
        self.system = system
        self.toolProviders = toolProviders
        self.cwd = cwd
        self.maxIterations = maxIterations
        self.maxRetries = maxRetries
    }
}

public enum AgentError: LocalizedError {
    case iterationLimit(Int)
    case unknownTool(String)

    public var errorDescription: String? {
        switch self {
        case .iterationLimit(let limit):
            return "The agent kept calling tools past \(limit) steps without answering."
        case .unknownTool(let name):
            return "The model called a tool that isn't available: \(name)."
        }
    }
}

/// A conversation against one model with one tool set. Holds the message history
/// and runs turns against it; `send` mutates the history, so a session is not
/// safe to run two turns through at once.
public actor Session {
    private let config: AgentConfig
    private var history: [Message]
    private var resolvedTools: [String: any Tool]?

    public init(config: AgentConfig, history: [Message] = []) {
        self.config = config
        self.history = history
    }

    public var messages: [Message] { history }

    public func setHistory(_ messages: [Message]) {
        history = messages
    }

    public func clearHistory() {
        history = []
    }

    /// Resolve tool providers once per session. An MCP provider connects on this
    /// call, so it is deferred until the first turn rather than done at init.
    private func tools() async throws -> [String: any Tool] {
        if let resolvedTools { return resolvedTools }
        var map: [String: any Tool] = [:]
        for provider in config.toolProviders {
            for tool in try await provider.tools() {
                map[tool.name] = tool
            }
        }
        resolvedTools = map
        return map
    }

    /// Runs one turn: streams the model, executes any tools it calls, and feeds
    /// the results back until it answers. Cancelling the consuming task stops the
    /// turn — the history keeps whatever completed, so a cancelled turn does not
    /// corrupt the conversation.
    public func send(_ prompt: String) -> AsyncThrowingStream<TurnEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.runTurn(prompt, into: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func runTurn(
        _ prompt: String,
        into continuation: AsyncThrowingStream<TurnEvent, Error>.Continuation
    ) async throws {
        let toolMap = try await tools()
        let toolList = Array(toolMap.values)
        let context = ToolContext(cwd: config.cwd) { [config] query, maxResults in
            try await config.model.searchWeb(query, maxResults: maxResults)
        }

        history.append(Message(role: .user, text: prompt))
        var totalUsage = Usage()

        for iteration in 0..<config.maxIterations {
            try Task.checkCancellation()

            let params = CreateMessageParams(
                messages: [Message(role: .system, text: config.system)] + history,
                tools: toolList)

            var parts: [ContentPart] = []
            var calls: [(id: String, name: String, input: JSONValue)] = []
            var stopReason = StopReason.endTurn

            let stream = try await streamWithRetry(
                params, iteration: iteration + 1, into: continuation)
            for try await event in stream {
                try Task.checkCancellation()
                switch event {
                case .textDelta(let text):
                    continuation.yield(.textDelta(text))
                case .textEnd(let text):
                    parts.append(.text(text))
                    continuation.yield(.text(text))
                case .thinkingDelta(let text):
                    continuation.yield(.thinkingDelta(text))
                case .thinkingEnd(let text, let redacted):
                    parts.append(.thinking(text: text, redactedData: redacted))
                    continuation.yield(.thinking(text))
                case .toolCall(let id, let name, let input):
                    parts.append(.toolCall(id: id, name: name, input: input))
                    calls.append((id, name, input))
                case .messageEnd(_, let reason, let usage):
                    stopReason = reason
                    totalUsage.inputTokens += usage.inputTokens
                    totalUsage.outputTokens += usage.outputTokens
                }
            }

            if !parts.isEmpty {
                history.append(Message(role: .assistant, content: parts))
            }

            guard stopReason == .toolUse, !calls.isEmpty else {
                continuation.yield(.turnEnd(usage: totalUsage))
                return
            }

            var results: [ContentPart] = []
            for call in calls {
                try Task.checkCancellation()
                continuation.yield(.toolCall(id: call.id, name: call.name, input: call.input))

                let (output, isError) = await execute(call, tools: toolMap, context: context)
                results.append(
                    .toolResult(
                        id: call.id, name: call.name, output: output, isError: isError))
                continuation.yield(
                    .toolResult(
                        id: call.id, name: call.name, output: output, isError: isError))
            }
            history.append(Message(role: .tool, content: results))

            if iteration == config.maxIterations - 1 {
                throw AgentError.iterationLimit(config.maxIterations)
            }
        }
    }

    /// A tool failure is data, not a turn-ending error: the model is told what
    /// went wrong so it can pick a different approach. Cancellation is the one
    /// exception — it has to propagate or the loop would keep going.
    private func execute(
        _ call: (id: String, name: String, input: JSONValue),
        tools: [String: any Tool],
        context: ToolContext
    ) async -> (output: String, isError: Bool) {
        guard let tool = tools[call.name] else {
            return (AgentError.unknownTool(call.name).localizedDescription, true)
        }
        do {
            return (try await tool.execute(call.input, context: context), false)
        } catch is CancellationError {
            return ("Cancelled.", true)
        } catch {
            return ("Error: \(error.localizedDescription)", true)
        }
    }

    /// Retries a transient provider failure. The stream is only retried before
    /// any event is consumed, so a failure mid-answer surfaces rather than
    /// replaying half of it.
    private func streamWithRetry(
        _ params: CreateMessageParams,
        iteration: Int,
        into events: AsyncThrowingStream<TurnEvent, Error>.Continuation
    ) async throws -> AsyncThrowingStream<ModelStreamEvent, Error> {
        var attempt = 0
        while true {
            let requestAttempt = attempt + 1
            let started = ContinuousClock.now
            events.yield(.modelRequestStarted(iteration: iteration, attempt: requestAttempt))
            let end: @Sendable (String) -> Void = { outcome in
                let elapsed = started.duration(to: .now).components
                let durationMs = Int(
                    elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000)
                events.yield(
                    .modelRequestEnded(
                        iteration: iteration, attempt: requestAttempt,
                        durationMs: durationMs, outcome: outcome))
            }
            do {
                let stream = config.model.streamMessage(params)
                // Pull the first event here so a connect-time failure is caught
                // and retried rather than thrown to the consumer mid-iteration.
                var iterator = stream.makeAsyncIterator()
                guard let first = try await iterator.next() else {
                    end("completed")
                    return AsyncThrowingStream { $0.finish() }
                }
                return AsyncThrowingStream { continuation in
                    let task = Task {
                        continuation.yield(first)
                        do {
                            while let event = try await iterator.next() {
                                continuation.yield(event)
                            }
                            end(Task.isCancelled ? "cancelled" : "completed")
                            continuation.finish()
                        } catch {
                            end(
                                error is CancellationError || Task.isCancelled
                                    ? "cancelled" : "failed")
                            continuation.finish(throwing: error)
                        }
                    }
                    continuation.onTermination = { _ in task.cancel() }
                }
            } catch is CancellationError {
                end("cancelled")
                throw CancellationError()
            } catch {
                end(Task.isCancelled ? "cancelled" : "failed")
                let retryable = (error as? ModelError)?.isRetryable ?? false
                attempt += 1
                guard retryable, attempt <= config.maxRetries else { throw error }
                // Back off a little; the common retryable case is a rate limit.
                try await Task.sleep(nanoseconds: UInt64(attempt) * 500_000_000)
            }
        }
    }
}

/// A long-lived configuration that hands out sessions.
public struct Agent: Sendable {
    public let config: AgentConfig

    public init(config: AgentConfig) {
        self.config = config
    }

    public func session(history: [Message] = []) -> Session {
        Session(config: config, history: history)
    }
}
