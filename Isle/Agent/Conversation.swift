//
//  Conversation.swift
//  Isle
//

import Foundation
import Roboport

/// The running conversation: owns the model-facing history and sends each typed
/// message to the agent, reporting the answer (or a failure) back through
/// callbacks. Context is carried here and replayed on every turn rather than by
/// a resumed server-side session.
@MainActor
final class Conversation {
    /// One message in the running conversation. Re-exported from the engine so
    /// the rest of the app has a single name for it.
    typealias Turn = AgentEngine.Turn
    typealias ToolEvent = AgentEngine.ToolEvent

    private let preferences: Preferences
    private let tools: [any Roboport.Tool]
    private var engine: AgentEngine?

    init(preferences: Preferences, tools: [any Roboport.Tool]) {
        self.preferences = preferences
        self.tools = tools
    }

    /// Builds the engine on first use rather than at init.
    ///
    /// Reading the API key is what forces this: the keychain lookup can block on
    /// a system authorisation prompt, and doing that during
    /// `applicationDidFinishLaunching` hangs the app before it draws — which
    /// also hangs `xcodebuild test`, since the app is the test host. Resolving it
    /// on the first turn means launch never touches the keychain, and the prompt
    /// (if any) lands when the user has actually asked for something.
    private func makeEngine() -> AgentEngine? {
        if let engine { return engine }
        guard let apiKey = OpenRouterCredentials.key else {
            Log.error("agent.init", "no OpenRouter key in the environment or keychain")
            return nil
        }
        // An empty scratch dir keeps the agent from treating some real project as
        // its workspace; requests that act on the machine use absolute paths.
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("isle-workdir", isDirectory: true)
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        let built = AgentEngine(
            apiKey: apiKey,
            model: preferences.model,
            thinking: preferences.thinking,
            systemPrompt: preferences.systemPrompt,
            tools: tools,
            cwd: workDir.path,
            timeout: preferences.turnTimeout)
        engine = built
        return built
    }

    /// Prior turns, replayed on each request so the model has full context.
    /// Cleared by `clearHistory()`.
    private var history: [Turn] = []

    /// The turn in flight, so a new request or a clear can cancel it.
    private var running: Task<Void, Never>?

    /// Fired with the answer once it arrives.
    var onResponse: ((String) -> Void)?

    /// Fired when the message was empty, or the request failed. The string is
    /// nil for an empty message and a display message otherwise.
    var onNoResponse: ((String?) -> Void)?

    /// Fired as the agent starts/finishes tool calls during a turn, so the pill
    /// can show the active tool. Delivered on the main actor.
    var onToolEvent: ((ToolEvent) -> Void)?

    /// Sends a message and reports the answer through the callbacks, appending
    /// both sides to the replayed history on success.
    func submit(_ text: String) {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            onNoResponse?(nil)
            return
        }
        guard let engine = makeEngine() else {
            onNoResponse?(AgentEngine.EngineError.notConfigured.localizedDescription)
            return
        }

        // A second request supersedes the one in flight rather than racing it.
        running?.cancel()

        let replayed = history
        let model = preferences.model
        let thinking = preferences.thinking.rawValue
        running = Task { [weak self] in
            let started = Date()
            let elapsedMs = { Int(Date().timeIntervalSince(started) * 1000) }
            do {
                Log.turnUser(text: prompt)
                Log.modelRequest(
                    model: model, thinking: thinking, historyTurns: replayed.count,
                    prompt: prompt)
                let answer = try await engine.send(
                    prompt, history: replayed,
                    onTool: { [weak self] event in
                        Task { @MainActor in self?.onToolEvent?(event) }
                    })
                guard let self, !Task.isCancelled else { return }
                self.history.append(Turn(role: .user, text: prompt))
                self.history.append(Turn(role: .assistant, text: answer))
                Log.modelResponse(chars: answer.count, durationMs: elapsedMs())
                Log.turnAssistant(text: answer)
                self.onResponse?(answer)
            } catch {
                guard let self, !Task.isCancelled else { return }
                let classified = AgentEngine.EngineError.classify(error)
                Log.modelError("\(classified)", detail: "\(error)", durationMs: elapsedMs())
                self.onNoResponse?(classified.localizedDescription)
            }
        }
    }

    /// Forgets the conversation so the next request starts a fresh context.
    func clearHistory() {
        running?.cancel()
        running = nil
        history.removeAll()
        Log.endConversation()
    }

    /// The running conversation, so `AppDelegate` can persist the live chat after
    /// each answer.
    var currentHistory: [Turn] { history }

    /// Replace the conversation with a saved chat's transcript (reinstating it),
    /// so a follow-up is answered in that chat's context.
    func loadHistory(_ turns: [Turn]) {
        history = turns
    }
}
