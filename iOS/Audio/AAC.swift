import AVFoundation

/// Compresses a recording for upload. A 16 kHz WAV is 32 KB a second, and the
/// upload was the slow part when the phone was idle (2.4 s for 6 s of speech
/// on Wi-Fi). AAC at 32 kbps is an eighth of that, and Whisper reads it the
/// same. The WAV is still what gets kept for playback.
enum AAC {
    static func encode(_ samples: [Int16], sampleRate: Int) throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        defer { try? FileManager.default.removeItem(at: url) }

        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(sampleRate),
                                         channels: 1, interleaved: true),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { throw CocoaError(.fileWriteUnknown) }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.int16ChannelData![0].update(from: source.baseAddress!, count: samples.count)
        }

        // Scoped so the file is closed, and its header written, before reading.
        do {
            let file = try AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 32_000,
            ], commonFormat: .pcmFormatInt16, interleaved: true)
            try file.write(from: buffer)
        }
        return try Data(contentsOf: url)
    }
}
