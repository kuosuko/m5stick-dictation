import Foundation

/// Cuts the quiet before and after the speech in a recording, and tells
/// whether there was any speech at all. Whisper invents text for silence
/// ("謝謝觀看"), so a recording without speech is never sent.
enum SpeechTrim {
    struct Result: Equatable {
        let samples: [Int16]
        let hasSpeech: Bool
    }

    /// 20 ms frames.
    private static let frameSeconds = 0.02
    /// A frame is speech when it is this many times louder than the room…
    private static let aboveFloor = 3.5
    /// …and at least this loud (about -48 dBFS), so a silent room never counts.
    private static let minimumLevel = 0.004
    /// Less speech than this is a stray press or a click.
    private static let minimumSpeechSeconds = 0.16
    /// Kept around the speech, so soft starts and endings (ㄙ, ㄏ, "s") survive.
    private static let leadSeconds = 0.3
    private static let tailSeconds = 0.45

    static func trim(_ samples: [Int16], sampleRate: Int) -> Result {
        let frameLength = max(Int(Double(sampleRate) * frameSeconds), 1)
        let levels = stride(from: 0, to: samples.count, by: frameLength).map { start in
            rms(samples[start..<min(start + frameLength, samples.count)])
        }
        guard !levels.isEmpty else { return Result(samples: samples, hasSpeech: false) }

        // The room: the quieter end of the recording, which is the gaps between words.
        let floor = levels.sorted()[levels.count / 10]
        let threshold = max(floor * aboveFloor, minimumLevel)
        let voiced = levels.indices.filter { levels[$0] > threshold }

        let framesNeeded = Int((minimumSpeechSeconds / frameSeconds).rounded(.up))
        guard voiced.count >= framesNeeded, let first = voiced.first, let last = voiced.last else {
            return Result(samples: samples, hasSpeech: false)
        }
        let start = max((first - Int(leadSeconds / frameSeconds)) * frameLength, 0)
        let end = min((last + 1 + Int(tailSeconds / frameSeconds)) * frameLength, samples.count)
        return Result(samples: Array(samples[start..<end]), hasSpeech: true)
    }

    /// 0…1, where 1 is a full-scale square wave.
    private static func rms(_ frame: ArraySlice<Int16>) -> Double {
        guard !frame.isEmpty else { return 0 }
        let sum = frame.reduce(0.0) { $0 + Double($1) * Double($1) }
        return (sum / Double(frame.count)).squareRoot() / 32768
    }
}
