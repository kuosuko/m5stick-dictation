import Foundation
import Observation
import UIKit
import os

struct Dictation: Identifiable, Codable, Equatable {
    var id = UUID()
    let date: Date
    let text: String?
    let error: String?
    let audioSeconds: Double
    /// End of recording → text on the clipboard.
    let latency: Double
    let missingPackets: Int
    let copied: Bool
    let wasInBackground: Bool
    /// What Whisper heard, when polishing changed it.
    var transcript: String?
    /// Where the time went, for finding out why one was slow. Seconds.
    var timing: Timing?

    struct Timing: Codable, Equatable {
        /// App launch → START from the stick; small means iOS launched the app for it.
        var sinceLaunch: Double?
        /// The stick stopped talking → the phone had all the audio.
        var transfer: Double?
        var transcribe: Double?
        var polish: Double?
        /// Per HTTP attempt: dns, connect, tls, upload, wait, download, and how.
        var network: String?
    }

    /// The recording is still on disk (the last twenty are).
    var hasAudio: Bool { RecordingFiles.exists(id) }
}

/// Recording in, text out: to the keyboard's shared inbox (works from the
/// background) and to the pasteboard (only lands when the app is in front).
@MainActor
@Observable
final class DictationStore {
    private(set) var history: [Dictation] = []
    private(set) var isTranscribing = false
    /// Length of the recording being transcribed, for the status line.
    private(set) var transcribingSeconds: Double?
    /// The keyboard has run with Full Access at least once.
    private(set) var keyboardReady = false
    @ObservationIgnored private var lastWarmUp = Date.distantPast

    /// Where transcription and polish go. Switching loads that provider's
    /// own key, models and model list.
    var providerKind: SpeechProvider.Kind {
        didSet {
            UserDefaults.standard.set(providerKind.rawValue, forKey: "provider")
            loadProviderSettings()
        }
    }
    /// For `.custom`: the address up to and including `/v1`.
    var customBaseURL: String {
        didSet { UserDefaults.standard.set(customBaseURL, forKey: "customBaseURL") }
    }
    var apiKey: String {
        didSet { if !loadingProvider { Keychain.write(apiKey, for: provider.keychainAccount) } }
    }
    var language: String {
        didSet { UserDefaults.standard.set(language, forKey: "language") }
    }
    /// Names and terms to keep spelled as written. Used only by polish; Whisper gets no prompt.
    var vocabulary: String {
        didSet { UserDefaults.standard.set(vocabulary, forKey: "vocabulary") }
    }
    var polishStyleID: String {
        didSet { UserDefaults.standard.set(polishStyleID, forKey: "polishStyle") }
    }
    /// The user's picks. What actually runs is `effective…`, which swaps in a
    /// model the provider still offers when the pick has been retired.
    var transcriptionModel: String {
        didSet { if !loadingProvider { UserDefaults.standard.set(transcriptionModel, forKey: modelKey("transcriptionModel")) } }
    }
    var polishModel: String {
        didSet { if !loadingProvider { UserDefaults.standard.set(polishModel, forKey: modelKey("polishModel")) } }
    }
    private(set) var modelLists: ProviderModels.Lists?
    private(set) var isLoadingModels = false
    @ObservationIgnored private var loadingProvider = false

    var provider: SpeechProvider {
        switch providerKind {
        case .groq: .groq
        case .openAI: .openAI
        case .custom: .custom(baseURL: URL(string: customBaseURL) ?? URL(string: SpeechProvider.customPlaceholder)!)
        }
    }
    /// A key when the provider needs one, an address when it is your own server.
    var providerReady: Bool {
        switch providerKind {
        case .custom: URL(string: customBaseURL)?.host() != nil
        default: !apiKey.isEmpty
        }
    }
    var effectiveTranscriptionModel: String { ProviderModels.speech(transcriptionModel, in: modelLists, of: provider) }
    var effectivePolishModel: String { ProviderModels.chat(polishModel, in: modelLists, of: provider) }
    var autoInsert: Bool {
        didSet {
            let value = autoInsert
            SharedInbox.update { $0.autoInsert = value }
        }
    }
    var splitKeyboard: Bool {
        didSet {
            let value = splitKeyboard
            SharedInbox.update { $0.splitKeyboard = value }
        }
    }

    @ObservationIgnored private let link: StickLink
    @ObservationIgnored private let logger = Logger(subsystem: "DuoDictate", category: "dictation")
    private static let historyKey = "history"

