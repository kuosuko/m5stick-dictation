import Foundation
import Observation
import UIKit
import notify

@MainActor
@Observable
final class KeyboardModel {
    enum Shift {
        case off
        case once
        case locked
    }

    /// The keyboard opens on its light home page; 打字 switches to the keys.
    enum Mode {
        case home
        case typing
    }

    /// Panels that take over the key area besides the candidate grid.
    enum Accessory {
        case kaomoji
        case cards
    }

    // MARK: Typing state

    private(set) var mode: Mode = .home
    private(set) var language: InputLanguage = .zhuyin
    var layer: KeyLayer = .letters
    private(set) var shift: Shift = .off
    private(set) var candidates: [ZhuyinCandidate] = []
    private(set) var isComposing = false
    /// Syllable where the segment being chosen starts.
    private(set) var focusIndex = 0
    /// The sentence as the engine split it, for picking a segment to fix.
    private(set) var segments: [ZhuyinSegment] = []
    /// We have put marked text into the host field and not yet closed it.
    @ObservationIgnored private var ownsMarkedText = false
    /// The candidate grid takes over the key area, like the system Zhuyin keyboard.
    private(set) var isCandidatePanelOpen = false
    /// The user can turn the split layout off in the app.
    private(set) var allowsSplit = true
    private(set) var engineFailed = false
    /// 聯想詞 for what was just sent; tapping one types it.
    private(set) var associations: [ZhuyinCandidate] = []
    /// Completions for the English word being typed.
    private(set) var suggestions: [String] = []
    private(set) var accessory: Accessory?
    /// A quick tap on ^_^ swaps the candidate bar for a row of kaomoji.
    private(set) var showsKaomojiStrip = false
    private(set) var recentKaomoji: [String] = UserDefaults.standard.stringArray(forKey: KeyboardModel.recentKaomojiKey) ?? []
    /// 我的資訊 cards and the user's own kaomoji, edited in the app.
    private(set) var snippets = SharedSnippets.State()

    // MARK: Stick inbox

    private(set) var inbox = SharedInbox.State()
    var needsGlobe = true
    var hasFullAccess = true
    /// Book posture splits around a vertical fold; laptop posture (landscape) never splits.
    var isPortrait = true

    @ObservationIgnored weak var controller: KeyboardViewController?
    @ObservationIgnored private var engine: ZhuyinEngine?
    @ObservationIgnored private var token: Int32 = NOTIFY_TOKEN_INVALID
    @ObservationIgnored private var shownAt = Date.distantFuture
    @ObservationIgnored private var lastSpace = Date.distantPast
    @ObservationIgnored private var lastShiftTap = Date.distantPast
    @ObservationIgnored private let haptics = UIImpactFeedbackGenerator(style: .light)
    @ObservationIgnored private let selectionHaptics = UISelectionFeedbackGenerator()
    @ObservationIgnored private let checker = UITextChecker()

    private static let lastInsertedKey = "lastInsertedID"
    private static let recentKaomojiKey = "recentKaomoji"
    private static let maxRecentKaomoji = 16
    private static let languageKey = "language"
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

    init() {
        if UserDefaults.standard.string(forKey: Self.languageKey) == "en" { language = .english }
    }

    // MARK: Lifecycle

    func start() {
        shownAt = .now
        inbox = SharedInbox.read()
        allowsSplit = inbox.splitKeyboard ?? true
        snippets = SharedSnippets.read()
        if SharedInbox.isAvailable, inbox.keyboardSeenAt == nil {
            SharedInbox.update { $0.keyboardSeenAt = .now }
        }
        // The dictionary is the slow part of opening; the home page doesn't need it.
        if mode == .typing { loadEngineIfNeeded() }
        updateAutoShift()
        guard token == NOTIFY_TOKEN_INVALID else { return }
        // Delivered on the main queue, so the main-actor closure is safe here.
        notify_register_dispatch(SharedInbox.changedNotification, &token, .main) { [weak self] _ in
            self?.inboxChanged()
        }
    }

    func stop() {
        commitComposition()
        KeyTiming.shared.save()
        guard token != NOTIFY_TOKEN_INVALID else { return }
        notify_cancel(token)
        token = NOTIFY_TOKEN_INVALID
    }

    /// Switching here means a result is wanted: one that is waiting goes in at once.
    func didAppear() {
        if let item = pending {
            insert(item)
            mode = .home
        }
    }

