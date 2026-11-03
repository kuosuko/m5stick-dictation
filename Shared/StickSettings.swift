import Foundation

/// What the phone can adjust on the stick (PROTOCOL.md, SETTINGS). The stick
/// keeps them across restarts and reports them whenever the phone connects.
struct StickSettings: Equatable, Sendable {
    enum Key: UInt8 {
        case brightness = 1, dimAfter, sleepAfter, micGain, findVolume, tapToLatch, deepSleepAfter, language
    }

    /// Backlight, 8–255.
    var brightness = 120
    /// Seconds idle before the screen dims; 0 = never.
    var dimAfter = 20
    /// Seconds idle before the screen turns off; 0 = never.
    var sleepAfter = 60
    /// Digital gain on top of the stick's fixed +30 dB analog stage, 0–32 dB.
    var micGain = 16
    /// Speaker volume while finding, 0–190; louder can brown out on battery.
    var findVolume = 150
    /// A short press starts recording and the next press sends it.
    var tapToLatch = true
    /// Seconds idle before the stick deep-sleeps; 0 = never. Waking costs
    /// less than waiting awake, so the default is short.
    var deepSleepAfter = 15
    /// The language on the stick's screen, following the app's. `nil` when
    /// the stick's firmware predates the setting.
    var language: Language?

    enum Language: UInt8, Sendable {
        case chinese = 0, english = 1

        /// The language the app itself is showing.
        static var app: Language {
            Bundle.main.preferredLocalizations.first?.hasPrefix("en") == true ? .english : .chinese
        }
    }

    init() {}

    /// From the stick's report: type, session, then key/value byte pairs.
    init?(report data: Data) {
        guard data.count >= 2, data[data.startIndex] == StickProtocol.StickMessage.settings.rawValue else { return nil }
        apply(pairs: data.dropFirst(2))
    }

    /// Unknown keys are skipped, so either side can add settings first.
    mutating func apply(pairs: Data) {
        let bytes = Array(pairs)
        for index in stride(from: 0, to: bytes.count - 1, by: 2) {
            let value = Int(bytes[index + 1])
            switch Key(rawValue: bytes[index]) {
            case .brightness: brightness = max(value, 8)
            case .dimAfter: dimAfter = value
            case .sleepAfter: sleepAfter = value
            case .micGain: micGain = min(value, 32)
            case .findVolume: findVolume = min(value, 190)
            case .tapToLatch: tapToLatch = value != 0
            case .deepSleepAfter: deepSleepAfter = value
            case .language: language = Language(rawValue: UInt8(value)) ?? .chinese
            case nil: break
            }
        }
    }

    var pairs: Data {
        Data([
            Key.brightness.rawValue, UInt8(clamping: brightness),
            Key.dimAfter.rawValue, UInt8(clamping: dimAfter),
            Key.sleepAfter.rawValue, UInt8(clamping: sleepAfter),
            Key.micGain.rawValue, UInt8(clamping: micGain),
            Key.findVolume.rawValue, UInt8(clamping: findVolume),
            Key.tapToLatch.rawValue, tapToLatch ? 1 : 0,
            Key.deepSleepAfter.rawValue, UInt8(clamping: deepSleepAfter),
        ] + (language.map { [Key.language.rawValue, $0.rawValue] } ?? []))
    }
}
