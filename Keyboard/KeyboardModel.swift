import Foundation
import Observation
import UIKit
import notify

@MainActor
@Observable
final class KeyboardModel {
    /// Panels that take over the area under the top bar.
    enum Accessory {
        case kaomoji
        case cards
        /// Older results, from holding 上一句.
        case history
        /// Marks and keys beyond the home's row.
        case more
        /// Rewrite the last result: a style, or a request spoken into the Stick.
        case refine
    }

    /// The home is short; a panel needs the keyboard taller while it is open.
    private(set) var accessory: Accessory? {
        didSet {
            controller?.setExpanded(accessory != nil)
            // While 改寫 is open, the next Stick recording is a request about
            // the last sentence; the app reads this to know.
            let request = accessory == .refine ? refineTarget.map { SharedInbox.RefineRequest(text: $0, date: .now) } : nil
            if SharedInbox.read().refine != request { SharedInbox.update { $0.refine = request } }
            if accessory != .refine, case .done = refineState { refineState = .idle }
        }
    }

    enum RefineState: Equatable {
        case idle
        case working
        /// `original` stays around for 復原.
        case done(original: String, rewritten: String)
        case failed(String)
    }

    private(set) var refineState = RefineState.idle

    /// The last text this keyboard typed: what 改寫 works on.
    private(set) var refineTarget: String? = UserDefaults.standard.string(forKey: KeyboardModel.lastTextKey)
    private(set) var recentKaomoji: [String] = UserDefaults.standard.stringArray(forKey: KeyboardModel.recentKaomojiKey) ?? []
    /// 我的資訊 cards and the user's own kaomoji, edited in the app.
    private(set) var snippets = SharedSnippets.State()

    // MARK: Stick inbox

    private(set) var inbox = SharedInbox.State()
    var needsGlobe = true
    var hasFullAccess = true

    @ObservationIgnored weak var controller: KeyboardViewController?
    @ObservationIgnored private var token: Int32 = NOTIFY_TOKEN_INVALID
    @ObservationIgnored private var shownAt = Date.distantFuture
    @ObservationIgnored private let haptics = UIImpactFeedbackGenerator(style: .light)
    @ObservationIgnored private let selectionHaptics = UISelectionFeedbackGenerator()

    private static let lastInsertedKey = "lastInsertedID"
    private static let lastTextKey = "lastInsertedText"
    private static let recentKaomojiKey = "recentKaomoji"
    private static let maxRecentKaomoji = 16
    /// A result older than this is history, not something to offer on open.
    private static let freshness: TimeInterval = 120

    private var proxy: UITextDocumentProxy? { controller?.textDocumentProxy }

