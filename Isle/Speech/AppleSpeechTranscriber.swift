//
//  AppleSpeechTranscriber.swift
//  Isle
//

import AVFoundation
import Foundation
import Speech

/// Apple's on-device `SpeechAnalyzer` / `SpeechTranscriber` (macOS 26+). Locale
/// model assets are managed by the OS — downloaded once, shared system-wide — so
/// there's no app-owned model blob.
///
/// **Batch, not streaming** — structured exactly like `ParakeetTranscriber`.
/// Pushed audio is accumulated into a buffer; a fresh, short-lived `SpeechAnalyzer`
/// re-transcribes the whole clip from scratch on a timer for the live preview, and
/// once more in `finish()`. SpeechAnalyzer's incremental/volatile streaming lags
/// badly in a push setup (seconds to first result, far worse when primed with a
/// catch-up burst), but its `finalize` path is fast — so we only ever use that,
/// one self-contained analyzer per transcription. Stateless per call: nothing
/// accumulates or wedges. Only the OS-cached models are long-lived (warmed once).
final class AppleSpeechTranscriber: Transcriber, @unchecked Sendable {

    var onPreview: ((String) -> Void)?

    private let locale: Locale
    private var resolvedLocale: Locale?
    private var analyzerFormat: AVAudioFormat?
    private var prepared = false

    /// Pushed audio for this utterance. Guarded because `append` runs on the
    /// audio thread while the preview loop reads it.
    private let lock = NSLock()
    private var buffer: [Float] = []

    private var previewTask: Task<Void, Never>?
    private var previewInFlight = false
    private let previewInterval: Duration

    /// Skip clips too short to be worth a model pass.
    private let minSamples = 16_000 * 4 / 10  // 0.4 s at 16 kHz
    /// Feed the clip to the analyzer in ~0.5 s slices.
    private let feedChunk = 8_000

    /// 16 kHz mono Float — what `AudioRecorder` produces.
    private let inputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    init(locale: Locale = .current, previewInterval: Duration = .milliseconds(500)) {
        self.locale = locale
        self.previewInterval = previewInterval
    }

    // MARK: - Lifecycle

    func prepare() async {
        guard !prepared else { return }
        do {
            let auth = await requestAuthorization()
            Log.voice("asr.auth", ["status": "\(auth)"])

            guard let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
                Log.error("asr.load", "locale \(locale.identifier) unsupported by SpeechTranscriber")
                return
            }
            let transcriber = makeTranscriber(locale: resolved)
            try await ensureAssets(for: transcriber, locale: resolved)
            resolvedLocale = resolved
            analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
            prepared = true
            Log.voice("asr.loaded", [
                "backend": "apple", "locale": resolved.identifier,
                "format": analyzerFormat.map { "\(Int($0.sampleRate))Hz/\($0.channelCount)ch" } ?? "nil"])

            // Warm the ANE program so the first real batch isn't a cold start.
            _ = await batchTranscribe([Float](repeating: 0, count: 16_000 / 5))
        } catch {
            Log.error("asr.load", "\(error)")
        }
    }

    private func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        if SFSpeechRecognizer.authorizationStatus() == .authorized { return .authorized }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }

    private func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [])
    }

    private func ensureAssets(for transcriber: SpeechTranscriber, locale: Locale) async throws {
        let installed = await SpeechTranscriber.installedLocales
        if installed.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) { return }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            Log.voice("asr.assets.download", ["locale": locale.identifier])
            try await request.downloadAndInstall()
        }
    }

    // MARK: - Utterance

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
        return await batchTranscribe(snapshot())
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

    /// Re-transcribes the growing buffer on a timer and emits the running text.
    private func startPreviewLoop() {
        previewTask?.cancel()
        previewTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: self.previewInterval)
                if Task.isCancelled { return }
                if self.previewInFlight { continue }
                self.previewInFlight = true
                let text = await self.batchTranscribe(self.snapshot())
                self.previewInFlight = false
                if Task.isCancelled || text.isEmpty { continue }
                let onPreview = self.onPreview
                await MainActor.run { onPreview?(text) }
            }
        }
    }

    /// One self-contained transcription of `samples`: a fresh analyzer consumes
    /// the whole clip, is finalized, and torn down. Returns "" for a clip too
    /// short, on a transient failure, or if the bounded finalize times out.
    private func batchTranscribe(_ samples: [Float]) async -> String {
        guard prepared, let resolvedLocale, samples.count >= minSamples else { return "" }

        let transcriber = makeTranscriber(locale: resolvedLocale)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()

        let box = TextBox()
        let results = Task {
            do {
                for try await result in transcriber.results {
                    box.append(String(result.text.characters))
                }
            } catch {}
        }
        let start = Task { try? await analyzer.start(inputSequence: stream) }

        var offset = 0
        while offset < samples.count {
            let end = min(offset + feedChunk, samples.count)
            if let buffer = makeBuffer(Array(samples[offset..<end])) {
                continuation.yield(AnalyzerInput(buffer: buffer))
            }
            offset = end
        }
        continuation.finish()

        let finalize = Task { _ = try? await analyzer.finalizeAndFinishThroughEndOfInput() }
        await Self.race(results, timeout: .seconds(4))
        finalize.cancel()
        start.cancel()
        results.cancel()
        Task { try? await analyzer.cancelAndFinishNow() }

        return box.text().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Helpers

    /// Thread-safe accumulator for a batch's results (finalized text wins; the
    /// last volatile is a fallback if no final arrives).
    private final class TextBox: @unchecked Sendable {
        private let lock = NSLock()
        private var accumulated = ""
        func append(_ piece: String) {
            let s = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty else { return }
            lock.lock(); accumulated = accumulated.isEmpty ? s : accumulated + " " + s; lock.unlock()
        }
        func text() -> String { lock.lock(); defer { lock.unlock() }; return accumulated }
    }

    /// Returns when `work` finishes or `timeout` elapses, whichever comes first,
    /// WITHOUT awaiting the loser — so a stuck `work` can't block the caller.
    private static func race(_ work: Task<Void, Never>, timeout: Duration) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let gate = ResumeOnce(continuation)
            Task { await work.value; gate.resume() }
            Task { try? await Task.sleep(for: timeout); gate.resume() }
        }
    }

    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }
        func resume() {
            lock.lock(); let c = continuation; continuation = nil; lock.unlock()
            c?.resume()
        }
    }

    /// Wraps 16 kHz mono samples in an `AVAudioPCMBuffer`, converting to the
    /// analyzer's preferred format when it differs.
    private func makeBuffer(_ samples: [Float]) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(samples.count))
        else { return nil }
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            input.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }

        guard let outputFormat = analyzerFormat, outputFormat != inputFormat else { return input }
        let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        guard let converter else { return input }

        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(samples.count) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return input }

        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return input
        }
        return output.frameLength > 0 ? output : input
    }
}
