import Foundation

enum WAV {
    /// 16-bit mono PCM with a 44-byte RIFF header.
    static func encode(_ samples: [Int16], sampleRate: Int) -> Data {
        let dataSize = UInt32(samples.count * 2)
        var data = Data(capacity: 44 + Int(dataSize))
        data.append(contentsOf: Array("RIFF".utf8))
        data.appendLE32(36 + dataSize)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        data.appendLE32(16)
        data.appendLE(1) // PCM
        data.appendLE(1) // mono
        data.appendLE32(UInt32(sampleRate))
        data.appendLE32(UInt32(sampleRate * 2))
        data.appendLE(2) // block align
        data.appendLE(16) // bits per sample
        data.append(contentsOf: Array("data".utf8))
        data.appendLE32(dataSize)
        samples.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
        return data
    }
}

private extension Data {
    mutating func appendLE32(_ value: UInt32) {
        appendLE(UInt16(value & 0xFFFF))
        appendLE(UInt16(value >> 16))
    }
}
