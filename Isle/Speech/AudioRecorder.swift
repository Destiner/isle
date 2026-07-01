//
//  AudioRecorder.swift
//  Isle
//

import AVFoundation

/// Captures microphone audio and resamples it to 16 kHz mono Float — the format
/// FluidAudio's Parakeet model expects. Recording runs while the pill is visible.
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
    }

    private let engine = AVAudioEngine()
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
    )!
    private let box = SampleBox()
    private(set) var isRecording = false

    func start() throws {
        guard !isRecording else { return }
        _ = box.drain()

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else { return }
        let target = targetFormat
        let box = self.box

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
            box.append(Array(UnsafeBufferPointer(start: channel[0], count: Int(out.frameLength))))
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

    /// Stops recording and returns the captured 16 kHz mono samples.
    func stop() -> [Float] {
        guard isRecording else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        return box.drain()
    }
}
