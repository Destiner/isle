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

    // MARK: - Codex

    /// `model_reasoning_effort` passed to `codex exec`. Low keeps spoken Q&A
    /// snappy rather than agentic; bump it for harder requests.
    var reasoningEffort: String = "low"

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