    func insertAgain(_ item: SharedInbox.Item) {
        KeyTiming.shared.note("tapped a recent result")
        feelTap()
        insert(item)
    }

    private func loadEngineIfNeeded() {
        guard engine == nil, !engineFailed,
              let data = Bundle.main.path(forResource: "data", ofType: "txt") else { return }
        let loadStart = Date.now
        defer { KeyTiming.shared.mark("engineLoad", since: loadStart) }
        let userDirectory = SharedInbox.fileURL?.deletingLastPathComponent().appendingPathComponent("zhuyin").path
        let associated = Bundle.main.path(forResource: "associated-phrases-v2", ofType: "txt")
        let abbreviations = Bundle.main.path(forResource: "abbrev", ofType: "txt")
        engine = ZhuyinEngine(dataPath: data, associatedPhrasesPath: associated,
                              abbreviationsPath: abbreviations, userDirectory: userDirectory)
        engineFailed = engine == nil
    }

    // MARK: Keys

    func tap(_ key: CharKey) {
        let timing = KeyTiming.shared
        timing.time("haptic") { feelTap() }
        if layer == .letters, language == .zhuyin, let ascii = key.output.utf8.first, let engine {
            if timing.time("engineKey", { engine.handleKey(CChar(bitPattern: ascii)) }) {
                associations = []
                showsKaomojiStrip = false
                refreshComposition()
                return
            }
        }
        commitComposition()
        let text = layer == .letters && language == .english && shift != .off ? key.output.uppercased() : key.output
        type(text)
        if shift == .once { shift = .off }
        if layer != .letters, ["'", "’"].contains(text) { layer = .letters }
        updateAutoShift()
    }

    /// The number row and ，: the text goes in as is, ending any Zhuyin being composed.
    func tapLiteral(_ key: CharKey) {
        feelTap()
        type(key.output)
    }

    /// Plain text that bypasses the Zhuyin engine: the letter on a swiped
    /// Zhuyin key, punctuation, and the like.
    func type(_ text: String) {
        commitComposition()
        proxy?.insertText(text)
        dismissStrips()
        updateSuggestions()
    }

    func space() {
        feelTap()
        // Space ends the syllable being typed; return is what sends the
        // sentence. With no syllable open, space shows the full candidate list.
        if language == .zhuyin, layer == .letters, let engine, engine.isComposing {
            if engine.handleSpace() {
                refreshComposition()
            } else if !candidates.isEmpty {
                isCandidatePanelOpen = true
            }
            return
        }
        // Double space → ". " like the system English keyboard.
        if language == .english, Date.now.timeIntervalSince(lastSpace) < 0.35,
           let before = proxy?.documentContextBeforeInput, before.hasSuffix(" "),
           let previous = before.dropLast().last, previous.isLetter || previous.isNumber {
            proxy?.deleteBackward()
            proxy?.insertText(". ")
            lastSpace = .distantPast
        } else {
            proxy?.insertText(" ")
            lastSpace = .now
        }
        if layer != .letters { layer = .letters }
        dismissStrips()
        suggestions = []
        updateAutoShift()
    }

    func returnKey() {
        feelTap()
        if isComposing {
            commitComposition()
            return
        }
        proxy?.insertText("\n")
        dismissStrips()
        suggestions = []
        updateAutoShift()
    }

    /// One word back: a Latin word with the spaces after it, or about one
    /// Chinese word (two characters), or one mark. Zhuyin being composed
    /// still goes a syllable at a time.
    func deleteWord() {
        if let engine, engine.isComposing {
            delete()
            return
        }
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
        dismissStrips()
        updateSuggestions()
        updateAutoShift()
    }

    func delete() {
        if let engine, engine.isComposing {
            _ = engine.backspace()
            refreshComposition()
            return
        }
        proxy?.deleteBackward()
        dismissStrips()
        updateSuggestions()
        updateAutoShift()
    }

    // MARK: Panels

    func open(_ panel: Accessory) {
        feelTap()
        commitComposition()
        dismissStrips()
        suggestions = []
        isCandidatePanelOpen = false
        accessory = panel
    }

    func closeAccessory() {
        feelTap()
        accessory = nil
    }

    /// A card is one-off, so the panel closes after it.
    func insert(card text: String) {
        feelTap()
        type(text)
        accessory = nil
    }

