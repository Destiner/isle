//
//  IsleTests.swift
//  IsleTests
//
//  Created by Timur Badretdinov on 29/06/2026.
//

import Testing
@testable import Isle

/// Covers `CodexClient.CodexError.classify` — the stderr/exit-code mapping that
/// turns a failed `codex exec` run into a short display case. Fixtures are real
/// or representative Codex output; the ordering test guards against the broad
/// `model` check swallowing more specific failures.
struct CodexErrorClassifyTests {
    typealias E = CodexClient.CodexError

    @Test func usageLimit() {
        #expect(E.classify(exitCode: 1, stderr:
            "ERROR: You've hit your usage limit. Try again at 10:04 PM.") == .usageLimit)
        #expect(E.classify(exitCode: 1, stderr: "429 Too Many Requests") == .usageLimit)
    }

    @Test func notAuthenticated() {
        #expect(E.classify(exitCode: 1, stderr: "Not logged in. Run `codex login`.")
            == .notAuthenticated)
        #expect(E.classify(exitCode: 1, stderr: "401 Unauthorized") == .notAuthenticated)
    }

    @Test func notInstalled() {
        #expect(E.classify(exitCode: 127, stderr: "") == .notInstalled)
        #expect(E.classify(exitCode: 1, stderr: "zsh: command not found: codex")
            == .notInstalled)
    }

    @Test func modelUnavailable() {
        // Verbatim stderr from `codex exec -c model=bogus` on a ChatGPT account.
        let real = """
            model: bogus-model-xyz
            warning: Model metadata for `bogus-model-xyz` not found. Defaulting to fallback metadata; this can degrade performance and cause issues.
            ERROR: {"type":"error","status":400,"error":{"type":"invalid_request_error","message":"The 'bogus-model-xyz' model is not supported when using Codex with a ChatGPT account."}}
            """
        #expect(E.classify(exitCode: 1, stderr: real) == .modelUnavailable)
    }

    @Test func serviceUnavailable() {
        #expect(E.classify(exitCode: 1, stderr: "error sending request: connection timed out")
            == .serviceUnavailable)
        #expect(E.classify(exitCode: 1, stderr: "503 Service Unavailable") == .serviceUnavailable)
    }

    @Test func unrecognizedFallsBackToFailed() {
        #expect(E.classify(exitCode: 1, stderr: "some unexpected panic") == .failed)
    }

    @Test func bannerModelLineIsNotAModelError() {
        // The startup banner always prints `model: …`; on its own that must not
        // read as a model failure, and a usage limit alongside it still wins.
        let stderr = """
            OpenAI Codex v0.142.5
            model: gpt-5.5
            ERROR: You've hit your usage limit.
            """
        #expect(E.classify(exitCode: 1, stderr: stderr) == .usageLimit)
    }
}
