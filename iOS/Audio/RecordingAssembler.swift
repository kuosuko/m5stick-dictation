import Foundation

struct Recording: Sendable {
    let session: UInt8
    let samples: [Int16]
    let receivedPackets: Int
    let expectedPackets: Int
    /// When the phone saw START; set by StickLink.
    var startedAt: Date?

    var duration: TimeInterval { Double(samples.count) / Double(StickProtocol.sampleRate) }
    var missingPackets: Int { max(expectedPackets - receivedPackets, 0) }
}

/// Turns the TX notification stream back into one recording per session.
struct RecordingAssembler {
    enum Event {
        case started(UInt8)
        /// Loudness of one audio packet, 0…1, for a live level meter.
        case level(Double)
        case finished(Recording)
        case cancelled(UInt8)
    }

    private var session: UInt8?
    private var blocks: [UInt16: [Int16]] = [:]

    /// RMS mapped onto a rough dB scale, so speech fills the meter and silence sits low.
    static func level(of samples: [Int16]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        let rms = sqrt(sum / Double(samples.count)) / Double(Int16.max)
        let db = 20 * log10(max(rms, 0.000_01))
        return min(max((db + 50) / 44, 0), 1)
    }

    mutating func receive(_ data: Data) -> Event? {
        guard data.count >= 2, let type = StickProtocol.StickMessage(rawValue: data[data.startIndex]) else { return nil }
        let packetSession = data[data.startIndex + 1]

        switch type {
        case .settings, .sleeping:
            return nil

        case .start:
            session = packetSession
            blocks = [:]
            return .started(packetSession)

        case .audio:
            guard packetSession == session, data.count > StickProtocol.audioHeaderSize else { return nil }
            let seq = data.uint16LE(at: 2)
            let block = IMAADPCM.Block(
                predictor: Int16(bitPattern: data.uint16LE(at: 4)),
                index: data[data.startIndex + 6],
                bytes: data.dropFirst(StickProtocol.audioHeaderSize)
            )
            let samples = IMAADPCM.decode(block)
            blocks[seq] = samples
            return .level(Self.level(of: samples))

        case .end:
            guard packetSession == session, data.count >= 4 else { return nil }
            let expected = Int(data.uint16LE(at: 2))
            let samples = blocks.keys.sorted().flatMap { blocks[$0] ?? [] }
            let recording = Recording(
                session: packetSession,
                samples: samples,
                receivedPackets: blocks.count,
                expectedPackets: expected
            )
            session = nil
            blocks = [:]
            return .finished(recording)

        case .cancel:
            guard packetSession == session else { return nil }
            session = nil
            blocks = [:]
            return .cancelled(packetSession)
        }
    }
}
