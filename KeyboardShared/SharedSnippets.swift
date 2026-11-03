import Foundation
import notify

/// Text the user keeps for quick typing: 我的資訊 cards (address, email, …)
/// and their own kaomoji. Edited in the app, read by the keyboard. Stays on
/// this phone, in the App Group container.
enum SharedSnippets {
    struct Card: Codable, Identifiable, Equatable {
        var id = UUID()
        var title: String
        var text: String
    }

    struct State: Codable, Equatable {
        var cards: [Card] = []
        var kaomoji: [String] = []
    }

    static var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: SharedInbox.groupID)?
            .appendingPathComponent("snippets.json")
    }

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
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        // Same signal as the inbox, so an open keyboard reloads.
        notify_post(SharedInbox.changedNotification)
    }
}
