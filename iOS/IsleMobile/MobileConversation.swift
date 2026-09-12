import Foundation
import Roboport

struct MobileAgentActivity: Identifiable, Sendable {
    let id: Int
    let icon: String
    let label: String
}

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
    @Published private(set) var activity: MobileAgentActivity?

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
        - Use Isle's available tools when the user asks for current or personal information.
        """

    private var archive: Archive
    private var session: Session?
    private var runningTask: Task<Void, Never>?
    private var activityFlipTask: Task<Void, Never>?
    private var pendingActivity: (icon: String, label: String)?
    private var activityCounter = 0
    private var activityShownAt: Date?

    private let minimumActivityDisplay: TimeInterval = 1

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
        activityFlipTask?.cancel()
    }

    @discardableResult
    func submit(_ rawPrompt: String) -> Bool {
        let prompt = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isResponding else { return false }

        startNewThreadIfIdle()
        let turnID = UUID()
        turns.append(ConversationTurn(id: turnID, question: prompt))
        isResponding = true
        showActivity(icon: "ellipsis", label: "Thinking…")

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
                    clearActivity()
                    update(turnID: turnID, answer: streamedAnswer)
                case .text(let completeText) where streamedAnswer.isEmpty:
                    streamedAnswer = completeText
                    clearActivity()
                    update(turnID: turnID, answer: streamedAnswer)
                case .thinkingDelta, .thinking:
                    showActivity(icon: "ellipsis", label: "Thinking…")
                case .toolCall(_, let name, _):
                    let presentation = Self.presentation(forTool: name)
                    showActivity(icon: presentation.icon, label: presentation.label)
                case .toolResult:
                    showActivity(icon: "ellipsis", label: "Thinking…")
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

        clearActivity()
        isResponding = false
        runningTask = nil
    }

    private func showActivity(icon: String, label: String) {
        if activity?.icon == icon, activity?.label == label, pendingActivity == nil { return }
        if pendingActivity?.icon == icon, pendingActivity?.label == label { return }

        if activity == nil || Date().timeIntervalSince(activityShownAt ?? .distantPast) >= minimumActivityDisplay {
            applyActivity(icon: icon, label: label)
            return
        }

        pendingActivity = (icon, label)
        activityFlipTask?.cancel()
        let elapsed = Date().timeIntervalSince(activityShownAt ?? .distantPast)
        let delay = max(0, minimumActivityDisplay - elapsed)
        activityFlipTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, let pending = self.pendingActivity else { return }
            self.applyActivity(icon: pending.icon, label: pending.label)
        }
    }

    private func applyActivity(icon: String, label: String) {
        activityFlipTask?.cancel()
        activityFlipTask = nil
        pendingActivity = nil
        activityCounter += 1
        activity = MobileAgentActivity(id: activityCounter, icon: icon, label: label)
        activityShownAt = Date()
    }

    private func clearActivity() {
        activityFlipTask?.cancel()
        activityFlipTask = nil
        pendingActivity = nil
        activity = nil
        activityShownAt = nil
    }

    private static func presentation(forTool name: String) -> (icon: String, label: String) {
        switch name {
        case "web_search", "web.search":
            ("globe", "Searching the web…")
        case "command_execution":
            ("terminal", "Running a command…")
        case "file_change":
            ("pencil", "Editing files…")
        case "create_reminder":
            ("checklist", "Creating a reminder…")
        case "edit_reminder":
            ("checklist", "Updating reminders…")
        case "list_calendars":
            ("calendar", "Checking calendars…")
        case "list_events", "get_event":
            ("calendar", "Checking your calendar…")
        case "create_event", "edit_event":
            ("calendar.badge.plus", "Updating your calendar…")
        default:
            if name.contains("calendar") || name.contains("event") {
                ("calendar", "Checking your calendar…")
            } else if name.contains("reminder") {
                ("checklist", "Checking reminders…")
            } else if name.contains("note") {
                ("note.text", "Checking your notes…")
            } else if name.contains("mail") || name.contains("email") {
                ("envelope", "Checking mail…")
            } else if name.hasPrefix("browser") {
                ("safari", "Browsing…")
            } else {
                ("wrench.and.screwdriver", "Working…")
            }
        }
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
        let now = ISO8601DateFormatter().string(from: Date())
        let agent = Agent(
            config: AgentConfig(
                model: model,
                system: """
                    \(Self.systemPrompt)

                    Current date and time: \(now)
                    Current time zone: \(TimeZone.current.identifier)

                    \(MobileToolSet.guidance)
                    """,
                toolProviders: [StaticToolProvider(MobileToolSet.tools())],
                maxIterations: 16
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

    func startNewThreadIfIdle() {
        guard !isResponding,
              let active = archive.threads.first(where: { $0.id == archive.activeThreadID }),
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
