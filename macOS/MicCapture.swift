import AVFoundation
import os

/// Captures the default input and hands back 16 kHz mono Int16 chunks,
/// which is what the ES8311 on the real stick will produce.
@MainActor
final class MicCapture {
    private let engine = AVAudioEngine()
    private let logger = Logger(subsystem: "StickSim", category: "mic")

    var onSamples: (([Int16]) -> Void)?

    func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    func start() throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(StickProtocol.sampleRate),
            channels: 1,
            interleaved: true
        ), let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw CaptureError.unsupportedFormat
        }
        let resampler = Resampler(converter: converter, targetFormat: targetFormat)
        let tap = Self.makeTap(resampler: resampler) { [weak self] samples in
            Task { @MainActor in self?.onSamples?(samples) }
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat, block: tap)
        engine.prepare()
        try engine.start()
        logger.debug("mic started at \(inputFormat.sampleRate) Hz")
    }

    /// Built outside the main actor on purpose: a closure written inline in a
    /// @MainActor method inherits main-actor isolation, and Swift 6 traps when
    /// AVAudioEngine calls it on its realtime queue.
    private nonisolated static func makeTap(
        resampler: Resampler,
        deliver: @escaping @Sendable ([Int16]) -> Void
    ) -> AVAudioNodeTapBlock {
        { buffer, _ in
            let samples = resampler.convert(buffer)
            if !samples.isEmpty { deliver(samples) }
        }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    enum CaptureError: Error {
        case unsupportedFormat
    }
}

/// Only touched from the audio tap thread, one buffer at a time.
private final class Resampler: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let targetFormat: AVAudioFormat

    init(converter: AVAudioConverter, targetFormat: AVAudioFormat) {
        self.converter = converter
        self.targetFormat = targetFormat
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> [Int16] {
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return [] }

        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = output.int16ChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
    }
}
