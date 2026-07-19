//
//  DictationManager.swift
//  Isle
//

import AppKit
import AVFoundation

/// Records speech while Isle is visible and, on Enter, transcribes it locally,
/// then sends the transcript to Codex and reports back its answer. The
/// transcription backend is swappable (`Preferences.speechBackend`): Apple's
/// on-device `SpeechAnalyzer` (default) or Parakeet via FluidAudio — this class
/// owns the mic and the silence endpointing and drives whichever is selected
/// through the `Transcriber` seam.
@MainActor
final class DictationManager {
    private let recorder = AudioRecorder()
    private let codex: CodexClient
    private let transcriber: Transcriber

    /// Whether the transcriber has an utterance in flight — i.e. `begin()` was
    /// called and audio is being fed. False for a follow-up armed with
    /// `preview: false` until speech onset flips on the live preview.
    private var previewing = false
    private var prepared = false

    /// Tuning knobs (endpointing thresholds, live-preview cadence, Codex
    /// reasoning effort) — see `Preferences`.
    private let preferences: Preferences

    init(preferences: Preferences = Preferences()) {
        self.preferences = preferences
        self.codex = CodexClient(
            systemPrompt: preferences.systemPrompt, model: preferences.codexModel,
            mcpReminderURL: preferences.enableReminderTools || preferences.enableCalendarTools || preferences.enableNotesTools || preferences.enableMusicTools || preferences.enableMailTools || preferences.enableBrowserTools
                ? "http://127.0.0.1:\(preferences.mcpPort)/mcp" : nil,
            computerAccess: preferences.computerAccess,
            timeout: preferences.codexTimeout)
        self.transcriber = TranscriberFactory.make(
            preferences.speechBackend, previewInterval: preferences.partialInterval)
        self.transcriber.onPreview = { [weak self] text in self?.onPartialTranscript?(text) }
    }

    /// The running conversation, passed back to Codex on each turn so it has the
    /// full context. Cleared by `clearHistory()` (Esc).
    private var history: [CodexClient.Turn] = []

    /// Live partial transcript updates while recording, on the main actor.
    var onPartialTranscript: ((String) -> Void)?

    /// Fired with the final transcript once recording stops, just before the
    /// request is sent to Codex (so the UI can settle the question).
    var onFinalTranscript: ((String) -> Void)?

    /// Fired with Codex's answer once it arrives.
    var onResponse: ((String) -> Void)?

    /// Fired when nothing usable was captured, or the Codex request failed.
    /// The string is nil for an empty capture and an error message otherwise.
    var onNoResponse: ((String?) -> Void)?

    /// Fired as Codex starts/finishes tool calls during a turn, so the pill can
    /// show the active tool. Delivered on the main actor.
    var onToolEvent: ((CodexClient.ToolEvent) -> Void)?

    /// Fired when the speaker has gone quiet after talking — the cue to submit
    /// the clip automatically. Wired to the same path as Enter from listening.
    var onEndpoint: (() -> Void)?

    /// Fired once per recording when speech is first detected. Used while an
    /// answer is shown (mic open, "Ready" still on screen) to flip into
    /// listening the moment the user starts a follow-up — hands-free both ways.
    var onSpeechStart: (() -> Void)?

    // Silence-based endpointing. A cheap RMS gate ticks on its own cadence
    // (decoupled from transcription latency) and fires `onEndpoint` once the
    // speaker has talked for at least `preferences.minSpeech` and then fallen
    // quiet for `preferences.endpointSilence`. Thresholds live in `Preferences`.
    private var endpointTask: Task<Void, Never>?

    /// Requests mic access and loads the transcription backend (downloading
    /// models/assets on first run). Idempotent — safe to call at launch and
    /// again on the first Tab switch into voice. Runs in the background.
    func prepare() {
        guard !prepared else { return }
        prepared = true

        // Request mic access independently so it never blocks model loading.
        Task { await requestMicAccess() }
        Task { await transcriber.prepare() }
    }

    /// Starts capturing audio. Recording does not need the model loaded — the
    /// model is only required at transcription time — so this never blocks even
    /// in the brief window right after launch.
    /// `preview` runs the live transcript loop; pass `false` to arm the mic for a
    /// follow-up while an answer is still shown — only the cheap RMS endpoint loop
    /// runs (no transcribing the user's reading-silence), and `enableLivePreview()`
    /// starts the transcript loop once they actually speak.
    func startRecording(preview: Bool = true) {
        if preview {
            transcriber.begin()
            previewing = true
            let transcriber = self.transcriber
            recorder.setBufferSink { transcriber.append($0) }
        } else {
            previewing = false
            recorder.setBufferSink(nil)
        }

        do {
            try recorder.start()
        } catch {
            Log.error("recording.start", "\(error)")
            if previewing { transcriber.cancel(); previewing = false }
            return
        }
        Log.voice("recording.start", ["preview": preview])
        onPartialTranscript?("")
        startEndpointLoop()
    }

    /// Starts the live transcript loop on an already-running recording. Used when
    /// a follow-up (armed with `preview: false`) turns into real listening. Primes
    /// the transcriber with the last moment of audio so the first words — captured
    /// before onset flipped us here — aren't lost, then streams the rest.
    func enableLivePreview() {
        guard recorder.isRecording, !previewing else { return }
        transcriber.begin()
        previewing = true
        transcriber.append(recorder.trailing(seconds: preferences.onsetSpeech + 0.3))
        let transcriber = self.transcriber
        recorder.setBufferSink { transcriber.append($0) }
    }

