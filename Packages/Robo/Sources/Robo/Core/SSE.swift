import Foundation

/// Server-sent events, reduced to what a chat-completions stream actually uses:
/// `data:` lines, with `[DONE]` ending the stream. Other fields (`event:`,
/// `id:`, comments) are ignored rather than modelled, since no provider here
/// depends on them.
enum SSE {
    /// Yields the payload of each `data:` line, stopping at `[DONE]`.
    static func lines(from bytes: URLSession.AsyncBytes) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines {
                        // A blank line closes an event; with one data field per
                        // event there is nothing to flush, so skip it.
                        if line.isEmpty { continue }
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        if payload.isEmpty { continue }
                        continuation.yield(payload)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
