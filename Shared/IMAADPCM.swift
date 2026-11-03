import Foundation

/// IMA ADPCM, 4:1. Chosen over Opus for v1 because it is ~40 lines on both
/// Swift and the ESP32 and needs no library; 16 kHz becomes 8 KB/s, which BLE
/// carries comfortably.
enum IMAADPCM {
    struct State {
        var predictor: Int = 0
        var index: Int = 0
    }

    struct Block {
        let predictor: Int16
        let index: UInt8
        let bytes: Data
    }

    private static let indexTable: [Int] = [-1, -1, -1, -1, 2, 4, 6, 8, -1, -1, -1, -1, 2, 4, 6, 8]

    private static let stepTable: [Int] = [
        7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45,
        50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143, 157, 173, 190, 209, 230,
        253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658, 724, 796, 876, 963,
        1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327,
        3660, 4026, 4428, 4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487,
        12635, 13899, 15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767,
    ]

    /// Encodes `samples` starting from `state`, and advances `state`.
    /// An odd sample count is padded with one repeated sample.
    static func encode(_ samples: ArraySlice<Int16>, state: inout State) -> Block {
        let header = Block(predictor: Int16(state.predictor), index: UInt8(state.index), bytes: Data())
        var bytes = Data(capacity: (samples.count + 1) / 2)
        var low: UInt8?
        for sample in samples {
            let code = encodeSample(sample, state: &state)
            if let pending = low {
                bytes.append(pending | (code << 4))
                low = nil
            } else {
                low = code
            }
        }
        if let pending = low {
            let pad = encodeSample(samples.last ?? 0, state: &state)
            bytes.append(pending | (pad << 4))
        }
        return Block(predictor: header.predictor, index: header.index, bytes: bytes)
    }

    static func decode(_ block: Block) -> [Int16] {
        var state = State(predictor: Int(block.predictor), index: min(Int(block.index), 88))
        var output = [Int16]()
        output.reserveCapacity(block.bytes.count * 2)
        for byte in block.bytes {
            output.append(decodeNibble(byte & 0x0F, state: &state))
            output.append(decodeNibble(byte >> 4, state: &state))
        }
        return output
    }

    private static func encodeSample(_ sample: Int16, state: inout State) -> UInt8 {
        var step = stepTable[state.index]
        var diff = Int(sample) - state.predictor
        var code = 0
        if diff < 0 {
            code = 8
            diff = -diff
        }
        var delta = step >> 3
        if diff >= step { code |= 4; diff -= step; delta += step }
        step >>= 1
        if diff >= step { code |= 2; diff -= step; delta += step }
        step >>= 1
        if diff >= step { code |= 1; delta += step }
        apply(code: code, delta: delta, state: &state)
        return UInt8(code)
    }

    private static func decodeNibble(_ nibble: UInt8, state: inout State) -> Int16 {
        let code = Int(nibble)
        let step = stepTable[state.index]
        var delta = step >> 3
        if code & 4 != 0 { delta += step }
        if code & 2 != 0 { delta += step >> 1 }
        if code & 1 != 0 { delta += step >> 2 }
        apply(code: code, delta: delta, state: &state)
        return Int16(state.predictor)
    }

    private static func apply(code: Int, delta: Int, state: inout State) {
        let predicted = state.predictor + (code & 8 != 0 ? -delta : delta)
        state.predictor = min(max(predicted, Int(Int16.min)), Int(Int16.max))
        state.index = min(max(state.index + indexTable[code], 0), stepTable.count - 1)
    }
}
