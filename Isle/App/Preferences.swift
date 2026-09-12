//
//  Preferences.swift
//  Isle
//

import Foundation
import Roboport

/// Which backend the mail tools run against. `.appleMail` drives Mail.app over
/// AppleScript (fronts every configured account, works offline, but slow — ~10
/// Apple Events per message); `.fastmail` talks JMAP over HTTPS directly (one
/// request per list/search, needs a Fastmail API token, single-account for now).
enum MailBackend: String {
    case appleMail
    case fastmail
}

/// Tunable knobs that shape Isle's behavior, in one place. Today these are
/// compile-time defaults for personal use; the struct is the seam a future
/// settings UI (or a `UserDefaults`-backed store) can hang off — build the
/// controls, mutate a `Preferences` value, and hand it to the pieces that read
/// it (`AppDelegate`, `Conversation`, `AgentEngine`).
struct Preferences {

    // MARK: - General

    /// How long the pill can sit closed before the conversation is cleared, so
    /// the next open starts fresh.
    var idleTimeout: TimeInterval = 5 * 60

    /// Register Isle as a login item so it is ready after the user signs in.
    /// macOS still owns the final approval and lets the user disable it in
    /// System Settings › General › Login Items & Extensions.
    var launchAtLogin: Bool = true

    /// Write structured debug logs (model turns, tool calls) to
    /// `~/Library/Application Support/Isle/logs/`. Debug builds only — the whole
    /// logging path compiles out of Release. The `ISLE_LOG` env var (`0`/`1`)
    /// overrides this per-launch. See `Log`.
    var enableLogging: Bool = true

    // MARK: - Model

    /// Reasoning effort for the turn. Low favors snappy Q&A over deliberation;
    /// raise for harder tasks that need to discover and chain tools (e.g.
    /// multi-step browser flows).
    var thinking: ThinkingLevel = .low

    /// The model Isle runs, as an OpenRouter `author/slug`.
    var model: String = "openai/gpt-5.6-sol"

    /// Isle's system prompt, sent as the system message each turn. Tool-use
    /// guidance is appended by the engine, so this stays pure persona — tuned
    /// for short conversational answers rather than an agentic coding session.
    var systemPrompt: String = """
        You are Isle, an assistant living in a small pill on the user's Mac. \
        The user types a short request and reads your reply.

        - Answer conversationally, the way you'd say it aloud. Keep it to one or two short \
        sentences unless more is genuinely needed.
        - Get straight to the point. Skip preamble, caveats, and restating the question.
        - You can act on this Mac when asked — open apps, files, or folders, run quick \
        commands — then confirm in a few words.
        - To browse the web, use your browser tools rather than shell commands; they drive \
        a real Chrome: browser_navigate, browser_read, browser_click, browser_type, \
        browser_evaluate, browser_screenshot, browser_show, browser_hide. You can fully \
        interact with pages — click, type, submit. Call browser_show when a page needs the \
        user — e.g. to sign in.
        - You can also use Isle's personal-app tools when asked: reminders, Calendar, Apple \
        Notes, Mail, and Music. Use the relevant MCP tool directly; don't say you lack access \
        unless a tool call actually fails. For Calendar, Notes, or Music, call its discovery \
        tool first when you need to identify an item (list_calendars, list_note_folders, or \
        search_music_library/list_music_playlists).
        """

    /// Hard cap on a single turn. If it hasn't finished within this, Isle
    /// cancels the turn and surfaces a timeout rather than leaving the pill
    /// stuck on "thinking" forever. Generous on purpose: normal quick Q&A
    /// finishes in seconds, but a browser flow can legitimately run for minutes.
    var turnTimeout: TimeInterval = 5 * 60

    // MARK: - Tools

    /// Expose Isle's reminder tools to the agent. First use asks for full
    /// Reminders access.
    var enableReminderTools: Bool = true

    /// Expose Isle's calendar tools (read/create/edit through EventKit). First
    /// use asks for full Calendar access.
    var enableCalendarTools: Bool = true

    /// Expose Apple Notes tools. Notes is controlled in-process with
    /// AppleScript, using Isle's existing Automation permission.
    var enableNotesTools: Bool = true

    /// Expose Music playback and library tools.
    var enableMusicTools: Bool = true

    /// Expose Isle's mail tools (read/search/send). `send_email` sends
    /// immediately — there is no confirmation. The backend is chosen by
    /// `mailBackend`.
    var enableMailTools: Bool = true

    /// Which backend the mail tools run against (see `MailBackend`). `.fastmail`
    /// (JMAP) is the default; `.appleMail` is kept as an offline / all-accounts
    /// fallback. Selecting `.fastmail` needs a token (see `FastmailCredentials`).
    var mailBackend: MailBackend = .fastmail

    /// Builds the mail backend `MailService` runs against, per `mailBackend`. A
    /// missing Fastmail token doesn't fail here — it surfaces as a readable error on
    /// the first tool call (`JMAPMailProvider.requireClient`).
    func makeMailProvider() -> MailProvider {
        switch mailBackend {
        case .appleMail: AppleMailProvider()
        case .fastmail: JMAPMailProvider(tokenProvider: { FastmailCredentials.token })
        }
    }

    /// Expose Isle's browser tools (navigate/read/click/type/evaluate/screenshot).
    /// Drives the user's installed Chrome over CDP — no
    /// bundled browser — launching it lazily on first use against a dedicated,
    /// persistent profile under Isle's Application Support (`chrome-profile`), so
    /// automation logins survive across runs without touching everyday browsing.
    var enableBrowserTools: Bool = true

    /// Remote-debugging port Isle opens Chrome on (and attaches CDP to) on `127.0.0.1`.
    var chromeDebuggingPort: Int = 9222

    /// Launch the automation Chrome headless (`--headless=new`) — a real Chrome that
    /// shares the same persistent profile (cookies/logins survive) but paints no
    /// window, so it doesn't pop up on the user's screen. Caveat: a headless window
    /// can't be signed into interactively, so auth-gated sites need one headed launch
    /// (`chromeHeadless = false`) to establish the session first; headless then reuses
    /// it. Public pages work headless immediately.
    var chromeHeadless: Bool = true
}
