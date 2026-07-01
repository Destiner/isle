//
//  DictationManager.swift
//  Isle
//

import AppKit
import AVFoundation
import FluidAudio

/// Records speech while Isle is visible and, on Enter, transcribes it
/// locally with Parakeet (via FluidAudio / CoreML), then sends the transcript to
/// Codex and reports back its answer. The model is downloaded once on first
/// launch and cached.
@MainActor
final class DictationManager {
    private let recorder = AudioRecorder()
    private let codex = CodexClient()
    private var asr: AsrManager?
    private var isTranscribing = false
    private var prepared = false

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

    /// Fired when the speaker has gone quiet after talking — the cue to submit
    /// the clip automatically. Wired to the same path as Enter from listening.
    var onEndpoint: (() -> Void)?

    /// Fired once per recording when speech is first detected. Used while an
    /// answer is shown (mic open, "Ready" still on screen) to flip into
    /// listening the moment the user starts a follow-up — hands-free both ways.
    var onSpeechStart: (() -> Void)?

    /// How often the accumulating buffer is re-transcribed for a live preview.
    private let partialInterval: Duration = .milliseconds(350)
    /// Parakeet rejects clips shorter than 0.3 s; require a touch more.
    private let minPartialSamples = 16_000 * 4 / 10  // 0.4 s at 16 kHz
    private var partialTask: Task<Void, Never>?
    private var partialInFlight = false

    // Silence-based endpointing. A cheap RMS gate ticks on its own cadence
    // (decoupled from transcription latency) and fires `onEndpoint` once the
    // speaker has talked for at least `minSpeech` and then fallen quiet for
    // `endpointSilence`. Thresholds are heuristic and hardware-dependent.
    private let endpointInterval: Duration = .milliseconds(150)
    private let endpointWindow: Double = 0.6      // trailing seconds measured for RMS
    private let silenceThreshold: Float = 0.008   // below this the window is "quiet"
    private let minSpeech: Double = 0.4           // speech needed before silence can end the turn
    private let endpointSilence: Double = 1.5     // sustained quiet that triggers submit
    private let onsetSpeech: Double = 0.2         // speech needed to flip a shown answer into listening
    private var endpointTask: Task<Void, Never>?

    /// Requests mic access and loads (downloading on first run) the English
    /// Parakeet v2 model. Idempotent — safe to call at launch and again on the
    /// first Tab switch into voice. Runs in the background.
    func prepare() {
        guard !prepared else { return }
        prepared = true

        // Request mic access independently so it never blocks the model download.
        Task { await requestMicAccess() }

        Task {
            do {
                let models = try await AsrModels.downloadAndLoad(version: .v2)
                let manager = AsrManager(config: .default)
                try await manager.loadModels(models)
                asr = manager
            } catch {
                NSLog("Isle: ASR model load failed: \(error)")
            }
        }
    }

    /// Starts capturing audio. Recording does not need the model loaded — the
    /// model is only required at transcription time — so this never blocks even
    /// in the brief window right after launch.
    /// `preview` runs the live transcript loop; pass `false` to arm the mic for a
    /// follow-up while an answer is still shown — only the cheap RMS endpoint loop
    /// runs (no transcribing the user's reading-silence), and `enableLivePreview()`
    /// starts the transcript loop once they actually speak.
    func startRecording(preview: Bool = true) {
        do {
            try recorder.start()
        } catch {
            NSLog("Isle: failed to start recording: \(error)")
            return
        }
        onPartialTranscript?("")
        if preview { startPartialLoop() }
        startEndpointLoop()
    }

    /// Starts the live transcript loop on an already-running recording. Used when
    /// a follow-up (armed with `preview: false`) turns into real listening.
    func enableLivePreview() {
        guard recorder.isRecording else { return }
        startPartialLoop()
    }

