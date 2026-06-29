//
//  AudioRecorder.swift
//  Isle
//

import AVFoundation

/// Captures microphone audio and resamples it to 16 kHz mono Float — the format
/// FluidAudio's Parakeet model expects. Recording runs while the fn key is held.
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

    /// Stops recording and returns the captured 16 kHz mono samples.
    func stop() -> [Float] {
        guard isRecording else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        return box.drain()
    }
}