    private var lastInserted: UUID? {
        get { UserDefaults.standard.string(forKey: Self.lastInsertedKey).flatMap(UUID.init) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: Self.lastInsertedKey) }
    }

    /// The newest Stick result not yet typed, while it is still fresh.
    var pending: SharedInbox.Item? {
        guard let latest = inbox.latest,
              latest.id != lastInserted,
              Date.now.timeIntervalSince(latest.date) < Self.freshness else { return nil }
        return latest
    }

    // MARK: Lifecycle

    func start() {
        shownAt = .now
        inbox = SharedInbox.read()
        snippets = SharedSnippets.read()
        if SharedInbox.isAvailable, inbox.keyboardSeenAt == nil {
            SharedInbox.update { $0.keyboardSeenAt = .now }
        }
        guard token == NOTIFY_TOKEN_INVALID else { return }
        // Delivered on the main queue, so the main-actor closure is safe here.
        notify_register_dispatch(SharedInbox.changedNotification, &token, .main) { [weak self] _ in
            self?.inboxChanged()
        }
    }

    func stop() {
        KeyTiming.shared.save()
        guard token != NOTIFY_TOKEN_INVALID else { return }
        notify_cancel(token)
        token = NOTIFY_TOKEN_INVALID
    }

    /// Switching here means a result is wanted: one that is waiting goes in at once.
    func didAppear() {
        if let item = pending { insert(item) }
    }

    func insertAgain(_ item: SharedInbox.Item) {
        KeyTiming.shared.note("tapped a recent result")
        feelTap()
        insert(item)
    }

    // MARK: Keys

    /// A mark or other literal text.
    func type(_ text: String) {
        feelTap()
        proxy?.insertText(text)
    }

    /// What is on the clipboard. Needs Full Access, which the keyboard asks for anyway.
    func paste() {
        feelTap()
        if let text = UIPasteboard.general.string { proxy?.insertText(text) }
    }

    func space() {
        feelTap()
        proxy?.insertText(" ")
    }

    func returnKey() {
        feelTap()
        proxy?.insertText("\n")
    }

    func delete() {
        proxy?.deleteBackward()
    }

    /// One word back: a Latin word with the spaces after it, or about one
    /// Chinese word (two characters), or one mark.
    func deleteWord() {
        let before = Array((proxy?.documentContextBeforeInput ?? "").suffix(64))
        var count = 0
        while count < before.count, before[before.count - 1 - count].isWhitespace { count += 1 }
        func isIdeograph(_ c: Character) -> Bool { c.unicodeScalars.first?.properties.isIdeographic ?? false }
        func isWordCharacter(_ c: Character) -> Bool { (c.isLetter || c.isNumber || c == "'") && !isIdeograph(c) }
        if count < before.count {
            let last = before[before.count - 1 - count]
            if isIdeograph(last) {
                var taken = 0
                while taken < 2, count < before.count, isIdeograph(before[before.count - 1 - count]) { count += 1; taken += 1 }
            } else if isWordCharacter(last) {
                while count < before.count, isWordCharacter(before[before.count - 1 - count]) { count += 1 }
            } else {
                count += 1
            }
        }
        for _ in 0..<max(count, 1) { proxy?.deleteBackward() }
    }

    func nextKeyboard() {
        controller?.advanceToNextInputMode()
    }

    // MARK: Panels

    func open(_ panel: Accessory) {
        feelTap()
        accessory = panel
    }

    func closeAccessory() {
        feelTap()
        accessory = nil
    }

    /// A card is one-off, so the panel closes after it.
    func insert(card text: String) {
        feelTap()
        proxy?.insertText(text)
        accessory = nil
    }

    /// Recent ones first, then the user's own, then every preset.
    var allKaomoji: [String] {
        var seen = Set<String>()
        let all = recentKaomoji + snippets.kaomoji + Kaomoji.presets.flatMap(\.items)
        return all.filter { seen.insert($0).inserted }
    }

    /// Typing a kaomoji keeps the panel open for another.
    func insert(kaomoji: String) {
        feelTap()
        proxy?.insertText(kaomoji)
        recentKaomoji = Array(([kaomoji] + recentKaomoji.filter { $0 != kaomoji }).prefix(Self.maxRecentKaomoji))
        UserDefaults.standard.set(recentKaomoji, forKey: Self.recentKaomojiKey)
    }

    // MARK: Cursor

    /// Dragging along the space bar moves the cursor, like the system keyboard;
    /// the arrows on the 更多 panel move it one step.
    func moveCursor(by offset: Int) {
        proxy?.adjustTextPosition(byCharacterOffset: offset)
        selectionHaptics.selectionChanged()
    }

    /// Prepared again after each tap, so the next one plays without the
    /// Taptic Engine's start-up delay (Apple's advice for rapid feedback).
    private func feelTap() {
        haptics.impactOccurred()
        haptics.prepare()
    }

    // MARK: Stick

    /// Results that arrive while the keyboard is up go straight into the field;
    /// anything older waits for a tap so opening the keyboard never types by surprise.
    private func inboxChanged() {
        // iOS can drop a keyboard's controller without viewDidDisappear; this
        // model then kept listening and "inserted" into nothing, marking the
        // result as done before the visible keyboard got to it.
        guard controller != nil else {
            KeyTiming.shared.note("stale keyboard stopped listening")
            if token != NOTIFY_TOKEN_INVALID { notify_cancel(token) }
            token = NOTIFY_TOKEN_INVALID
            return
        }
        inbox = SharedInbox.read()
        snippets = SharedSnippets.read()
        // A spoken 改寫 always applies; it was asked for from this keyboard.
        guard let latest = inbox.latest, inbox.autoInsert || latest.replaces != nil,
              latest.date >= shownAt, latest.id != lastInserted else {
            KeyTiming.shared.note("skip auto: autoInsert \(inbox.autoInsert) latest \(inbox.latest != nil) "
                + "afterShown \(inbox.latest.map { $0.date >= shownAt } ?? false) "
                + "new \(inbox.latest.map { $0.id != lastInserted } ?? false)")
            return
        }
        insert(latest)
    }

    func insert(_ item: SharedInbox.Item) {
        guard proxy != nil else {
            KeyTiming.shared.note("insert skipped: no text field")
            return
        }
        if let old = item.replaces {
            // A spoken 改寫: swap the sentence if it is still right before the cursor.
            lastInserted = item.id
            if replace(old, with: item.text) {
                refineState = .done(original: old, rewritten: item.text)
            } else {
                refineState = .failed(String(localized: "游標要在那句後面才能改寫"))
            }
            inbox = SharedInbox.read()
            return
        }
        let before = proxy?.documentContextBeforeInput ?? ""
        proxy?.insertText(item.text)
        let after = proxy?.documentContextBeforeInput ?? ""
        KeyTiming.shared.note("insert \(item.text.count) chars: proxy \(proxy != nil) controller \(controller != nil) "
            + "hasText \(proxy?.hasText ?? false) before \(before.count) after \(after.count) "
            + "endsWith \(after.hasSuffix(item.text)) field \(String(describing: proxy?.documentIdentifier))")
        lastInserted = item.id
        rememberTyped(item.text)
        inbox = SharedInbox.read()
    }

    // MARK: 改寫

    private func rememberTyped(_ text: String) {
        refineTarget = text
        UserDefaults.standard.set(text, forKey: Self.lastTextKey)
    }

    /// Deletes `old` from just before the cursor and types `new`. False when
    /// the field doesn't end with `old` there (the cursor moved, or it was edited).
    private func replace(_ old: String, with new: String) -> Bool {
        guard let proxy, (proxy.documentContextBeforeInput ?? "").hasSuffix(old) else { return false }
        for _ in 0..<old.count { proxy.deleteBackward() }
        proxy.insertText(new)
        rememberTyped(new)
        return true
    }

    /// The styles 改寫 offers: the app's, minus 原文, plus the user's own.
    var refineStyles: [PolishStyle] {
        let presets = PolishStyle.all.filter(\.rewritesText)
        guard let custom = inbox.polish?.customStyle else { return presets }
        return presets + [.custom(custom)]
    }

    func refine(_ style: PolishStyle) {
        feelTap()
        guard let target = refineTarget else { return }
        guard let setup = inbox.polish, let baseURL = URL(string: setup.baseURL) else {
            refineState = .failed(String(localized: "先打開 Stick App 一次"))
            return
        }
        guard (proxy?.documentContextBeforeInput ?? "").hasSuffix(target) else {
            refineState = .failed(String(localized: "游標要在那句後面才能改寫"))
            return
        }
        refineState = .working
        let provider = SpeechProvider(
            kind: setup.needsKey ? .groq : .custom, baseURL: baseURL, name: setup.providerName, keyPrompt: "",
            defaultSpeech: "", defaultChat: setup.chatModel, preferredSpeech: [], preferredChat: []
        )
        let key = Keychain.read(setup.keychainAccount) ?? ""
        Task {
            let result = await Polish.run(target, style: style, spellings: setup.spellings,
                                          traditionalChinese: setup.traditionalChinese, about: setup.about,
                                          provider: provider, apiKey: key, model: setup.chatModel)
            guard result.polished else {
                refineState = .failed(String(localized: "沒辦法改寫：整理服務沒有回應"))
                return
            }
            refineState = replace(target, with: result.text)
                ? .done(original: target, rewritten: result.text)
                : .failed(String(localized: "游標要在那句後面才能改寫"))
        }
    }

    /// Puts the sentence back the way it was before 改寫.
    func undoRefine() {
        feelTap()
        guard case let .done(original, rewritten) = refineState else { return }
        if replace(rewritten, with: original) { refineState = .idle }
    }
}
