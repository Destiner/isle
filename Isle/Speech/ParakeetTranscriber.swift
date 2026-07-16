//
//  ParakeetTranscriber.swift
//  Isle
//

import Foundation
import FluidAudio

/// Parakeet speech-to-text via FluidAudio (CoreML / Neural Engine). Accumulates
/// pushed audio and re-transcribes the whole clip from scratch on a timer for the
/// live preview (clean text, no token-stitching); `finish()` runs one final pass
/// over everything captured. Uses Parakeet **v2** (English-only) — switch to
/// `.v3` for multilingual.
///
/// Selecting this backend triggers a one-time ~450 MB model download on first
/// use, cached under `~/Library/Application Support/FluidAudio/Models/`.
final class ParakeetTranscriber: Transcriber, @unchecked Sendable {

    var onPreview: ((String) -> Void)?

    private var asr: AsrManager?

    /// Pushed audio for this utterance. Guarded because `append` runs on the
    /// audio thread while the preview loop reads it.
    private let lock = NSLock()
    private var buffer: [Float] = []

    private var previewTask: Task<Void, Never>?
    private let previewInterval: Duration

    /// Parakeet rejects clips shorter than 0.3 s; require a touch more.
    private let minSamples = 16_000 * 4 / 10  // 0.4 s at 16 kHz

    init(previewInterval: Duration = .milliseconds(350)) {
        self.previewInterval = previewInterval
    }

    func prepare() async {
        guard asr == nil else { return }
        do {
            let models = try await AsrModels.downloadAndLoad(version: .v2)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            asr = manager
            Log.voice("asr.loaded", ["backend": "parakeet"])
        } catch {
            Log.error("asr.load", "\(error)")
        }
    }

    func begin() {
        lock.lock(); buffer.removeAll(keepingCapacity: true); lock.unlock()
        startPreviewLoop()
    }

    func append(_ samples: [Float]) {
        lock.lock(); buffer.append(contentsOf: samples); lock.unlock()
    }

    func finish() async -> String {
        previewTask?.cancel()
        previewTask = nil
        return await transcribeBuffer() ?? ""
    }

    func cancel() {
        previewTask?.cancel()
        previewTask = nil
        lock.lock(); buffer.removeAll(keepingCapacity: true); lock.unlock()
    }

    private func snapshot() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        return buffer
    }

    /// Re-transcribes the whole accumulated clip from a fresh decoder state.
    /// Returns nil for a clip too short for Parakeet, or on a transient failure.
    private func transcribeBuffer() async -> String? {
        guard let asr else { return nil }
        let samples = snapshot()
        guard samples.count >= minSamples else { return nil }
        do {
            var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
            let result = try await asr.transcribe(samples, decoderState: &state)
            return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    /// Periodically re-transcribes the growing buffer and emits the running text.
    /// Utterances are short enough that a full re-transcribe stays fast.
    private func startPreviewLoop() {
        previewTask?.cancel()
        previewTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: self.previewInterval)
                if Task.isCancelled { return }
                guard let text = await self.transcribeBuffer(), !text.isEmpty else { continue }
                if Task.isCancelled { return }
                let onPreview = self.onPreview
                await MainActor.run { onPreview?(text) }
            }
        }
    }
}
