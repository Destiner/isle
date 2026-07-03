//
//  BrowserService.swift
//  Isle
//

import Foundation

/// A page reduced to JSON-friendly fields — what crosses the actor boundary and gets
/// encoded into a tool result. `text` is present only when the caller asked to read
/// the page; `truncated` flags that the body was longer than the cap.
struct PageDTO: Codable, Sendable {
    let url: String
    let title: String
    let text: String?
    let truncated: Bool?
}

/// Where a captured screenshot was written.
struct ScreenshotDTO: Codable, Sendable {
    let path: String
}

/// A browser operation that failed, mapped to a message the model can read back.
enum BrowserError: LocalizedError {
    case chromeNotFound
    case launchFailed(String)
    case notConnected
    case timeout(String)
    case cdp(String)
    case evalFailed(String)
    case elementNotFound(String)
    case navigationFailed(String, String)
    case navigationBlocked(String)

    var errorDescription: String? {
        switch self {
        case .chromeNotFound:            "Google Chrome isn't installed at \(BrowserService.chromeBinary)."
        case .launchFailed(let m):       "Couldn't start Chrome for automation: \(m)"
        case .notConnected:              "Not connected to a browser page."
        case .timeout(let method):       "The browser didn't respond to \(method) in time."
        case .cdp(let m):                "Browser protocol error: \(m)"
        case .evalFailed(let m):         "Script evaluation failed: \(m)"
        case .elementNotFound(let sel):  "No element matched selector \"\(sel)\"."
        case .navigationFailed(let url, let err): "Couldn't load \(url): \(err)."
        case .navigationBlocked(let url): "Navigation to \(url) had no effect — the page didn't change. Some URLs (e.g. top-level data: URLs) are blocked by the browser."
        }
    }
}

