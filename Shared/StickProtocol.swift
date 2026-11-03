import CoreBluetooth
import Foundation

/// Wire format shared by StickSim, the phone app and (later) the ESP32 firmware.
/// See PROTOCOL.md.
// CBUUID is immutable once created; it just is not annotated Sendable.
enum StickProtocol {
    nonisolated(unsafe) static let serviceUUID = CBUUID(string: "5A1D0001-8F3C-4C59-9B0A-6D2E5A7C1E01")
    nonisolated(unsafe) static let txUUID = CBUUID(string: "5A1D0002-8F3C-4C59-9B0A-6D2E5A7C1E01")
    nonisolated(unsafe) static let rxUUID = CBUUID(string: "5A1D0003-8F3C-4C59-9B0A-6D2E5A7C1E01")
    /// Standard Bluetooth Battery Service / Battery Level (one byte, 0–100).
    nonisolated(unsafe) static let batteryServiceUUID = CBUUID(string: "180F")
    nonisolated(unsafe) static let batteryLevelUUID = CBUUID(string: "2A19")
    static let localName = "StickS3"

    static let sampleRate = 16_000
    static let codecIMAADPCM: UInt8 = 1
    static let audioHeaderSize = 8
    static let maxTextBytes = 160

    enum StickMessage: UInt8 {
        case start = 0x01
        case audio = 0x02
        case end = 0x03
        case cancel = 0x04
        /// The stick's settings, on connect and after every change.
        case settings = 0x05
        /// Sent just before the stick deep-sleeps; a press wakes it.
        case sleeping = 0x06
    }

    enum PhoneMessage: UInt8 {
        case transcribing = 0x10
        case done = 0x11
        case error = 0x12
        /// Not tied to a recording: `session` is 0 and the stick ignores it.
        case find = 0x13
        /// Writes stick settings; `session` is 0.
        case settings = 0x14
    }

    // MARK: Stick → phone

    static func start(session: UInt8) -> Data {
        var data = Data([StickMessage.start.rawValue, session, codecIMAADPCM])
        data.appendLE(UInt16(sampleRate))
        return data
    }

    static func audio(session: UInt8, seq: UInt16, block: IMAADPCM.Block) -> Data {
        var data = Data([StickMessage.audio.rawValue, session])
        data.appendLE(seq)
        data.appendLE(UInt16(bitPattern: block.predictor))
        data.append(block.index)
        data.append(block.bytes)
        return data
    }

    static func end(session: UInt8, packetCount: UInt16) -> Data {
        var data = Data([StickMessage.end.rawValue, session])
        data.appendLE(packetCount)
        return data
    }

    static func cancel(session: UInt8) -> Data {
        Data([StickMessage.cancel.rawValue, session])
    }

    // MARK: Phone → stick

    static func phone(_ type: PhoneMessage, session: UInt8, text: String = "") -> Data {
        Data([type.rawValue, session]) + utf8Prefix(text, maxBytes: maxTextBytes)
    }

    /// Asks the stick to sound off (1) or stop (0), so it can be found.
    static func find(on: Bool) -> Data {
        Data([PhoneMessage.find.rawValue, 0, on ? 1 : 0])
    }

    static func settings(_ settings: StickSettings) -> Data {
        Data([PhoneMessage.settings.rawValue, 0]) + settings.pairs
    }

    static func settingsReport(_ settings: StickSettings) -> Data {
        Data([StickMessage.settings.rawValue, 0]) + settings.pairs
    }

    /// Cuts on a character boundary so the stick never receives half a CJK glyph.
    static func utf8Prefix(_ text: String, maxBytes: Int) -> Data {
        var result = Data()
        for character in text {
            let bytes = Data(String(character).utf8)
            if result.count + bytes.count > maxBytes { break }
            result.append(bytes)
        }
        return result
    }
}

extension Data {
    mutating func appendLE(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8(value >> 8))
    }

    func uint16LE(at offset: Int) -> UInt16 {
        let base = startIndex + offset
        return UInt16(self[base]) | (UInt16(self[base + 1]) << 8)
    }
}
