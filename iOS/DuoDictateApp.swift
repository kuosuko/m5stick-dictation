import SwiftUI

/// When this process started, to tell a dictation that had to launch the app
/// from a dictation that found it running.
enum AppLaunch {
    static let date = Date()
}

@main
struct DuoDictateApp: App {
    @State private var link: StickLink
    @State private var store: DictationStore

    init() {
        _ = AppLaunch.date
        let link = StickLink()
        _link = State(initialValue: link)
        _store = State(initialValue: DictationStore(link: link))
    }

    var body: some Scene {
        WindowGroup {
            HomeView(link: link, store: store, demo: DemoScenario.fromLaunchArguments())
                .tint(LabSettings.shared.page.accentColor)
        }
    }
}