    init(link: StickLink) {
        self.link = link
        providerKind = UserDefaults.standard.string(forKey: "provider").flatMap(SpeechProvider.Kind.init) ?? .groq
        customBaseURL = UserDefaults.standard.string(forKey: "customBaseURL") ?? ""
        apiKey = ""
        transcriptionModel = ""
        polishModel = ""
        language = UserDefaults.standard.string(forKey: "language") ?? "zh"
        // The old default was a sentence written for Whisper's prompt, not a word list.
        let savedVocabulary = UserDefaults.standard.string(forKey: "vocabulary") ?? ""
        vocabulary = savedVocabulary == "以下是繁體中文的句子。" ? "" : savedVocabulary
        polishStyleID = UserDefaults.standard.string(forKey: "polishStyle") ?? PolishStyle.cleanID
        let shared = SharedInbox.read()
        autoInsert = shared.autoInsert
        splitKeyboard = shared.splitKeyboard ?? true
        if let data = UserDefaults.standard.data(forKey: Self.historyKey),
           let saved = try? JSONDecoder().decode([Dictation].self, from: data) {
            history = saved
        }
        loadProviderSettings()
        link.onRecording = { [weak self] recording in
            Task { await self?.handle(recording) }
        }
        link.onRecordingChanged = { [weak self] isRecording in
            SharedInbox.update { $0.phase = isRecording ? .recording : .idle }
            if isRecording { self?.warmUpConnection() }
        }
    }

    /// Groq keeps the keys it had before there were other providers.
    private func modelKey(_ name: String) -> String {
        providerKind == .groq ? name : "\(name).\(providerKind.rawValue)"
    }

    private func loadProviderSettings() {
        loadingProvider = true
        defer { loadingProvider = false }
        let provider = provider
        apiKey = Keychain.read(provider.keychainAccount) ?? ""
        transcriptionModel = UserDefaults.standard.string(forKey: modelKey("transcriptionModel")) ?? provider.defaultSpeech
        polishModel = UserDefaults.standard.string(forKey: modelKey("polishModel")) ?? provider.defaultChat
        modelLists = ProviderModels.cached(for: provider)
    }

    /// Re-reads what the keyboard has reported; call when the app comes to the front.
    func refreshSetup() {
        keyboardReady = SharedInbox.read().keyboardSeenAt != nil
        // Providers retire models without warning; a day-old list is old enough to recheck.
        if Date.now.timeIntervalSince(modelLists?.fetchedAt ?? .distantPast) > 12 * 3600 {
            Task { await refreshModels() }
        }
    }

    func refreshModels() async {
        guard providerReady, !isLoadingModels else { return }
        isLoadingModels = true
        defer { isLoadingModels = false }
        let provider = provider
        do {
            let lists = try await ProviderModels.fetch(from: provider, apiKey: apiKey)
            // The user may have switched providers while the list was loading.
            if provider == self.provider { modelLists = lists }
        } catch {
            logger.error("model list failed: \(error.localizedDescription)")
        }
    }

    /// One retry when the provider says the model is gone: fetch the list again and
    /// use whatever it offers now.
    private func transcribe(_ audio: Data, filename: String, with transcriber: Transcriber,
                            trace: NetworkTrace) async throws -> String {
        var transcriber = transcriber
        do {
            return try await transcriber.transcribe(audio: audio, filename: filename, trace: trace)
        } catch Transcriber.Failure.http(let name, let status, let message) where ProviderModels.isMissingModel(status: status, message: message) {
            await refreshModels()
            guard effectiveTranscriptionModel != transcriber.model else { throw Transcriber.Failure.http(name, status, message) }
            transcriber.model = effectiveTranscriptionModel
            return try await transcriber.transcribe(audio: audio, filename: filename, trace: trace)
        }
    }

    /// At most once a minute; an open connection is reused for a while anyway.
    private func warmUpConnection() {
        guard Date.now.timeIntervalSince(lastWarmUp) > 60 else { return }
        lastWarmUp = .now
        let key = apiKey, provider = provider
        Task { await Transcriber.warmUp(provider, apiKey: key) }
    }

    private var spellings: [String] {
        vocabulary.components(separatedBy: CharacterSet(charactersIn: ",，、\n"))
    }

    func clearHistory() {
        history = []
        persist()
        RecordingFiles.removeAll()
    }