    func toggleKaomojiStrip() {
        feelTap()
        let showing = showsKaomojiStrip
        commitComposition()
        dismissStrips()
        suggestions = []
        showsKaomojiStrip = !showing
    }

    /// Recent ones first, then the user's own, then every preset.
    var stripKaomoji: [String] {
        var seen = Set<String>()
        let all = recentKaomoji + snippets.kaomoji + Kaomoji.presets.flatMap(\.items)
        return all.filter { seen.insert($0).inserted }
    }

    /// Typing a kaomoji keeps the strip or panel open for another.
    func insert(kaomoji: String) {
        feelTap()
        commitComposition()
        proxy?.insertText(kaomoji)
        clearAssociations()
        suggestions = []
        recentKaomoji = Array(([kaomoji] + recentKaomoji.filter { $0 != kaomoji }).prefix(Self.maxRecentKaomoji))
        UserDefaults.standard.set(recentKaomoji, forKey: Self.recentKaomojiKey)
    }

    // MARK: Cursor

    /// Dragging along the space bar moves the cursor, like the system keyboard.
    func beginCursorDrag() {
        commitComposition()
        dismissStrips()
        suggestions = []
    }

    func moveCursor(by offset: Int) {
        proxy?.adjustTextPosition(byCharacterOffset: offset)
        selectionHaptics.selectionChanged()
    }

    // MARK: Suggestions

    func accept(association: ZhuyinCandidate) {
        feelTap()
        proxy?.insertText(association.value)
        engine?.acceptAssociatedPhrase(association)
        associations = Array((engine?.associatedPhrases() ?? []).prefix(Self.maxAssociations))
    }

    /// Replaces the partial word with the completion and a space.
    func accept(suggestion: String) {
        feelTap()
        for _ in 0..<currentWord.count { proxy?.deleteBackward() }
        proxy?.insertText(suggestion + " ")
        suggestions = []
        updateAutoShift()
    }

    private static let maxAssociations = 40

    /// Whatever the candidate bar was offering goes away once the user types on.
    private func dismissStrips() {
        showsKaomojiStrip = false
        clearAssociations()
    }

    private func clearAssociations() {
        guard !associations.isEmpty else { return }
        associations = []
        engine?.forgetAssociation()
    }

    /// The letters right before the cursor.
    private var currentWord: String {
        let before = proxy?.documentContextBeforeInput ?? ""
        return String(before.reversed().prefix { $0.isLetter && $0.isASCII }.reversed())
    }

    private func updateSuggestions() {
        let word = currentWord
        guard language == .english, layer == .letters, !word.isEmpty else {
            suggestions = []
            return
        }
        let range = NSRange(location: 0, length: (word as NSString).length)
        let completions = checker.completions(forPartialWordRange: range, in: word.lowercased(), language: "en_US") ?? []
        let capitalized = word.first?.isUppercase == true
        suggestions = completions.prefix(3).map { capitalized ? $0.prefix(1).uppercased() + $0.dropFirst() : $0 }
    }

    /// Tap = next letter only, quick double tap = caps lock, like the system keyboard.
    func tapShift() {
        feelTap()
        let isDoubleTap = Date.now.timeIntervalSince(lastShiftTap) < 0.3
        lastShiftTap = .now
        switch shift {
        case .off: shift = .once
        case .once: shift = isDoubleTap ? .locked : .off
        case .locked: shift = .off
        }
    }

    func toggleLanguage() {
        feelTap()
        commitComposition()
        dismissStrips()
        suggestions = []
        language = language == .zhuyin ? .english : .zhuyin
        layer = .letters
        UserDefaults.standard.set(language == .english ? "en" : "zh", forKey: Self.languageKey)
        updateAutoShift()
    }

    func nextKeyboard() {
        commitComposition()
        controller?.advanceToNextInputMode()
    }

    // MARK: Candidates

    /// Picking fixes one segment and moves on; the sentence is sent once
    /// every segment is chosen (or the whole-sentence candidate is picked).
    func select(_ candidate: ZhuyinCandidate) {
        feelTap()
        guard let engine else { return }
        if KeyTiming.shared.time("engineSelect", { engine.selectCandidate(candidate) }) {
            commitComposition()
        } else {
            refreshComposition()
        }
    }

    func toggleCandidatePanel() {
        feelTap()
        isCandidatePanelOpen.toggle()
    }

    var canMoveFocusForward: Bool {
        guard let last = segments.last else { return false }
        return focusIndex < last.start
    }

