//
//  DictationManager.swift
//  Isle
//

import AppKit
import AVFoundation
import Carbon.HIToolbox
import FluidAudio

/// Records speech while the fn key is held and, on release, transcribes it
/// locally with Parakeet (via FluidAudio / CoreML) and pastes the text into the
/// active app. The model is downloaded once on first launch and cached.
@MainActor
final class DictationManager {
    private let recorder = AudioRecorder()
    private var asr: AsrManager?
    private var isTranscribing = false

    /// Requests mic access and loads (downloading on first run) the English
    /// Parakeet v2 model. Safe to call once at launch; runs in the background.
    func prepare() {
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
        }
    }

    /// Stops recording, transcribes, and pastes the result into the active app.
    func finishAndPaste() {
        let samples = recorder.stop()
        guard let asr, !isTranscribing, !samples.isEmpty else { return }
        isTranscribing = true

        Task {
            defer { isTranscribing = false }
            do {
                var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
                let result = try await asr.transcribe(samples, decoderState: &state)
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                paste(text)
            } catch {
                NSLog("Isle: transcription failed: \(error)")
            }
        }
    }

    /// Puts the text on the clipboard and sends ⌘V to the frontmost app, then
    /// restores the previous clipboard contents.
    private func paste(_ text: String) {
        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey = CGKeyCode(kVK_ANSI_V)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)

        // Restore the prior clipboard once the paste has been delivered.
        if let previous {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                pasteboard.clearContents()
                pasteboard.setString(previous, forType: .string)
            }
        }
    }

    private func requestMicAccess() async {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { _ in continuation.resume() }
        }
    }
}
