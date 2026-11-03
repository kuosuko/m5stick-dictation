import Foundation

/// Fixed screens for the simulator, which has no Bluetooth: launch with
/// `-demo ready|recording|transcribing|done|setup`.
struct DemoScenario {
    let phase: HomePhase
    let setup: SetupState
    let history: [Dictation]
    var battery: Int? = 82
    var pairing: StickLink.Pairing?
    var opensLab = false
    var opensFind = false

    /// The home screen as the Lab previews it.
    static let preview = DemoScenario(phase: .ready, setup: SetupState(stickPaired: true, keyboardReady: true, hasKey: true), history: sample)

    static func fromLaunchArguments() -> DemoScenario? {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-demo"), index + 1 < arguments.count else { return nil }
        let ready = SetupState(stickPaired: true, keyboardReady: true, hasKey: true)
        switch arguments[index + 1] {
        case "pairing":
            return DemoScenario(phase: .searching, setup: SetupState(stickPaired: false, keyboardReady: true, hasKey: true),
                                history: [], pairing: .found(name: "StickS3"))
        case "lab":
            return DemoScenario(phase: .ready, setup: ready, history: sample, opensLab: true)
        case "find":
            return DemoScenario(phase: .ready, setup: ready, history: sample, opensFind: true)
        case "paired":
            return DemoScenario(phase: .ready, setup: ready, history: [], pairing: .connected(name: "StickS3"))
        case "setup":
            return DemoScenario(phase: .searching, setup: SetupState(stickPaired: false, keyboardReady: false, hasKey: true), history: [])
        case "recording":
            let levels = [0.2, 0.45, 0.7, 0.5, 0.85, 0.6, 0.35, 0.75, 0.55, 0.4, 0.65, 0.3]
            return DemoScenario(phase: .recording(since: .now.addingTimeInterval(-3), levels: levels), setup: ready, history: sample)
        case "transcribing":
            return DemoScenario(phase: .transcribing(seconds: 3.8), setup: ready, history: sample)
        case "done":
            return DemoScenario(phase: .done(latency: 0.7), setup: ready, history: sample)
        default:
            return DemoScenario(phase: .ready, setup: ready, history: sample)
        }
        #else
        return nil
        #endif
    }

    private static func entry(_ text: String, minutesAgo: Double, seconds: Double, latency: Double,
                              heard: String? = nil) -> Dictation {
        Dictation(
            date: .now.addingTimeInterval(-minutesAgo * 60), text: text, error: nil,
            audioSeconds: seconds, latency: latency, missingPackets: 0, copied: false, wasInBackground: true,
            transcript: heard
        )
    }

    /// In the language the app is showing, so screenshots read in one language.
    private static var sample: [Dictation] {
        Bundle.main.preferredLocalizations.first?.hasPrefix("en") == true ? englishSample : chineseSample
    }

    private static let chineseSample: [Dictation] = [
        // Polish kept the correction: 台北 was taken back in the same breath.
        entry("我今天想去台中，晚上一起吃飯嗎？", minutesAgo: 0.1, seconds: 3.8, latency: 0.7,
              heard: "嗯我今天想去台北 不對是台中 晚上一起吃飯嗎"),
        entry("記得把簡報的第三頁換成新的數字。", minutesAgo: 12, seconds: 4.2, latency: 0.8),
        entry("Claude, make GTA 7. Make no mistakes.", minutesAgo: 47, seconds: 2.9, latency: 0.6),
        entry("幫我查一下明天早上的高鐵班次，九點以前到台中。", minutesAgo: 95, seconds: 5.6, latency: 0.9),
    ]

    private static let englishSample: [Dictation] = [
        entry("Want to grab dinner in Brooklyn tonight?", minutesAgo: 0.1, seconds: 3.4, latency: 0.7,
              heard: "um want to grab dinner in Queens no wait Brooklyn tonight"),
        entry("Swap the numbers on slide three for the new ones.", minutesAgo: 12, seconds: 4.0, latency: 0.8),
        entry("Claude, make GTA 7. Make no mistakes.", minutesAgo: 47, seconds: 2.9, latency: 0.6),
        entry("Find me a train tomorrow morning that gets to Boston before nine.", minutesAgo: 95, seconds: 5.2,
              latency: 0.9),
    ]
}