    /// Stops recording, transcribes the clip, and sends the transcript to Codex,
    /// reporting the answer (or a failure) through the callbacks.
    func finishAndRespond() {
        endpointTask?.cancel()
        endpointTask = nil
        recorder.setBufferSink(nil)
        _ = recorder.stop()

        guard previewing else {
            Log.voice("capture.empty")
            onNoResponse?(nil)
            return
        }
        previewing = false

        Task {
            let prompt = await transcriber.finish()
            guard !prompt.isEmpty else {
                Log.voice("capture.empty")
                onNoResponse?(nil)
                return
            }
            Log.turnUser(source: .voice, text: prompt)
            onFinalTranscript?(prompt)

            do {
                let answer = try await codex.send(
                    prompt, history: history, effort: preferences.reasoningEffort,
                    onTool: { [weak self] event in
                        Task { @MainActor in self?.onToolEvent?(event) }
                    })
                history.append(CodexClient.Turn(role: .user, text: prompt))
                history.append(CodexClient.Turn(role: .assistant, text: answer))
                Log.turnAssistant(text: answer)
                onResponse?(answer)
            } catch let error as CodexClient.CodexError {
                onNoResponse?(error.localizedDescription)
            } catch {
                Log.error("codex.send", "\(error)")
                onNoResponse?("Something went wrong")
            }
        }
    }

    /// Sends an already-composed message (text mode) straight to Codex, skipping
    /// the mic and transcription. Reuses the same history and callbacks as the
    /// voice path so the UI and conversation context stay identical.
    func submitText(_ text: String) {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            onNoResponse?(nil)
            return
        }

        Task {
            do {
                Log.turnUser(source: .text, text: prompt)
                // Unlike voice, text mode deliberately skips `onFinalTranscript`:
                // it drives the voice teleprompter (`TranscriptText`), which can't
                // wrap a long unbreakable token (e.g. a pasted URL) and overflows
                // the pill. The message already shows via the wrapping echo
                // (`IslandState.userMessage` / `showsUserText`).

                let answer = try await codex.send(
                    prompt, history: history, effort: preferences.reasoningEffort,
                    onTool: { [weak self] event in
                        Task { @MainActor in self?.onToolEvent?(event) }
                    })
                history.append(CodexClient.Turn(role: .user, text: prompt))
                history.append(CodexClient.Turn(role: .assistant, text: answer))
                Log.turnAssistant(text: answer)
                onResponse?(answer)
            } catch let error as CodexClient.CodexError {
                onNoResponse?(error.localizedDescription)
            } catch {
                Log.error("submit", "\(error)")
                onNoResponse?("Something went wrong")
            }
        }
    }

    /// Stops recording and discards the clip without transcribing or sending —
    /// used when the user toggles Isle off mid-listen. Safe to call when not
    /// recording. The conversation history is left intact.
    func cancelRecording() {
        endpointTask?.cancel()
        endpointTask = nil
        recorder.setBufferSink(nil)
        _ = recorder.stop()
        if previewing {
            transcriber.cancel()
            previewing = false
        }
    }

    /// Forgets the conversation so the next request starts a fresh context.
    func clearHistory() {
        history.removeAll()
        Log.endConversation()
    }

    /// The running conversation, so `AppDelegate` can persist the live chat after
    /// each answer.
    var currentHistory: [CodexClient.Turn] { history }

    /// Replace the conversation with a saved chat's transcript (reinstating it),
    /// so a follow-up is answered in that chat's context. `codex exec` is
    /// one-shot, so restoring the replayed history is all that's needed.
    func loadHistory(_ turns: [CodexClient.Turn]) {
        history = turns
    }

    /// Ticks a cheap RMS silence gate on a fixed cadence while recording. Once
    /// the speaker has talked for `minSpeech` and then stayed quiet for
    /// `endpointSilence`, fires `onEndpoint` (the auto-submit cue) and stops.
    /// Kept separate from the partial loop so transcription latency never skews
    /// the silence timing.
    private func startEndpointLoop() {
        endpointTask?.cancel()
        let interval = preferences.endpointInterval
        let tick = Double(interval.components.seconds)
            + Double(interval.components.attoseconds) / 1e18
        endpointTask = Task { [weak self] in
            var speech = 0.0
            var silence = 0.0
            var onsetFired = false
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, !Task.isCancelled, self.recorder.isRecording else { return }

                let rms = self.recorder.trailingRMS(seconds: self.preferences.endpointWindow)
                if rms >= self.preferences.silenceThreshold {
                    speech += tick
                    silence = 0
                    if !onsetFired, speech >= self.preferences.onsetSpeech {
                        onsetFired = true
                        Log.voice("speech.onset")
                        self.onSpeechStart?()
                    }
                } else if onsetFired {
                    // Arm the silence gate on onset (≥ onsetSpeech of speech
                    // confirmed), not a separate higher `minSpeech` bar: when the
                    // mic is quiet, `speech` can plateau just under `minSpeech` and
                    // deadlock, so the turn never auto-submits.
                    silence += tick
                    if silence >= self.preferences.endpointSilence {
                        self.endpointTask = nil
                        Log.voice("endpoint")
                        self.onEndpoint?()
                        return
                    }
                }
            }
        }
    }

    private func requestMicAccess() async {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { _ in continuation.resume() }
        }
    }
}
