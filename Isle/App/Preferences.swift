//
//  Preferences.swift
//  Isle
//

import Foundation

/// How the user composes a request. The two modes are switched live with Tab
/// while the pill is open; the last-used mode is remembered across launches.
enum InputMode: String {
    case voice
    case text
}

/// Tunable knobs that shape Isle's behavior, in one place. Today these are
/// compile-time defaults for personal use; the struct is the seam a future
/// settings UI (or a `UserDefaults`-backed store) can hang off — build the
/// controls, mutate a `Preferences` value, and hand it to the pieces that read
/// it (`AppDelegate`, `DictationManager`, `CodexClient`).
struct Preferences {

    // MARK: - General

    /// Input mode used on first launch, before a Tab switch has been remembered
    /// (`UserDefaults` key `inputMode`).
    var defaultMode: InputMode = .text

    /// How long the pill can sit closed before the conversation is cleared, so
    /// the next open starts fresh.
    var idleTimeout: TimeInterval = 5 * 60

    /// Write structured debug logs (Codex runs, tool calls, turns, voice) to
    /// `~/Library/Application Support/Isle/logs/`. Debug builds only — the whole
    /// logging path compiles out of Release. The `ISLE_LOG` env var (`0`/`1`)
    /// overrides this per-launch. See `Log`.
    var enableLogging: Bool = true

    // MARK: - Codex

    /// `model_reasoning_effort` passed to `codex exec`. Medium balances snappy
    /// spoken Q&A against enough deliberation to discover and chain tools (e.g.
    /// multi-step browser flows); drop to `low` for pure speed, raise for harder tasks.
    var reasoningEffort: String = "medium"

    /// Model `codex exec` runs. Isle uses its own isolated `CODEX_HOME` so your
    /// personal `~/.codex/AGENTS.md` and `config.toml` don't leak into spoken
    /// answers — which also means the model is set here, not inherited from
    /// `~/.codex/config.toml`.
    var codexModel: String = "gpt-5.5"

    /// Grant Codex general-purpose computer access: run its shell commands
    /// unsandboxed with no approval prompts (`--dangerously-bypass-approvals-and-sandbox`),
    /// so spoken requests can open apps, launch files, and drive the machine. When
    /// off, Codex runs under a `workspace-write` seatbelt sandbox with approvals
    /// disabled — it can still run commands and write to its scratch dir, but can't
    /// send Apple Events to other apps (no controlling Music/Finder/etc.) or launch
    /// apps via LaunchServices. Isle's own Mail/Reminders tools are unaffected either
    /// way (they run in-process, not as sandboxed Codex subprocesses). Trade-off when
    /// on: a misheard command runs with full access under Isle's identity.
    var computerAccess: Bool = true

    /// Isle's system prompt. Written to the isolated `CODEX_HOME`'s `AGENTS.md`,
    /// it replaces the personal dev instructions Codex would otherwise load —
    /// tuned for short spoken answers rather than an agentic coding session.
    var systemPrompt: String = """
        You are Isle, an assistant living in a small pill on the user's Mac. \
        The user speaks or types a short request and hears or reads your reply.

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
        """

    /// Hard cap on a single `codex exec` run. If Codex hasn't finished within this,
    /// Isle kills the process (and its children) and surfaces a timeout instead of
    /// leaving the pill stuck on "thinking" forever — e.g. when the model's response
    /// stream stalls with no data and no close, which fires no timeout on Codex's own
    /// side. Generous on purpose: normal spoken Q&A finishes in seconds.
    var codexTimeout: TimeInterval = 5 * 60

    // MARK: - Tools (MCP)

    /// Expose Isle's reminder tools to Codex over a localhost MCP server. When on,
    /// Isle hosts the server and writes an `[mcp_servers.reminders]` entry into its
    /// isolated `CODEX_HOME` config so `codex exec` can call it.
    var enableReminderTools: Bool = true

    /// Expose Isle's calendar tools (read/create/edit through EventKit) to Codex on
    /// the localhost MCP server. First use asks for full Calendar access.
    var enableCalendarTools: Bool = true

    /// Expose Isle's mail tools (read/search/send via Mail.app over AppleScript) to
    /// Codex on the same MCP server. First use prompts for Automation access to Mail,
    /// attributed to Isle. `send_email` sends immediately — there is no confirmation.
    var enableMailTools: Bool = true

    /// Expose Isle's browser tools (navigate/read/click/type/evaluate/screenshot) to
    /// Codex on the same MCP server. Drives the user's installed Chrome over CDP — no
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

    /// Port the in-process MCP server binds on `127.0.0.1`. Codex connects here.
    var mcpPort: Int = 8917

    // MARK: - Voice: hands-free ("auto voice")

    /// Auto-submit a spoken turn once the speaker falls quiet, instead of
    /// waiting for Enter (the silence endpoint). Enter still works as an instant
    /// override when this is off.
    var autoSubmitOnSilence: Bool = true

    /// After an answer, silently re-arm the mic so simply speaking a follow-up
    /// flips back into listening — hands-free both ways. When off, the next turn
    /// starts on the next fn-tap or Enter.
    var autoListenFollowUp: Bool = true

    // MARK: - Voice: endpointing tuning
    //
    // Heuristic, hardware-dependent thresholds for the cheap RMS silence gate.
    // Tuned against a quiet built-in mic where speech RMS peaks ~0.02–0.03.

    /// How often the accumulating buffer is re-transcribed for the live preview.
    var partialInterval: Duration = .milliseconds(350)

    /// Cadence of the RMS silence gate, decoupled from transcription latency.
    var endpointInterval: Duration = .milliseconds(150)

    /// Trailing seconds of audio measured for RMS. Deliberately wide so
    /// syllable-level gaps in speech don't read as silence.
    var endpointWindow: Double = 0.6

    /// RMS below this marks the trailing window as "quiet".
    var silenceThreshold: Float = 0.008

    /// Speech that must accrue before sustained silence can end the turn.
    var minSpeech: Double = 0.4

    /// Sustained quiet (after `minSpeech`) that triggers an auto-submit.
    var endpointSilence: Double = 1.5

    /// Speech that must accrue to flip a shown answer into listening.
    var onsetSpeech: Double = 0.2
}
