//
//  CDPClient.swift
//  Isle
//

import Foundation

/// A minimal Chrome DevTools Protocol client speaking to a single page target over a
/// WebSocket (`URLSessionWebSocketTask`). CDP is just JSON-RPC over WS —
/// `{id, method, params}` out, `{id, result | error}` back, interleaved with
/// unsolicited `{method, params}` events — so this is all we need to drive a page
/// with no Node/Puppeteer and nothing bundled: it talks to the user's own installed
/// Chrome (launched by `BrowserService`).
///
/// Requests are correlated by their integer `id`; events (no `id`) are ignored — the
/// higher-level ops in `BrowserService` poll (`document.readyState`) rather than wait
/// on load events, so this layer stays request/reply only. Each command carries its
/// own timeout so a wedged socket can't hang a tool call forever.
actor CDPClient {
    /// A received WS frame, reduced to `Sendable` values in the receive callback so it
    /// can cross into the actor without dragging `URLSessionWebSocketTask.Message`.
    private enum Frame: Sendable {
        case text(String)
        case failed(String)
    }

    private let session = URLSession(configuration: .default)
    private var webSocket: URLSessionWebSocketTask?
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]

    var isConnected: Bool { webSocket != nil }

    /// Opens the WebSocket to a page's `webSocketDebuggerUrl` and enables the Page and
    /// Runtime domains (Page for navigation/screenshots, Runtime for `evaluate`).
    func connect(wsURL: URL) async throws {
        let task = session.webSocketTask(with: wsURL)
        webSocket = task
        task.resume()
        receiveNext()
        _ = try await send("Page.enable")
        _ = try await send("Runtime.enable")
    }

    /// Sends a CDP command and awaits its reply, returning the raw `result` object as
    /// JSON `Data` (Sendable — callers parse the fields they need). Throws on a CDP
    /// `error`, a socket write failure, or if no reply arrives within `timeoutMs`.
    func send(_ method: String, _ params: [String: Any] = [:], timeoutMs: Int = 30_000) async throws -> Data {
        guard let ws = webSocket else { throw BrowserError.notConnected }
        let id = nextID
        nextID += 1
        let payload: [String: Any] = ["id": id, "method": method, "params": params]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)

        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            ws.send(.string(json)) { [weak self] error in
                if let error { Task { await self?.fail(id: id, error: error) } }
            }
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(timeoutMs))
                await self?.fail(id: id, error: BrowserError.timeout(method))
            }
        }
    }

    /// Closes the socket and fails any in-flight commands.
    func close() {
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        failAll("connection closed")
    }

    // MARK: - Receive loop

    /// Arms a one-shot receive; re-armed from `handle` after each frame so processing
    /// stays ordered through the actor. A `.failed` frame tears the connection down.
    private func receiveNext() {
        guard let ws = webSocket else { return }
        ws.receive { [weak self] result in
            let frame: Frame
            switch result {
            case .success(let message):
                switch message {
                case .string(let string): frame = .text(string)
                case .data(let data): frame = .text(String(decoding: data, as: UTF8.self))
                @unknown default: frame = .text("")
                }
            case .failure(let error):
                frame = .failed(error.localizedDescription)
            }
            Task { await self?.handle(frame) }
        }
    }

    private func handle(_ frame: Frame) {
        switch frame {
        case .failed(let message):
            webSocket = nil
            failAll(message)
        case .text(let string):
            resolve(string)
            receiveNext()
        }
    }

    /// Matches a reply to its pending command by `id`. Frames without an `id` are
    /// events, which this client doesn't consume.
    private func resolve(_ string: String) {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(string.utf8))) as? [String: Any],
              let id = object["id"] as? Int,
              let continuation = pending.removeValue(forKey: id) else { return }
        if let error = object["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "CDP error"
            continuation.resume(throwing: BrowserError.cdp(message))
            return
        }
        let result = object["result"] as? [String: Any] ?? [:]
        let data = (try? JSONSerialization.data(withJSONObject: result)) ?? Data("{}".utf8)
        continuation.resume(returning: data)
    }

    private func fail(id: Int, error: Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func failAll(_ message: String) {
        let error = BrowserError.cdp(message)
        for (_, continuation) in pending { continuation.resume(throwing: error) }
        pending.removeAll()
    }
}