/// Drives the user's installed Chrome over CDP, no bundled browser and no Node. On
/// first use it launches Chrome against a **dedicated** user-data-dir under Isle's
/// Application Support (so logins persist across runs without touching the user's
/// everyday profile) with the remote-debugging port open, then attaches a `CDPClient`
/// to a page target. Chrome is launched lazily (it's heavy) and reused across calls;
/// it outlives Isle, so the automation profile stays warm.
///
/// Mirrors `RemindersService`/`MailService`: an actor returning `Codable` DTOs, fronted
/// by `BrowserTools` on the shared MCP server.
actor BrowserService {
    static let chromeBinary = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

    private let port: Int
    private let headless: Bool
    private var cdp: CDPClient?
    private var chromeProcess: Process?

    /// Longest page body returned by `read`, to keep a big DOM from blowing the
    /// model's context. Slicing happens in-page so the excess is never transferred.
    private let textCap = 20_000

    init(port: Int, headless: Bool) {
        self.port = port
        self.headless = headless
    }

    // MARK: - Operations

    /// Navigates to `url`, waits for the load to settle, and returns the page with text.
    /// Reports a failure rather than returning stale content when the navigation didn't
    /// actually happen — either Chrome reported an error (bad host, network) or the page
    /// is unchanged despite a different requested URL (e.g. a blocked top-level data: URL).
    func navigate(url: String) async throws -> PageDTO {
        let cdp = try await ensureConnected()
        let before = (try? await evalString(cdp, "location.href")) ?? ""
        let result = try await cdp.send("Page.navigate", ["url": url])
        if let object = try? JSONSerialization.jsonObject(with: result) as? [String: Any],
           let errorText = object["errorText"] as? String {
            throw BrowserError.navigationFailed(url, errorText)
        }
        await waitForLoad(cdp)
        let page = try await pageInfo(cdp, includeText: true)
        if Self.urlsMatch(page.url, before), !Self.urlsMatch(page.url, url) {
            throw BrowserError.navigationBlocked(url)
        }
        return page
    }

    /// Reads the current page: url, title, and visible text (or outer HTML).
    func read(html: Bool) async throws -> PageDTO {
        let cdp = try await ensureConnected()
        return try await pageInfo(cdp, includeText: true, html: html)
    }

    /// Clicks the first element matching a CSS selector.
    func click(selector: String) async throws -> PageDTO {
        let cdp = try await ensureConnected()
        let expression = """
            (function(){var e=document.querySelector(\(Self.js(selector)));\
            if(!e){return false;}e.scrollIntoView({block:'center'});e.click();return true;})()
            """
        let result = try await evaluate(cdp, expression)
        guard result["value"] as? Bool == true else { throw BrowserError.elementNotFound(selector) }
        await waitForLoad(cdp)
        return try await pageInfo(cdp, includeText: false)
    }

    /// Fills a form field (input / textarea / contenteditable) and optionally submits.
    func type(selector: String, text: String, submit: Bool) async throws -> PageDTO {
        let cdp = try await ensureConnected()
        let expression = """
            (function(){var e=document.querySelector(\(Self.js(selector)));if(!e){return false;}\
            e.focus();if('value' in e){e.value=\(Self.js(text));}else{e.textContent=\(Self.js(text));}\
            e.dispatchEvent(new Event('input',{bubbles:true}));\
            e.dispatchEvent(new Event('change',{bubbles:true}));\
            if(\(submit ? "true" : "false")&&e.form){\
            if(e.form.requestSubmit){e.form.requestSubmit();}else{e.form.submit();}}return true;})()
            """
        let result = try await evaluate(cdp, expression)
        guard result["value"] as? Bool == true else { throw BrowserError.elementNotFound(selector) }
        if submit { await waitForLoad(cdp) }
        return try await pageInfo(cdp, includeText: false)
    }

    /// Runs a JavaScript expression in the page and returns its value as a JSON string
    /// (or the object description when the value isn't serializable, e.g. a DOM node).
    func evaluate(expression: String) async throws -> String {
        let cdp = try await ensureConnected()
        let result = try await evaluate(cdp, expression)
        if let value = result["value"] {
            let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
            return String(decoding: data, as: UTF8.self)
        }
        return result["description"] as? String ?? result["type"] as? String ?? "undefined"
    }

    /// Captures a PNG screenshot of the viewport, writing it to a temp file.
    func screenshot() async throws -> ScreenshotDTO {
        let cdp = try await ensureConnected()
        let data = try await cdp.send("Page.captureScreenshot", ["format": "png"])
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let base64 = object["data"] as? String,
              let png = Data(base64Encoded: base64) else {
            throw BrowserError.cdp("screenshot returned no image data")
        }
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("isle-shot-\(UUID().uuidString).png")
        try png.write(to: path)
        return ScreenshotDTO(path: path.path)
    }

    // MARK: - Connection

    /// The Isle-owned Chrome profile — separate from the user's everyday Chrome so
    /// automation logins persist here without disturbing their normal browsing.
    private var userDataDir: URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)) ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Isle/chrome-profile", isDirectory: true)
    }

    /// Returns a live `CDPClient`, launching Chrome (in the default visibility) and
    /// attaching a page if needed.
    private func ensureConnected() async throws -> CDPClient {
        if let cdp, await cdp.isConnected { return cdp }
        if !(await debugPortIsUp()) { try await launchChrome(headless: headless) }
        return try await attach()
    }

    /// Opens a fresh CDP connection to a page target on the running Chrome.
    private func attach() async throws -> CDPClient {
        let client = CDPClient()
        try await client.connect(wsURL: try await pageWebSocketURL())
        cdp = client
        return client
    }

    /// Escalate to a **visible** window so the user can do something only they can —
    /// sign in, solve a CAPTCHA, approve a step. Chrome can't switch headless↔headed
    /// on a live process, so this relaunches against the same on-disk profile (cookies
    /// and logins carry over), reopens the page the agent was on (or `url`), and brings
    /// it to the front. Returns once the window is up; the human step then plays out
    /// across the following conversation turns.
    func show(url: String?) async throws -> PageDTO {
        var target = url
        if target == nil { target = await currentURL() }
        try await relaunch(headless: false)
        let cdp = try await attach()
        if let target { _ = try await cdp.send("Page.navigate", ["url": target]); await waitForLoad(cdp) }
        _ = try? await cdp.send("Page.bringToFront")
        return try await pageInfo(cdp, includeText: false)
    }

    /// Tuck the browser back out of sight (headless) after an interactive step. The
    /// session established while visible persists via the shared profile.
    func hide() async throws -> PageDTO {
        let target = await currentURL()
        try await relaunch(headless: true)
        let cdp = try await attach()
        if let target { _ = try await cdp.send("Page.navigate", ["url": target]); await waitForLoad(cdp) }
        return try await pageInfo(cdp, includeText: false)
    }

    /// The current page's URL, if we're connected and it's a real page (not blank).
    private func currentURL() async -> String? {
        guard let cdp else { return nil }
        guard await cdp.isConnected else { return nil }
        guard let here = try? await evalString(cdp, "location.href") else { return nil }
        return (here.isEmpty || here == "about:blank") ? nil : here
    }

    /// Tears down the current Chrome and starts a fresh one in the requested visibility.
    private func relaunch(headless: Bool) async throws {
        await shutdownChrome()
        try await launchChrome(headless: headless)
    }

    /// Quits the automation Chrome **gracefully** via CDP `Browser.close` so it flushes
    /// cookies and localStorage to the profile before exiting — the entire point of the
    /// persistent profile. SIGTERMing the whole process tree (browser + renderers at
    /// once) makes Chrome treat it as a crash and skip that flush, which silently loses
    /// the just-established session. Escalates to a SIGTERM on only the launched process,
    /// then a tree `pkill`, solely as fallbacks if the graceful path doesn't bring the
    /// port down. Waits until the port is actually free so the relaunch can rebind it.
    private func shutdownChrome() async {
        if let cdp, await cdp.isConnected {
            _ = try? await cdp.send("Browser.close", timeoutMs: 4000)
        }
        await cdp?.close()
        cdp = nil

        if await portDownWithin(iterations: 15) { chromeProcess = nil; return }
        chromeProcess?.terminate()
        chromeProcess = nil
        if await portDownWithin(iterations: 10) { return }

        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-f", "user-data-dir=\(userDataDir.path)"]
        try? pkill.run()
        pkill.waitUntilExit()
        _ = await portDownWithin(iterations: 10)
    }

    private func portDownWithin(iterations: Int) async -> Bool {
        for _ in 0..<iterations {
            if !(await debugPortIsUp()) { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return !(await debugPortIsUp())
    }

    /// Launches Chrome against the dedicated profile and polls until the debugging port
    /// answers. `--headless=new` shares the same profile, so persisted logins still
    /// apply; omitting it opens a normal window.
    private func launchChrome(headless: Bool) async throws {
        guard FileManager.default.fileExists(atPath: Self.chromeBinary) else {
            throw BrowserError.chromeNotFound
        }
        try? FileManager.default.createDirectory(at: userDataDir, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.chromeBinary)
        var arguments = [
            "--remote-debugging-port=\(port)",
            "--user-data-dir=\(userDataDir.path)",
            "--no-first-run",
            "--no-default-browser-check",
            "--disable-session-crashed-bubble",
        ]
        if headless { arguments.append("--headless=new") }
        process.arguments = arguments
        do { try process.run() } catch { throw BrowserError.launchFailed(error.localizedDescription) }
        chromeProcess = process

        for _ in 0..<50 {
            if await debugPortIsUp() { return }
            try? await Task.sleep(for: .milliseconds(200))
        }
        throw BrowserError.launchFailed("no debugging port on \(port) after launch")
    }

    private func debugPortIsUp() async -> Bool {
        (try? await httpJSON("/json/version")) != nil
    }

    /// Picks an existing normal page tab's WebSocket, else opens a fresh tab.
    private func pageWebSocketURL() async throws -> URL {
        if let list = try await httpJSON("/json") as? [[String: Any]],
           let page = list.first(where: {
               ($0["type"] as? String) == "page"
                   && !(($0["url"] as? String) ?? "").hasPrefix("devtools://")
           }),
           let ws = page["webSocketDebuggerUrl"] as? String, let url = URL(string: ws) {
            return url
        }
        // `/json/new` is PUT on modern Chrome (was GET on older builds) — try both.
        var created = try? await httpJSON("/json/new?about:blank", method: "PUT")
        if created == nil { created = try? await httpJSON("/json/new?about:blank", method: "GET") }
        if let dict = created as? [String: Any],
           let ws = dict["webSocketDebuggerUrl"] as? String, let url = URL(string: ws) {
            return url
        }
        throw BrowserError.cdp("could not open a page to drive")
    }

    private func httpJSON(_ path: String, method: String = "GET") async throws -> Any {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = method
        request.timeoutInterval = 5
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw BrowserError.cdp("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1) for \(path)")
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    private let session = URLSession(configuration: .default)

    // MARK: - Page helpers

    /// Polls `document.readyState` until the page finishes loading (best-effort; a
    /// slow page just returns whatever state it reached within the window).
    private func waitForLoad(_ cdp: CDPClient) async {
        for _ in 0..<150 {
            if (try? await evalString(cdp, "document.readyState")) == "complete" { return }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    private func pageInfo(_ cdp: CDPClient, includeText: Bool, html: Bool = false) async throws -> PageDTO {
        let base = try await evalObject(cdp, "({u:location.href,t:document.title})")
        var text: String?
        var truncated: Bool?
        if includeText {
            let source = html ? "document.documentElement.outerHTML" : "(document.body?document.body.innerText:'')"
            let object = try await evalObject(cdp, "(function(){var s=\(source);return {n:s.length,s:s.slice(0,\(textCap))};})()")
            text = object["s"] as? String ?? ""
            truncated = (object["n"] as? Int ?? 0) > textCap
        }
        return PageDTO(
            url: base["u"] as? String ?? "",
            title: base["t"] as? String ?? "",
            text: text,
            truncated: truncated)
    }

    /// `Runtime.evaluate` returning the RemoteObject (`{type, value, description, ...}`),
    /// throwing on a thrown JS exception.
    private func evaluate(_ cdp: CDPClient, _ expression: String) async throws -> [String: Any] {
        let data = try await cdp.send("Runtime.evaluate", [
            "expression": expression,
            "returnByValue": true,
            "awaitPromise": true,
        ])
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let exception = object["exceptionDetails"] as? [String: Any] {
            throw BrowserError.evalFailed(Self.exceptionText(exception))
        }
        return object["result"] as? [String: Any] ?? [:]
    }

    private func evalObject(_ cdp: CDPClient, _ expression: String) async throws -> [String: Any] {
        try await evaluate(cdp, expression)["value"] as? [String: Any] ?? [:]
    }

    private func evalString(_ cdp: CDPClient, _ expression: String) async throws -> String {
        try await evaluate(cdp, expression)["value"] as? String ?? ""
    }

    private static func exceptionText(_ details: [String: Any]) -> String {
        if let exception = details["exception"] as? [String: Any],
           let description = exception["description"] as? String { return description }
        return details["text"] as? String ?? "exception"
    }

    /// A JSON string literal for safe embedding in a page-side script (quotes and
    /// escapes handled by the encoder). Encodes `[value]` and strips the brackets,
    /// since `JSONSerialization` won't serialize a bare string.
    private static func js(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let array = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(array.dropFirst().dropLast())
    }

    /// Loose URL equality for the navigation guard — ignores a trailing slash and any
    /// `#fragment` so a real redirect reads as a move while a no-op reads as unchanged.
    private static func urlsMatch(_ a: String, _ b: String) -> Bool {
        func normalize(_ s: String) -> String {
            var t = s
            if let hash = t.firstIndex(of: "#") { t = String(t[..<hash]) }
            if t.hasSuffix("/") { t.removeLast() }
            return t
        }
        return normalize(a) == normalize(b)
    }
}