    private func handle(_ recording: Recording) async {
        let ended = Date.now
        var timing = Dictation.Timing()
        if let started = recording.startedAt {
            timing.sinceLaunch = started.timeIntervalSince(AppLaunch.date)
            timing.transfer = max(ended.timeIntervalSince(started) - recording.duration, 0)
        }
        let wasInBackground = UIApplication.shared.applicationState != .active
        // A BLE wake gives us a few seconds; ask for enough to finish the upload.
        let task = BackgroundTask(name: "transcribe")
        defer { task.end() }
        // Launched in the background before the first unlock, the Keychain was closed.
        if apiKey.isEmpty, let stored = Keychain.read(provider.keychainAccount) { apiKey = stored }

        isTranscribing = true
        transcribingSeconds = recording.duration
        link.reply(.transcribing, session: recording.session)
        SharedInbox.update { $0.phase = .transcribing }

        var transcriber = Transcriber(provider: provider, apiKey: apiKey, language: language == "auto" ? nil : language,
                                      model: effectiveTranscriptionModel)
        transcriber.traditionalChinese = language != "en"
        let id = UUID()
        let trace = NetworkTrace()

        do {
            // Only the speech is sent; a press with none is not sent at all.
            let speech = SpeechTrim.trim(recording.samples, sampleRate: StickProtocol.sampleRate)
            guard speech.hasSpeech else { throw Transcriber.Failure.emptyResult }
            let wav = WAV.encode(speech.samples, sampleRate: StickProtocol.sampleRate)
            // Kept whether or not the provider answers: a failed one is worth hearing again.
            RecordingFiles.save(wav, for: id)
            let transcribeStart = Date.now
            // Smaller upload; the WAV is the fallback if encoding fails.
            let upload = (try? AAC.encode(speech.samples, sampleRate: StickProtocol.sampleRate))
                .map { ($0, "stick.m4a") } ?? (wav, "stick.wav")
            trace.note("\(upload.1) \(upload.0.count / 1024) KB")
            let transcript = try await transcribe(upload.0, filename: upload.1, with: transcriber, trace: trace)
            timing.transcribe = Date.now.timeIntervalSince(transcribeStart)
            timing.network = trace.summary
            let polishStart = Date.now
            let polish = await Polish.run(
                transcript, style: PolishStyle.withID(polishStyleID), spellings: spellings,
                traditionalChinese: language != "en", provider: provider, apiKey: apiKey,
                model: effectivePolishModel
            )
            timing.polish = Date.now.timeIntervalSince(polishStart)
            // The model may still slip into simplified characters.
            let text = language == "en" ? polish.text
                : polish.text.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? polish.text
            SharedInbox.update {
                $0.phase = .idle
                $0.message = nil
                $0.recent.insert(SharedInbox.Item(text: text, date: .now), at: 0)
            }
            let copied = copyToClipboard(text)
            link.reply(.done, session: recording.session, text: text)
            record(Dictation(
                id: id, date: ended, text: text, error: nil,
                audioSeconds: recording.duration, latency: Date.now.timeIntervalSince(ended),
                missingPackets: recording.missingPackets, copied: copied, wasInBackground: wasInBackground,
                transcript: polish.polished && text != transcript ? transcript : nil, timing: timing
            ))
        } catch {
            let message = error.localizedDescription
            logger.error("transcription failed: \(message)")
            timing.network = trace.summary
            link.reply(.error, session: recording.session, text: message)
            SharedInbox.update {
                $0.phase = .failed
                $0.message = message
            }
            record(Dictation(
                id: id, date: ended, text: nil, error: message,
                audioSeconds: recording.duration, latency: Date.now.timeIntervalSince(ended),
                missingPackets: recording.missingPackets, copied: false, wasInBackground: wasInBackground,
                timing: timing
            ))
        }
        isTranscribing = false
        transcribingSeconds = nil
    }

    /// iOS drops pasteboard writes from a backgrounded app (confirmed on device);
    /// `changeCount` shows whether this one landed.
    private func copyToClipboard(_ text: String) -> Bool {
        let before = UIPasteboard.general.changeCount
        UIPasteboard.general.string = text
        return UIPasteboard.general.changeCount != before
    }

    private func record(_ dictation: Dictation) {
        history.insert(dictation, at: 0)
        if history.count > 50 { history.removeLast(history.count - 50) }
        persist()
        RecordingFiles.prune(keeping: history.map(\.id))
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: Self.historyKey)
        }
    }
}

/// Background time for one job. Ends itself if iOS runs out of patience,
/// which otherwise kills the app outright.
@MainActor
private final class BackgroundTask {
    private var id = UIBackgroundTaskIdentifier.invalid

    init(name: String) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in self?.end() }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
