//
//  Conversation.swift
//  Isle
//

import Foundation

/// The running conversation: owns the model-facing history and sends each typed
/// message to Codex, reporting the answer (or a failure) back through callbacks.
/// `codex exec` is one-shot, so context is carried here and replayed on every
/// turn rather than by a resumed session.
@MainActor
final class Conversation {
    private let codex: CodexClient

    /// Tuning knobs (Codex model, reasoning effort, timeout) — see `Preferences`.
    private let preferences: Preferences

    init(preferences: Preferences) {
        self.preferences = preferences
        self.codex = CodexClient(
            systemPrompt: preferences.systemPrompt, model: preferences.codexModel,
            mcpReminderURL: preferences.enableReminderTools || preferences.enableCalendarTools || preferences.enableNotesTools || preferences.enableMusicTools || preferences.enableMailTools || preferences.enableBrowserTools
                ? "http://127.0.0.1:\(preferences.mcpPort)/mcp" : nil,
            computerAccess: preferences.computerAccess,
            timeout: preferences.codexTimeout)
    }

    /// Prior turns, passed back to Codex on each request so it has full context.
    /// Cleared by `clearHistory()`.
    private var history: [CodexClient.Turn] = []

    /// Fired with Codex's answer once it arrives.
    var onResponse: ((String) -> Void)?

    /// Fired when the message was empty, or the Codex request failed. The string
    /// is nil for an empty message and an error message otherwise.
    var onNoResponse: ((String?) -> Void)?

    /// Fired as Codex starts/finishes tool calls during a turn, so the pill can
    /// show the active tool. Delivered on the main actor.
    var onToolEvent: ((CodexClient.ToolEvent) -> Void)?

    /// Sends a composed message to Codex and reports the answer through the
    /// callbacks, appending both sides to the replayed history on success.
    func submit(_ text: String) {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            onNoResponse?(nil)
            return
        }

        Task {
            do {
                Log.turnUser(text: prompt)
                let answer = try await codex.send(
                    prompt, history: history, effort: preferences.reasoningEffort,
                    onTool: { [weak self] event in
                        Task { @MainActor in self?.onToolEvent?(event) }
                    })
                history.append(CodexClient.Turn(role: .user, text: prompt))
                history.append(CodexClient.Turn(role: .assistant, text: answer))
                Log.turnAssistant(text: answer)
                onResponse?(answer)
            } catch let error as CodexClient.CodexError {
                onNoResponse?(error.localizedDescription)
            } catch {
                Log.error("submit", "\(error)")
                onNoResponse?("Something went wrong")
            }
        }
    }

    /// Forgets the conversation so the next request starts a fresh context.
    func clearHistory() {
        history.removeAll()
        Log.endConversation()
    }

    /// The running conversation, so `AppDelegate` can persist the live chat after
    /// each answer.
    var currentHistory: [CodexClient.Turn] { history }

    /// Replace the conversation with a saved chat's transcript (reinstating it),
    /// so a follow-up is answered in that chat's context. `codex exec` is
    /// one-shot, so restoring the replayed history is all that's needed.
    func loadHistory(_ turns: [CodexClient.Turn]) {
        history = turns
    }
}
