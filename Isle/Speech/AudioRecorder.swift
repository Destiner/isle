//
//  AudioRecorder.swift
//  Isle
//

import AVFoundation

/// Captures microphone audio and resamples it to 16 kHz mono Float — the common
/// input format the transcription backends consume (Parakeet directly; the Apple
/// backend converts on to its analyzer format). Recording runs while the pill is
/// visible.
final class AudioRecorder {

    /// Thread-safe sample sink: the audio tap runs off the main thread.
    private final class SampleBox: @unchecked Sendable {
        private let lock = NSLock()
        private var samples: [Float] = []

        func append(_ new: [Float]) {
            lock.lock(); samples.append(contentsOf: new); lock.unlock()
        }

        func drain() -> [Float] {
            lock.lock(); defer { samples.removeAll(keepingCapacity: true); lock.unlock() }
            return samples
        }

        /// A copy of the samples captured so far, leaving the buffer intact.
        func snapshot() -> [Float] {
            lock.lock(); defer { lock.unlock() }
            return samples
        }

        /// RMS energy over the trailing `n` samples, without copying the buffer.
        /// Returns 0 when empty. Used for cheap silence-based endpointing.
        func trailingRMS(sampleCount n: Int) -> Float {
            lock.lock(); defer { lock.unlock() }
            let count = samples.count
            guard count > 0 else { return 0 }
            let start = max(0, count - n)
            var sum: Float = 0
            for i in start..<count { sum += samples[i] * samples[i] }
            return (sum / Float(count - start)).squareRoot()
        }

        /// A copy of the trailing `n` samples. Used to prime a streaming
        /// transcriber with the first words when a follow-up flips into listening.
        func trailing(sampleCount n: Int) -> [Float] {
            lock.lock(); defer { lock.unlock() }
            let start = max(0, samples.count - n)
            return Array(samples[start...])
        }
    }

    /// Forwards captured chunks to a streaming transcriber. Retargeted from the
    /// main actor (via `setBufferSink`) and read from the realtime audio thread,
    /// so it guards its target behind a lock.
    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var forward: (([Float]) -> Void)?
        func set(_ forward: (([Float]) -> Void)?) {
            lock.lock(); self.forward = forward; lock.unlock()
        }
        func feed(_ samples: [Float]) {
            lock.lock(); let forward = self.forward; lock.unlock()
            forward?(samples)
        }
    }

    private let engine = AVAudioEngine()
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
    )!
    private let box = SampleBox()
    private let sink = Sink()
    private(set) var isRecording = false

    /// Sets (or clears with `nil`) the sink that receives each captured 16 kHz
    /// chunk. Live-toggleable mid-recording, so a follow-up can start feeding a
    /// transcriber the moment speech is detected. Buffers are still accumulated
    /// for `trailingRMS`/`stop` regardless of the sink.
    func setBufferSink(_ forward: (([Float]) -> Void)?) { sink.set(forward) }

    func start() throws {
        guard !isRecording else { return }
        _ = box.drain()

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        // After an engine stop/start the input node can briefly report a 0 Hz
        // format; bail rather than build a broken converter.
        guard inputFormat.sampleRate > 0,
              let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            Log.error("recording.format", "invalid input format \(inputFormat.sampleRate)Hz")
            return
        }
        let target = targetFormat
        let box = self.box
        let sink = self.sink

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            let ratio = target.sampleRate / inputFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }

            var consumed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if consumed { status.pointee = .noDataNow; return nil }
                consumed = true
                status.pointee = .haveData
                return buffer
            }

            guard out.frameLength > 0, let channel = out.floatChannelData else { return }
            let samples = Array(UnsafeBufferPointer(start: channel[0], count: Int(out.frameLength)))
            box.append(samples)
            sink.feed(samples)
        }

        engine.prepare()
        try engine.start()
        isRecording = true
    }

    /// The audio captured so far, without stopping or clearing the buffer.
    /// Used for live partial transcription while recording is ongoing.
    func snapshot() -> [Float] { box.snapshot() }

    /// RMS energy of the trailing `seconds` of captured audio, leaving the
    /// buffer intact. Used for silence-based endpointing while recording.
    func trailingRMS(seconds: Double) -> Float {
        box.trailingRMS(sampleCount: Int(seconds * targetFormat.sampleRate))
    }

    /// The trailing `seconds` of captured audio, leaving the buffer intact. Used
    /// to prime a streaming transcriber with the first words of a follow-up.
    func trailing(seconds: Double) -> [Float] {
        box.trailing(sampleCount: Int(seconds * targetFormat.sampleRate))
    }

    /// Stops recording and returns the captured 16 kHz mono samples.
    func stop() -> [Float] {
        guard isRecording else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        sink.set(nil)
        return box.drain()
    }
}
