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

    /// How often the accumulating buffer is re-transcribed for a live preview.
    private let partialInterval: Duration = .milliseconds(350)
    /// Parakeet rejects clips shorter than 0.3 s; require a touch more.
    private let minPartialSamples = 16_000 * 4 / 10  // 0.4 s at 16 kHz
    private var partialTask: Task<Void, Never>?
    private var partialInFlight = false

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
    func startRecording() {
        do {
            try recorder.start()
        } catch {
            NSLog("Isle: failed to start recording: \(error)")
            return
        }
        onPartialTranscript?("")
        startPartialLoop()
    }

    /// Stops recording, transcribes the clip, and sends the transcript to Codex,
    /// reporting the answer (or a failure) through the callbacks.
    func finishAndRespond() {
        partialTask?.cancel()
        partialTask = nil

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
