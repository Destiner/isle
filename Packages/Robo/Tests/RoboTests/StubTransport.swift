import Foundation

@testable import Robo

/// Replays canned SSE chunks and records what was sent, so adapters can be
/// exercised without a live provider.
final class StubTransport: HTTPTransport, @unchecked Sendable {
    struct Capture {
        let url: String
        let headers: [String: String]
        let body: JSONValue
    }

    private let lock = NSLock()
    private var _captures: [Capture] = []
    private var streamQueue: [[JSONValue]] = []
    private var sendQueue: [(status: Int, data: Data)] = []

    var captures: [Capture] {
        lock.lock()
        defer { lock.unlock() }
        return _captures
    }

    var lastBody: JSONValue { captures.last?.body ?? .null }

    /// Queue one streamed response, as the sequence of chunk objects the
    /// provider would emit in `data:` lines.
    func enqueueStream(_ chunks: [JSONValue]) {
        lock.lock()
        streamQueue.append(chunks)
        lock.unlock()
    }

    func enqueueSend(status: Int = 200, _ value: JSONValue) {
        lock.lock()
        sendQueue.append((status, value.encoded()))
        lock.unlock()
    }

    private func record(_ request: URLRequest) {
        lock.lock()
        _captures.append(
            Capture(
                url: request.url?.absoluteString ?? "",
                headers: Dictionary(
                    uniqueKeysWithValues: (request.allHTTPHeaderFields ?? [:]).map {
                        ($0.key.lowercased(), $0.value)
                    }),
                body: request.httpBody.flatMap { JSONValue.parse($0) } ?? .null))
        lock.unlock()
    }

    func stream(_ request: URLRequest) async throws -> HTTPStreamResponse {
        record(request)
        lock.lock()
        let chunks = streamQueue.isEmpty ? [] : streamQueue.removeFirst()
        lock.unlock()
        return HTTPStreamResponse(
            status: 200,
            events: AsyncThrowingStream { continuation in
                for chunk in chunks { continuation.yield(chunk.encodedString()) }
                continuation.finish()
            })
    }

    func send(_ request: URLRequest) async throws -> (status: Int, data: Data) {
        record(request)
        lock.lock()
        let next = sendQueue.isEmpty ? (200, Data("{}".utf8)) : sendQueue.removeFirst()
        lock.unlock()
        return next
    }
}

/// A transport that always fails, to exercise error and retry paths.
final class FailingTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _attempts = 0
    private let status: Int
    /// Succeed (with an empty end-turn stream) once this many attempts have failed.
    private let succeedAfter: Int?

    init(status: Int, succeedAfter: Int? = nil) {
        self.status = status
        self.succeedAfter = succeedAfter
    }

    var attempts: Int {
        lock.lock()
        defer { lock.unlock() }
        return _attempts
    }

    func stream(_ request: URLRequest) async throws -> HTTPStreamResponse {
        lock.lock()
        _attempts += 1
        let count = _attempts
        lock.unlock()

        if let succeedAfter, count > succeedAfter {
            let chunk = JSONValue.object([
                "choices": .array([
                    .object([
                        "delta": .object(["content": .string("recovered")]),
                        "finish_reason": .string("stop"),
                    ])
                ])
            ])
            return HTTPStreamResponse(
                status: 200,
                events: AsyncThrowingStream { continuation in
                    continuation.yield(chunk.encodedString())
                    continuation.finish()
                })
        }
        return .failed(status: status, body: Data("upstream said no".utf8))
    }

    func send(_ request: URLRequest) async throws -> (status: Int, data: Data) {
        (status, Data("upstream said no".utf8))
    }
}
