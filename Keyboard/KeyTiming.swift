import Foundation

/// Measures how quickly keys respond on a real device: how long a touch
/// takes to reach the key, and how long the key's work holds the main
/// thread. Written to the App Group's Library/Caches when the keyboard
/// goes away, where `devicectl device copy from` can read it.
@MainActor
final class KeyTiming {
    static let shared = KeyTiming()

    private struct Sample: Codable {
        /// Touch-down event to the key hearing about it, in ms.
        var delivery: Double
        /// The key's action on the main thread, in ms.
        var work: Double
        var key: String
    }

    private var samples: [Sample] = []
    /// One-off durations in ms: process launch to first appearance, engine load.
    private var marks: [String: [Double]] = [:]
    var loadedAt: Date?
    private var hasAppeared = false
    private var pendingDelivery: [String: Double] = [:]
    /// What happened when a Stick result was offered, newest last.
    private var events: [String] = []

    func note(_ event: String) {
        events.append(Date.now.formatted(.dateTime.hour().minute().second()) + " " + event)
        if events.count > 60 { events.removeFirst(events.count - 60) }
    }
    private static let limit = 600

    /// SwiftUI stamps touch events with time since boot, wrapped in a Date
    /// counted from the reference date, not wall-clock time.
    func touchDown(key: String, eventTime: Date) {
        let delay = ProcessInfo.processInfo.systemUptime - eventTime.timeIntervalSinceReferenceDate
        pendingDelivery[key] = (0...5).contains(delay) ? delay * 1000 : -1
    }

    /// Times one step of a key's work under `name`.
    func time<T>(_ name: String, _ work: () -> T) -> T {
        let start = Date.now
        let result = work()
        mark(name, since: start)
        return result
    }

    func measure(key: String, _ action: () -> Void) {
        let start = Date.now
        action()
        let work = Date.now.timeIntervalSince(start) * 1000
        samples.append(Sample(delivery: pendingDelivery.removeValue(forKey: key) ?? -1, work: work, key: key))
        if samples.count > Self.limit { samples.removeFirst(samples.count - Self.limit) }
    }

    func mark(_ name: String, since start: Date) {
        var values = marks[name, default: []]
        values.append(Date.now.timeIntervalSince(start) * 1000)
        if values.count > Self.limit { values.removeFirst(values.count - Self.limit) }
        marks[name] = values
    }

    /// The first appearance of this process is a cold start; later ones are warm.
    func appeared() {
        if !hasAppeared, let launch = Self.processStart() { mark("launchToFirstAppear", since: launch) }
        if let loadedAt { mark(hasAppeared ? "warmLoadToAppear" : "coldLoadToAppear", since: loadedAt) }
        hasAppeared = true
    }

    func save() {
        guard !samples.isEmpty || !marks.isEmpty || !events.isEmpty,
              let folder = SharedInbox.fileURL?.deletingLastPathComponent()
                .appendingPathComponent("Library/Caches", isDirectory: true) else { return }
        let report: [String: AnyEncodable] = [
            "count": AnyEncodable(samples.count),
            "marks": AnyEncodable(marks.mapValues { Self.summary($0).merging(["n": Double($0.count)]) { a, _ in a } }),
            "delivery": AnyEncodable(Self.summary(samples.map(\.delivery).filter { $0 >= 0 })),
            "work": AnyEncodable(Self.summary(samples.map(\.work))),
            "recent": AnyEncodable(Array(samples.suffix(80))),
            "events": AnyEncodable(events),
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(report) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: folder.appendingPathComponent("keytiming.json"), options: .atomic)
    }

    /// When the kernel started this process, so the cold start includes launch.
    private static func processStart() -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
    }

    private static func summary(_ values: [Double]) -> [String: Double] {
        guard !values.isEmpty else { return [:] }
        let sorted = values.sorted()
        func at(_ p: Double) -> Double { sorted[min(Int(Double(sorted.count - 1) * p), sorted.count - 1)] }
        return ["p50": at(0.5), "p90": at(0.9), "max": sorted.last ?? 0]
    }
}

private struct AnyEncodable: Encodable {
    private let body: (Encoder) throws -> Void
    init<T: Encodable>(_ value: T) { body = value.encode }
    func encode(to encoder: Encoder) throws { try body(encoder) }
}
