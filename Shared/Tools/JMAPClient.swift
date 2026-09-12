//
//  JMAPClient.swift
//  Isle
//

import Foundation

/// Minimal JMAP transport over `URLSession` — session discovery plus the single
/// `methodCalls` POST endpoint. Same "speak the protocol directly, bundle nothing"
/// approach as `CDPClient`: JMAP is just JSON over HTTPS, so there's no SDK, only a
/// bearer token and two request shapes.
///
/// An `actor` so the discovered `Session` is fetched once and cached without a data
/// race. Request/response bodies cross the boundary as `Data` (Sendable) — the
/// caller builds the `[String: Any]` method-call array and parses the response, so
/// no non-Sendable dictionary is ever passed in or out.
actor JMAPClient {
    /// The bits of the JMAP session object Isle needs: where to POST, and the mail
    /// account to operate on (Fastmail is single-account for us today).
    struct Session: Sendable {
        let apiURL: URL
        let accountId: String
        /// The account's primary address (e.g. `you@fastmail.com`), used as the
        /// display `account` on returned emails.
        let accountName: String
    }

    static let coreCapability = "urn:ietf:params:jmap:core"
    static let mailCapability = "urn:ietf:params:jmap:mail"
    static let submissionCapability = "urn:ietf:params:jmap:submission"

    private let token: String
    private let sessionURL: URL
    private let urlSession: URLSession
    private var cached: Session?

    init(
        token: String,
        sessionURL: URL = URL(string: "https://api.fastmail.com/jmap/session")!,
        urlSession: URLSession = .shared
    ) {
        self.token = token
        self.sessionURL = sessionURL
        self.urlSession = urlSession
    }

    /// Fetches (and caches) the JMAP session: the API endpoint and the primary mail account.
    func session() async throws -> Session {
        if let cached { return cached }
        var request = URLRequest(url: sessionURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await urlSession.data(for: request)
        try Self.checkStatus(response, data: data)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let apiURLString = json["apiUrl"] as? String,
              let apiURL = URL(string: apiURLString, relativeTo: sessionURL),
              let primary = json["primaryAccounts"] as? [String: Any],
              let accountId = primary[Self.mailCapability] as? String else {
            throw MailError.backend("Malformed JMAP session response.")
        }
        let account = (json["accounts"] as? [String: Any])?[accountId] as? [String: Any]
        let name = account?["name"] as? String ?? accountId
        let session = Session(apiURL: apiURL, accountId: accountId, accountName: name)
        cached = session
        return session
    }

    /// POSTs a pre-serialized JMAP request body to the account's API endpoint and
    /// returns the raw response bytes for the caller to parse.
    func post(_ body: Data) async throws -> Data {
        let session = try await session()
        var request = URLRequest(url: session.apiURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await urlSession.data(for: request)
        try Self.checkStatus(response, data: data)
        return data
    }

    private static func checkStatus(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200...299:
            return
        case 401, 403:
            throw MailError.notConfigured(
                "Fastmail rejected the API token (HTTP \(http.statusCode)). Check the token stored in the Keychain.")
        default:
            let text = String(data: data, encoding: .utf8) ?? ""
            throw MailError.backend("JMAP request failed (HTTP \(http.statusCode)): \(text.prefix(200))")
        }
    }
}