    func moveFocusBackward() {
        feelTap()
        guard let engine, engine.moveFocusBackward() else { return }
        refreshComposition()
    }

    func moveFocusForward() {
        feelTap()
        guard let engine, engine.moveFocusForward() else { return }
        refreshComposition()
    }

    func focus(_ segment: ZhuyinSegment) {
        feelTap()
        engine?.focusSegment(at: segment.start)
        refreshComposition()
    }

    /// Shows the walked sentence inline as marked text, like the system IME,
    /// with the segment being chosen selected.
    private func refreshComposition() {
        guard let engine else { return }
        let text = engine.composingText
        isComposing = engine.isComposing
        let choosing = engine.readingText.isEmpty
        candidates = choosing ? KeyTiming.shared.time("candidates") { engine.candidates() } : []
        segments = choosing ? engine.segments : []
        focusIndex = choosing ? Int(engine.focusIndex) : 0
        if candidates.isEmpty { isCandidatePanelOpen = false }
        if text.isEmpty {
            releaseMarkedText()
        } else {
            // Like the system keyboard: Bopomofo in the field, the conversion
            // in the candidate bar. Segments already chosen show as characters.
            let marked = engine.markedTextConverting(before: UInt(focusIndex))
            KeyTiming.shared.time("setMarkedText") {
                proxy?.setMarkedText(marked, selectedRange: NSRange(location: (marked as NSString).length, length: 0))
            }
            ownsMarkedText = true
        }
    }

    /// Ends the host's composing state if we started one. Some apps keep the
    /// field "composing" after insertText, so the sentence stayed an underlined
    /// draft and later text (a Stick result) landed inside it. An empty mark
    /// plus unmark closes it without touching the committed text.
    private func releaseMarkedText() {
        guard ownsMarkedText else { return }
        proxy?.setMarkedText("", selectedRange: NSRange(location: 0, length: 0))
        proxy?.unmarkText()
        ownsMarkedText = false
    }

    private func commitComposition() {
        guard let engine, engine.isComposing else { return }
        let text = engine.commit()
        // insertText replaces the marked text and leaves the cursor after it.
        // setMarkedText + unmarkText left the cursor at the start in some apps,
        // so the next key ("1" after 測試) landed in front of the sentence.
        KeyTiming.shared.time("commitInsert") {
            proxy?.insertText(text)
            releaseMarkedText()
        }
        isComposing = false
        candidates = []
        segments = []
        focusIndex = 0
        isCandidatePanelOpen = false
        if language == .zhuyin {
            associations = KeyTiming.shared.time("associations") { Array(engine.associatedPhrases().prefix(Self.maxAssociations)) }
        }
    }

    /// Prepared again after each tap, so the next one plays without the
    /// Taptic Engine's start-up delay (Apple's advice for rapid feedback).
    private func feelTap() {
        haptics.impactOccurred()
        haptics.prepare()
    }

    private func updateAutoShift() {
        guard language == .english, shift != .locked, let proxy else { return }
        guard proxy.autocapitalizationType != UITextAutocapitalizationType.none else {
            shift = .off
            return
        }
        let before = proxy.documentContextBeforeInput ?? ""
        let trimmed = before.trimmingCharacters(in: .whitespaces)
        let startsSentence = trimmed.isEmpty || trimmed.hasSuffix(".") || trimmed.hasSuffix("?")
            || trimmed.hasSuffix("!") || before.hasSuffix("\n")
        shift = startsSentence && (before.isEmpty || before.hasSuffix(" ") || before.hasSuffix("\n")) ? .once : .off
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
        allowsSplit = inbox.splitKeyboard ?? true
        snippets = SharedSnippets.read()
        guard inbox.autoInsert, let latest = inbox.latest, latest.date >= shownAt, latest.id != lastInserted else {
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
        commitComposition()
        releaseMarkedText()
        dismissStrips()
        let before = proxy?.documentContextBeforeInput ?? ""
        proxy?.insertText(item.text)
        let after = proxy?.documentContextBeforeInput ?? ""
        KeyTiming.shared.note("insert \(item.text.count) chars: proxy \(proxy != nil) controller \(controller != nil) "
            + "hasText \(proxy?.hasText ?? false) before \(before.count) after \(after.count) "
            + "endsWith \(after.hasSuffix(item.text)) field \(String(describing: proxy?.documentIdentifier))")
        lastInserted = item.id
        inbox = SharedInbox.read()
    }
}