    /// Stops recording, transcribes the clip, and sends the transcript to Codex,
    /// reporting the answer (or a failure) through the callbacks.
    func finishAndRespond() {
        partialTask?.cancel()
        partialTask = nil
        endpointTask?.cancel()
        endpointTask = nil

        let samples = recorder.stop()
        guard let asr, !samples.isEmpty else {
            onNoResponse?(nil)
            return
        }

        Task {
            do {
                var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
                let result = try await asr.transcribe(samples, decoderState: &state)
                let prompt = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !prompt.isEmpty else {
                    onNoResponse?(nil)
                    return
                }
                onFinalTranscript?(prompt)

                let answer = try await codex.send(prompt, history: history)
                history.append(CodexClient.Turn(role: .user, text: prompt))
                history.append(CodexClient.Turn(role: .assistant, text: answer))
                onResponse?(answer)
            } catch let error as CodexClient.CodexError {
                NSLog("Isle: codex request failed: \(error)")
                onNoResponse?(error.localizedDescription)
            } catch {
                NSLog("Isle: transcription failed: \(error)")
                onNoResponse?("Couldn't transcribe that.")
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
                onFinalTranscript?(prompt)

                let answer = try await codex.send(prompt, history: history)
                history.append(CodexClient.Turn(role: .user, text: prompt))
                history.append(CodexClient.Turn(role: .assistant, text: answer))
                onResponse?(answer)
            } catch let error as CodexClient.CodexError {
                NSLog("Isle: codex request failed: \(error)")
                onNoResponse?(error.localizedDescription)
            } catch {
                NSLog("Isle: codex request failed: \(error)")
                onNoResponse?("Something went wrong.")
            }
        }
    }

    /// Stops recording and discards the clip without transcribing or sending —
    /// used when the user toggles Isle off mid-listen. Safe to call when not
    /// recording. The conversation history is left intact.
    func cancelRecording() {
        partialTask?.cancel()
        partialTask = nil
        endpointTask?.cancel()
        endpointTask = nil
        _ = recorder.stop()
    }

    /// Forgets the conversation so the next request starts a fresh context.
    func clearHistory() {
        history.removeAll()
    }

    /// Periodically re-transcribes the whole accumulated buffer while recording,
    /// emitting the running text so the UI can show speech as it's recognized.
    /// Re-transcribing from scratch (fresh decoder state) keeps the text clean
    /// without token-stitching; utterances are short enough that it stays fast.
    private func startPartialLoop() {
        partialTask?.cancel()
        partialTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: self?.partialInterval ?? .milliseconds(350))
                if Task.isCancelled { return }
                await self?.emitPartialTranscript()
            }
        }
    }

    /// Ticks a cheap RMS silence gate on a fixed cadence while recording. Once
    /// the speaker has talked for `minSpeech` and then stayed quiet for
    /// `endpointSilence`, fires `onEndpoint` (the auto-submit cue) and stops.
    /// Kept separate from the partial loop so transcription latency never skews
    /// the silence timing.
    private func startEndpointLoop() {
        endpointTask?.cancel()
        let tick = Double(endpointInterval.components.seconds)
            + Double(endpointInterval.components.attoseconds) / 1e18
        endpointTask = Task { [weak self] in
            var speech = 0.0
            var silence = 0.0
            var onsetFired = false
            while !Task.isCancelled {
                try? await Task.sleep(for: self?.endpointInterval ?? .milliseconds(150))
                guard let self, !Task.isCancelled, self.recorder.isRecording else { return }

                let rms = self.recorder.trailingRMS(seconds: self.endpointWindow)
                if rms >= self.silenceThreshold {
                    speech += tick
                    silence = 0
                    if !onsetFired, speech >= self.onsetSpeech {
                        onsetFired = true
                        self.onSpeechStart?()
                    }
                } else if speech >= self.minSpeech {
                    silence += tick
                    if silence >= self.endpointSilence {
                        self.endpointTask = nil
                        self.onEndpoint?()
                        return
                    }
                }
            }
        }
    }

    private func emitPartialTranscript() async {
        guard let asr, !partialInFlight else { return }
        let samples = recorder.snapshot()
        guard samples.count >= minPartialSamples else { return }

        partialInFlight = true
        defer { partialInFlight = false }
        do {
            var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
            let result = try await asr.transcribe(samples, decoderState: &state)
            guard !Task.isCancelled, recorder.isRecording else { return }
            onPartialTranscript?(result.text.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            // Transient (e.g. too-short clip mid-stream); the next tick retries.
        }
    }

    private func requestMicAccess() async {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { _ in continuation.resume() }
        }
    }
}
