//
//  Transcriber.swift
//  Isle
//

import Foundation

/// A live, streaming speech-to-text backend. Audio samples (16 kHz mono Float,
/// as produced by `AudioRecorder`) are pushed in as they're captured; the
/// backend emits a running transcript for the live preview and, on `finish()`,
/// returns the finalized text to hand to Codex.
///
/// Isle ships two implementations, selected by `Preferences.speechBackend`:
/// `AppleSpeechTranscriber` (Apple's on-device `SpeechAnalyzer`, macOS 26+) and
/// `ParakeetTranscriber` (FluidAudio / CoreML). `DictationManager` owns the mic
/// and the silence endpointing and drives whichever backend is selected through
/// this seam — mirroring the `MailProvider` pattern.
///
/// Concurrency: `append(_:)` is called from the realtime audio thread and must
/// be thread-safe; every other method is called from the main actor, and
/// `onPreview` is delivered on the main actor. Conformers are `@unchecked
/// Sendable` classes that guard their own state (the same shape as
/// `AudioRecorder`'s sample box).
protocol Transcriber: AnyObject, Sendable {

    /// Load models / download OS assets. Idempotent; safe to call at launch and
    /// again later. Runs in the background.
    func prepare() async

    /// Start a fresh utterance, clearing any prior session state. Called when the
    /// live preview begins — recording start, or speech onset on a follow-up.
    func begin()

    /// Push newly captured samples (16 kHz mono Float) as they arrive. Called
    /// from the audio thread; must not block.
    func append(_ samples: [Float])

    /// The running transcript for the live preview, delivered on the main actor.
    /// The append-only teleprompter (`IslandState.update`) freezes the shown
    /// prefix, so re-emitting a revised full string here is fine.
    var onPreview: ((String) -> Void)? { get set }

    /// Finalize the current utterance and return its transcript (the caller
    /// trims it). Returns "" if nothing usable was captured.
    func finish() async -> String

    /// Abandon the current utterance without finalizing.
    func cancel()
}

/// Builds the transcription backend for the selected preference.
enum TranscriberFactory {
    @MainActor static func make(_ backend: SpeechBackend, previewInterval: Duration) -> Transcriber {
        switch backend {
        case .apple: return AppleSpeechTranscriber(previewInterval: previewInterval)
        case .parakeet: return ParakeetTranscriber(previewInterval: previewInterval)
        }
    }
}
