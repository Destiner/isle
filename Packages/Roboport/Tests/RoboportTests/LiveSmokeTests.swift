import XCTest

@testable import Roboport

/// Hits the real OpenRouter API. Skipped unless ROBOPORT_LIVE_KEY is set, so the
/// normal test run stays offline and free.
final class LiveSmokeTests: XCTestCase {
    private var key: String {
        get throws {
            guard let value = ProcessInfo.processInfo.environment["ROBOPORT_LIVE_KEY"],
                !value.isEmpty
            else { throw XCTSkip("set ROBOPORT_LIVE_KEY to run the live smoke test") }
            return value
        }
    }

    private func makeSession(_ key: String, cwd: String) -> Session {
        let model = OpenRouter(
            "openai/gpt-5.6-sol", apiKey: key, thinking: .low, title: "isle")
        return Session(
            config: AgentConfig(
                model: model,
                system: "You are Isle, a concise desktop assistant.\n\n"
                    + Harness.toolGuidance,
                toolProviders: [Harness.provider()],
                cwd: cwd))
    }

    private func run(_ session: Session, _ prompt: String) async throws -> (
        text: String, tools: [String]
    ) {
        var text = ""
        var tools: [String] = []
        for try await event in await session.send(prompt) {
            switch event {
            case .textDelta(let delta): text += delta
            case .toolCall(_, let name, _): tools.append(name)
            default: break
            }
        }
        return (text, tools)
    }

    func testPlainTurn() async throws {
        let session = makeSession(try key, cwd: NSTemporaryDirectory())
        let result = try await run(session, "Reply with exactly the word: pong")
        XCTAssertTrue(result.text.lowercased().contains("pong"), result.text)
    }

    func testBashToolRoundTrip() async throws {
        let dir = NSTemporaryDirectory() + "isle-live-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let session = makeSession(try key, cwd: dir)
        let result = try await run(
            session,
            "Use the bash tool to run `echo isle-ok`, then tell me exactly what it printed.")
        XCTAssertTrue(result.tools.contains("bash"), "tools: \(result.tools)")
        XCTAssertTrue(result.text.contains("isle-ok"), result.text)
    }

    func testWebSearch() async throws {
        let session = makeSession(try key, cwd: NSTemporaryDirectory())
        let result = try await run(
            session, "Use web_search to find what the Swift Package Manager is, in one sentence.")
        XCTAssertTrue(result.tools.contains("web_search"), "tools: \(result.tools)")
        XCTAssertFalse(result.text.isEmpty)
    }
}
