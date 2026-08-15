import Foundation

/// The result of a streaming request. Exactly one of `events` / `body` carries
/// the payload: a 2xx streams SSE events, anything else is drained into `body`
/// so the caller can put the provider's error text into the thrown error.
public struct HTTPStreamResponse: Sendable {
    public let status: Int
    public let events: AsyncThrowingStream<String, Error>
    public let body: Data

    public init(status: Int, events: AsyncThrowingStream<String, Error>, body: Data = Data()) {
        self.status = status
        self.events = events
        self.body = body
    }

    public static func failed(status: Int, body: Data) -> HTTPStreamResponse {
        HTTPStreamResponse(
            status: status,
            events: AsyncThrowingStream { $0.finish() },
            body: body)
    }
}

/// The seam between a model adapter and the network, so adapters can be tested
/// against recorded streams instead of a live provider.
public protocol HTTPTransport: Sendable {
    func stream(_ request: URLRequest) async throws -> HTTPStreamResponse
    func send(_ request: URLRequest) async throws -> (status: Int, data: Data)
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func stream(_ request: URLRequest) async throws -> HTTPStreamResponse {
        let (bytes, response) = try await session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            // Drain the error body; it is small and the message matters more
            // than the bytes saved by skipping it.
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            return .failed(status: status, body: data)
        }
        return HTTPStreamResponse(status: status, events: SSE.lines(from: bytes))
    }

    public func send(_ request: URLRequest) async throws -> (status: Int, data: Data) {
        let (data, response) = try await session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}
