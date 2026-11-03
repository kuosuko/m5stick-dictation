import Foundation
import notify

/// Hand-off between the app (which may be woken in the background by the
/// stick) and the keyboard extension. iOS won't let a background app write the
/// pasteboard, so results land here and the keyboard inserts them.
enum SharedInbox {
    /// From Info.plist, named by the build's bundle prefix. A sideloaded copy
    /// re-signed by AltStore gets a new group, which AltStore lists first.
    static let groupID: String = {
        let info = Bundle.main.infoDictionary
        if let groups = info?["ALTAppGroups"] as? [String], let first = groups.first { return first }
        return info?["StickAppGroup"] as? String ?? "group.com.example.stickdictation"
    }()
    static let changedNotification = groupID + ".inbox-changed"
    static let maxItems = 20

    struct Item: Codable, Identifiable, Equatable {
        var id = UUID()
        let text: String
        let date: Date
    }

    enum Phase: String, Codable {
        case idle
        case recording
        case transcribing
        case failed
    }

    struct State: Codable, Equatable {
        var phase: Phase = .idle
        var message: String?
        var recent: [Item] = []
        var autoInsert = true
        /// Optional so inbox files written before this setting still decode; nil means on.
        var splitKeyboard: Bool?
        /// Set the first time the keyboard runs with Full Access, so the app can
        /// tick that setup step off.
        var keyboardSeenAt: Date?

        var latest: Item? { recent.first }
    }

    /// nil when the container is unavailable, e.g. a keyboard without Full Access.
    static var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: groupID)?
            .appendingPathComponent("inbox.json")
    }

    static var isAvailable: Bool { fileURL != nil }

    static func read() -> State {
        guard let url = fileURL,
              let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(State.self, from: data) else { return State() }
        return state
    }

    static func update(_ change: (inout State) -> Void) {
        guard let url = fileURL else { return }
        var state = read()
        change(&state)
        if state.recent.count > maxItems { state.recent.removeLast(state.recent.count - maxItems) }
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: url, options: .atomic)
        notify_post(changedNotification)
    }
}
