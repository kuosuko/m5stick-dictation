import Foundation

/// Where transcription and polish go. Every choice speaks OpenAI's API
/// (`/audio/transcriptions`, `/chat/completions`, `/models`), so one client
/// serves Groq, OpenAI and a server of your own (whisper.cpp, LocalAI, vLLM…).
struct SpeechProvider: Hashable, Identifiable, Sendable {
    enum Kind: String, CaseIterable, Identifiable, Sendable {
        case groq, openAI, custom
        var id: String { rawValue }
    }

    let kind: Kind
    var baseURL: URL
    /// Shown in settings and errors.
    let name: String
    let keyPrompt: String
    let defaultSpeech: String
    let defaultChat: String
    /// Tried in order when the saved choice is no longer offered.
    let preferredSpeech: [String]
    let preferredChat: [String]

    var id: String { kind.rawValue }
    /// A server of your own may need no key.
    var needsKey: Bool { kind != .custom }
    /// Groq's account name predates the other providers.
    var keychainAccount: String { kind == .groq ? "groq" : kind.rawValue }

    func endpoint(_ path: String) -> URL { baseURL.appending(path: path) }

    static let groq = SpeechProvider(
        kind: .groq, baseURL: URL(string: "https://api.groq.com/openai/v1")!, name: "Groq",
        keyPrompt: String(localized: "貼上 gsk_ 開頭的 key"),
        defaultSpeech: "whisper-large-v3-turbo", defaultChat: "llama-3.3-70b-versatile",
        preferredSpeech: ["whisper-large-v3-turbo", "whisper-large-v3"],
        preferredChat: ["llama-3.3-70b-versatile", "openai/gpt-oss-120b", "moonshotai/kimi-k2-instruct", "qwen/qwen3-32b"]
    )

    static let openAI = SpeechProvider(
        kind: .openAI, baseURL: URL(string: "https://api.openai.com/v1")!, name: "OpenAI",
        keyPrompt: String(localized: "貼上 sk- 開頭的 key"),
        defaultSpeech: "gpt-4o-mini-transcribe", defaultChat: "gpt-4.1-mini",
        preferredSpeech: ["gpt-4o-mini-transcribe", "gpt-4o-transcribe", "whisper-1"],
        preferredChat: ["gpt-4.1-mini", "gpt-4o-mini", "gpt-4.1"]
    )

    /// `baseURL` is the address up to and including `/v1`.
    static func custom(baseURL: URL) -> SpeechProvider {
        SpeechProvider(
            kind: .custom, baseURL: baseURL, name: String(localized: "自訂伺服器"), keyPrompt: String(localized: "不需要就留空"),
            defaultSpeech: "whisper-1", defaultChat: "",
            preferredSpeech: [], preferredChat: []
        )
    }

    static let customPlaceholder = "http://192.168.1.10:8080/v1"
}
