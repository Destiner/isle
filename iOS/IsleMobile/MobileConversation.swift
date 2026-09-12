import Foundation
import Roboport

struct ConversationTurn: Codable, Identifiable, Sendable {
    let id: UUID
    let question: String
    var answer: String?
    var isError: Bool

    init(id: UUID = UUID(), question: String, answer: String? = nil, isError: Bool = false) {
        self.id = id
        self.question = question
        self.answer = answer
        self.isError = isError
    }
}

@MainActor
final class MobileConversation: ObservableObject {
    @Published private(set) var turns: [ConversationTurn]
    @Published private(set) var isResponding = false

    private struct StoredThread: Codable, Identifiable {
        let id: UUID
        let createdAt: Date
        var updatedAt: Date
        var turns: [ConversationTurn]
    }

    private struct Archive: Codable {
        var activeThreadID: UUID
        var threads: [StoredThread]
    }

    private static let archiveKey = "isle.mobile.threads"
    private static let idleTimeout: TimeInterval = 5 * 60
    private static let model = "openai/gpt-5.6-sol"
    private static let systemPrompt = """
        You are Isle, a concise personal assistant on iPhone.

        - Answer conversationally and get straight to the point.
        - Keep replies to one or two short paragraphs unless more is genuinely needed.
        - Do not claim to access apps, personal data, or tools. None are available yet.
        """

    private var archive: Archive
    private var session: Session?
    private var runningTask: Task<Void, Never>?

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.archiveKey),
           var stored = try? JSONDecoder().decode(Archive.self, from: data),
           let active = stored.threads.first(where: { $0.id == stored.activeThreadID }) {
            if Date().timeIntervalSince(active.updatedAt) >= Self.idleTimeout {
                let thread = Self.makeEmptyThread()
                stored.activeThreadID = thread.id
                stored.threads.append(thread)
                archive = stored
                turns = []
            } else {
                archive = stored
                turns = active.turns
            }
        } else {
            let thread = Self.makeEmptyThread()
            archive = Archive(activeThreadID: thread.id, threads: [thread])
            turns = []
        }
    }

    deinit {
        runningTask?.cancel()
    }

    @discardableResult
    func submit(_ rawPrompt: String) -> Bool {
        let prompt = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isResponding else { return false }

        startNewThreadIfIdle()
        let turnID = UUID()
        turns.append(ConversationTurn(id: turnID, question: prompt))
        isResponding = true

        runningTask = Task { [weak self] in
            await self?.run(prompt: prompt, turnID: turnID)
        }
        return true
    }

    private func run(prompt: String, turnID: UUID) async {
        do {
            let session = try makeSession()
            var streamedAnswer = ""

            for try await event in await session.send(prompt) {
                switch event {
                case .textDelta(let delta):
                    streamedAnswer += delta
                    update(turnID: turnID, answer: streamedAnswer)
                case .text(let completeText) where streamedAnswer.isEmpty:
                    streamedAnswer = completeText
                    update(turnID: turnID, answer: streamedAnswer)
                default:
                    break
                }
            }

            let answer = streamedAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !answer.isEmpty else { throw MobileAgentError.emptyResponse }
            update(turnID: turnID, answer: answer)
            persistActiveThread()
        } catch is CancellationError {
            remove(turnID: turnID)
        } catch {
            update(turnID: turnID, answer: MobileAgentError.message(for: error), isError: true)
        }

        isResponding = false
        runningTask = nil
    }

    private func makeSession() throws -> Session {
        if let session { return session }
        guard let apiKey = MobileOpenRouterCredentials.key else {
            throw MobileAgentError.notConfigured
        }

        let model = OpenRouter(
            Self.model,
            apiKey: apiKey,
            thinking: .low,
            referer: "https://github.com/Destiner/isle",
            title: "Isle"
        )
        let agent = Agent(
            config: AgentConfig(
                model: model,
                system: Self.systemPrompt,
                toolProviders: [],
                maxIterations: 2
            )
        )
        let history = turns.dropLast().flatMap { turn -> [Message] in
            guard !turn.isError, let answer = turn.answer, !answer.isEmpty else { return [] }
            return [
                Message(role: .user, text: turn.question),
                Message(role: .assistant, text: answer),
            ]
        }
        let session = agent.session(history: history)
        self.session = session
        return session
    }

    private func update(turnID: UUID, answer: String, isError: Bool = false) {
        guard let index = turns.firstIndex(where: { $0.id == turnID }) else { return }
        turns[index].answer = answer
        turns[index].isError = isError
    }

    private func remove(turnID: UUID) {
        turns.removeAll { $0.id == turnID }
    }

    private func startNewThreadIfIdle() {
        guard let active = archive.threads.first(where: { $0.id == archive.activeThreadID }),
              Date().timeIntervalSince(active.updatedAt) >= Self.idleTimeout else {
            return
        }

        let thread = Self.makeEmptyThread()
        archive.activeThreadID = thread.id
        archive.threads.append(thread)
        turns = []
        session = nil
        persistArchive()
    }

    private func persistActiveThread() {
        guard let index = archive.threads.firstIndex(where: { $0.id == archive.activeThreadID }) else {
            return
        }
        archive.threads[index].turns = turns.filter { !$0.isError }
        archive.threads[index].updatedAt = Date()
        persistArchive()
    }

    private func persistArchive() {
        guard let data = try? JSONEncoder().encode(archive) else { return }
        UserDefaults.standard.set(data, forKey: Self.archiveKey)
    }

    private static func makeEmptyThread() -> StoredThread {
        StoredThread(id: UUID(), createdAt: Date(), updatedAt: Date(), turns: [])
    }
}

private enum MobileAgentError: LocalizedError {
    case notConfigured
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "No API key configured."
        case .emptyResponse:
            "The model returned an empty response."
        }
    }

    static func message(for error: Error) -> String {
        if let local = error as? LocalizedError, let description = local.errorDescription {
            if case ModelError.http(let status, _) = error {
                switch status {
                case 401, 403: return "The API key was rejected."
                case 402, 429: return "The account is out of credit or temporarily rate-limited."
                case 500...599: return "The model service is temporarily unavailable."
                default: break
                }
            }
            return description
        }
        return "Something went wrong."
    }
}
