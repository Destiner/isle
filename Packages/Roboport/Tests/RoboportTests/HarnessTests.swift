import XCTest

@testable import Roboport

private func context(
    cwd: String,
    searchWeb: @escaping @Sendable (String, Int?) async throws -> [SearchHit] = { _, _ in [] }
) -> ToolContext {
    ToolContext(cwd: cwd, searchWeb: searchWeb)
}

final class BashToolTests: XCTestCase {
    private var workdir: String = ""

    override func setUpWithError() throws {
        workdir = FileManager.default.temporaryDirectory
            .appendingPathComponent("roboport-bash-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(
            atPath: workdir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: workdir)
    }

    func testRunsACommandAndReturnsStdout() async throws {
        let output = try await BashTool().execute(
            .object(["command": .string("echo hello-from-isle")]), context: context(cwd: workdir))
        XCTAssertEqual(output, "hello-from-isle")
    }

    func testRunsInTheSessionWorkingDirectory() async throws {
        let output = try await BashTool().execute(
            .object(["command": .string("pwd")]), context: context(cwd: workdir))
        // /var and /private/var are the same place; compare resolved paths.
        XCTAssertEqual(
            URL(fileURLWithPath: output).resolvingSymlinksInPath().path,
            URL(fileURLWithPath: workdir).resolvingSymlinksInPath().path)
    }

    func testReportsANonZeroExit() async throws {
        let output = try await BashTool().execute(
            .object(["command": .string("exit 3")]), context: context(cwd: workdir))
        XCTAssertTrue(output.contains("exit code 3"), output)
    }

    func testCapturesStderr() async throws {
        let output = try await BashTool().execute(
            .object(["command": .string("echo oops >&2")]), context: context(cwd: workdir))
        XCTAssertTrue(output.contains("oops"), output)
    }

    func testEmptyOutputStillSaysSomething() async throws {
        let output = try await BashTool().execute(
            .object(["command": .string("true")]), context: context(cwd: workdir))
        XCTAssertEqual(output, "(no output)")
    }

    func testRequiresACommand() async throws {
        let output = try await BashTool().execute(.object([:]), context: context(cwd: workdir))
        XCTAssertTrue(output.contains("required"), output)
    }

    func testTruncatesRunawayOutput() async throws {
        let tool = BashTool(maxOutputBytes: 200)
        let output = try await tool.execute(
            .object(["command": .string("seq 1 5000")]), context: context(cwd: workdir))
        XCTAssertTrue(output.hasSuffix("… (truncated)"), "should be truncated")
        XCTAssertLessThan(output.utf8.count, 400)
    }

    func testKillsACommandThatOutlastsItsTimeout() async throws {
        let started = Date()
        let output = try await BashTool().execute(
            .object(["command": .string("sleep 30"), "timeout": .number(1)]),
            context: context(cwd: workdir))
        XCTAssertTrue(output.contains("timeout"), output)
        XCTAssertLessThan(
            Date().timeIntervalSince(started), 10, "the watchdog should not wait for sleep 30")
    }
}

final class WebSearchToolTests: XCTestCase {
    func testFormatsHits() async throws {
        let ctx = context(cwd: "/tmp") { query, limit in
            XCTAssertEqual(query, "roboport")
            XCTAssertEqual(limit, 5)
            return [
                SearchHit(title: "A", url: "https://a.example", text: "about a"),
                SearchHit(title: "B", url: "https://b.example"),
            ]
        }
        let output = try await WebSearchTool().execute(
            .object(["query": .string("roboport")]), context: ctx)
        XCTAssertTrue(output.contains("https://a.example"))
        XCTAssertTrue(output.contains("about a"))
        XCTAssertTrue(output.contains("B"))
    }

    func testHonoursMaxResults() async throws {
        let ctx = context(cwd: "/tmp") { _, limit in
            XCTAssertEqual(limit, 2)
            return []
        }
        _ = try await WebSearchTool().execute(
            .object(["query": .string("q"), "max_results": .number(2)]), context: ctx)
    }

    func testReportsNoResults() async throws {
        let output = try await WebSearchTool().execute(
            .object(["query": .string("q")]), context: context(cwd: "/tmp"))
        XCTAssertEqual(output, "No results.")
    }

    func testRequiresAQuery() async throws {
        let output = try await WebSearchTool().execute(
            .object([:]), context: context(cwd: "/tmp"))
        XCTAssertTrue(output.contains("required"), output)
    }
}

final class JSONValueTests: XCTestCase {
    func testRoundTripsThroughFoundation() {
        let value = JSONValue.object([
            "s": .string("x"), "n": .number(3), "b": .bool(true),
            "a": .array([.number(1), .null]),
        ])
        XCTAssertEqual(JSONValue.parse(value.encoded()), value)
    }

    /// NSNumber cannot be distinguished from a boxed Bool by type alone, so a
    /// naive bridge turns `true` into `1`.
    func testKeepsBooleansDistinctFromNumbers() {
        let parsed = JSONValue.parse("{\"flag\":true,\"count\":1}")
        XCTAssertEqual(parsed?["flag"], .bool(true))
        XCTAssertEqual(parsed?["count"], .number(1))
    }

    /// A whole number must not reach a tool (or a shell) as "10.0".
    func testEmitsWholeNumbersAsIntegers() {
        XCTAssertEqual(JSONValue.number(10).encodedString(), "10")
        XCTAssertEqual(JSONValue.number(1.5).encodedString(), "1.5")
    }

    func testParsesInvalidJSONAsNil() {
        XCTAssertNil(JSONValue.parse("{not json"))
    }
}
