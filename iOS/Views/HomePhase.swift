import Foundation

/// The one thing the home screen is about right now.
enum HomePhase: Equatable {
    case bluetoothOff
    case unauthorized
    case searching
    case connecting
    /// The stick deep-sleeps when idle; pressing it wakes and reconnects.
    case asleep
    case ready
    case recording(since: Date, levels: [Double])
    case transcribing(seconds: Double)
    case done(latency: Double)
    case failed(String)

    /// How long a finished or failed result stays the headline.
    static let resultHold: TimeInterval = 8

    @MainActor
    static func current(link: StickLink, store: DictationStore, now: Date) -> HomePhase {
        if store.isTranscribing { return .transcribing(seconds: store.transcribingSeconds ?? 0) }
        if link.isRecording { return .recording(since: link.recordingStartedAt ?? now, levels: link.levels) }
        if let latest = store.history.first, now.timeIntervalSince(latest.date) < resultHold {
            if latest.text != nil { return .done(latency: latest.latency) }
            return .failed(latest.error ?? "")
        }
        switch link.status {
        case .bluetoothOff: return .bluetoothOff
        case .unauthorized: return .unauthorized
        case .searching: return .searching
        case .connecting: return link.isAsleep ? .asleep : .connecting
        case .connected: return .ready
        }
    }

    /// Stable identity for animating between phases (levels change every packet).
    var kind: String {
        switch self {
        case .bluetoothOff: "bluetoothOff"
        case .unauthorized: "unauthorized"
        case .searching: "searching"
        case .connecting: "connecting"
        case .asleep: "asleep"
        case .ready: "ready"
        case .recording: "recording"
        case .transcribing: "transcribing"
        case .done: "done"
        case .failed: "failed"
        }
    }

    var screen: StickScreen {
        switch self {
        case .bluetoothOff, .unauthorized, .searching, .connecting, .asleep: .off
        case .ready: .ready
        case .recording(_, let levels): .listening(levels: levels)
        case .transcribing: .working
        case .done: .done
        case .failed: .problem
        }
    }

    var title: String {
        switch self {
        case .bluetoothOff: String(localized: "藍牙關著")
        case .unauthorized: String(localized: "需要藍牙權限")
        case .searching: String(localized: "找不到 Stick")
        case .connecting: String(localized: "正在連線")
        case .asleep: String(localized: "Stick 在睡")
        case .ready: String(localized: "按住 Stick 說話")
        case .recording: String(localized: "正在聽")
        case .transcribing: String(localized: "轉寫中")
        case .done: String(localized: "已送到鍵盤")
        case .failed: String(localized: "沒有轉成功")
        }
    }

    func subtitle(now: Date) -> String {
        switch self {
        case .bluetoothOff: String(localized: "到控制中心打開藍牙")
        case .unauthorized: String(localized: "到設定 › Stick 允許藍牙")
        case .searching: String(localized: "打開 Stick，或在 Mac 上開 StickSim")
        case .connecting: String(localized: "Stick 在附近時會自動連上")
        case .asleep: String(localized: "按住它就醒，直接說")
        case .ready: String(localized: "放開後，文字會打進 Stick 鍵盤")
        case .recording(let since, _):
            Duration.seconds(max(now.timeIntervalSince(since), 0))
                .formatted(.time(pattern: .minuteSecond))
        case .transcribing(let seconds): String(format: String(localized: "%.1f 秒的錄音"), seconds)
        case .done(let latency): String(format: String(localized: "放開後 %.1f 秒完成"), latency)
        case .failed(let message): message
        }
    }
}
