//
//  LogTests.swift
//  IsleTests
//

import Foundation
import Testing
@testable import Isle

/// Covers `Log.jsonLine` — the JSONL line builder that is the on-disk log format.
/// These lock the envelope (keys present, stable ordering, valid JSON) since a
/// later debugging session parses these files back.
struct LogLineTests {

    private func parse(_ line: String?) -> [String: Any] {
        guard let line, let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return obj
    }

    @Test func envelopeIsAlwaysPresent() {
        let obj = parse(Log.jsonLine(
            cat: "codex", event: "request", level: .info, timestamp: "2026-07-02T00:00:00.000Z",
            conv: nil, turn: nil, fields: [:]))
        #expect(obj["ts"] as? String == "2026-07-02T00:00:00.000Z")
        #expect(obj["level"] as? String == "info")
        #expect(obj["cat"] as? String == "codex")
        #expect(obj["event"] as? String == "request")
    }

    @Test func convAndTurnOmittedWhenNil() {
        let obj = parse(Log.jsonLine(
            cat: "app", event: "launch", level: .info, timestamp: "t",
            conv: nil, turn: nil, fields: [:]))
        #expect(obj["conv"] == nil)
        #expect(obj["turn"] == nil)
    }

    @Test func convAndTurnIncludedWhenSet() {
        let obj = parse(Log.jsonLine(
            cat: "turn", event: "user", level: .info, timestamp: "t",
            conv: "c1", turn: "t3", fields: ["text": "hello", "chars": 12]))
        #expect(obj["conv"] as? String == "c1")
        #expect(obj["turn"] as? String == "t3")
        #expect(obj["text"] as? String == "hello")
        #expect(obj["chars"] as? Int == 12)
    }

    @Test func keysAreSortedForStableOutput() {
        let line = Log.jsonLine(
            cat: "codex", event: "response", level: .info, timestamp: "t",
            conv: nil, turn: nil, fields: ["zeta": 1, "alpha": 2])
        // sortedKeys → alpha before cat before event ... before ts before zeta.
        #expect(line == #"{"alpha":2,"cat":"codex","event":"response","level":"info","ts":"t","zeta":1}"#)
    }

    @Test func fieldsCanOverrideNothingCritical() {
        // Envelope keys win over caller fields (set last), so a stray "level"
        // field can't corrupt the level.
        let obj = parse(Log.jsonLine(
            cat: "tool", event: "call", level: .warn, timestamp: "t",
            conv: nil, turn: nil, fields: ["level": "sneaky"]))
        #expect(obj["level"] as? String == "warn")
    }
}
