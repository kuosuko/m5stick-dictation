import Foundation

/// Providers retire models often, so the choices come from the provider's
/// live model list instead of names baked into the app.
enum ProviderModels {
    struct Lists: Codable, Equatable {
        /// Speech-to-text models, for transcription.
        var speech: [String]
        /// Chat models, for polish.
        var chat: [String]
        var fetchedAt: Date
    }

    private static let speechMarkers = ["whisper", "transcribe"]
    /// Not useful for rewriting text: speech, embeddings, images, safety classifiers.
    private static let notChat = [
        "whisper", "transcribe", "tts", "playai", "orpheus", "guard", "embed", "moderation",
        "dall-e", "image", "realtime", "audio", "search", "davinci", "babbage",
    ]

    private static func cacheKey(_ provider: SpeechProvider) -> String {
        provider.kind == .groq ? "groqModels" : "models.\(provider.kind.rawValue)"
    }

    static func cached(for provider: SpeechProvider) -> Lists? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey(provider)) else { return nil }
        return try? JSONDecoder().decode(Lists.self, from: data)
    }

    static func fetch(from provider: SpeechProvider, apiKey: String) async throws -> Lists {
        var request = URLRequest(url: provider.endpoint("models"))
        request.timeoutInterval = 15
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }

        struct Response: Decodable {
            struct Model: Decodable { let id: String; let active: Bool? }
            let data: [Model]
        }
        let ids = try JSONDecoder().decode(Response.self, from: data).data
            .filter { $0.active ?? true }
            .map(\.id)
            .sorted()
        let lists = Lists(
            speech: ids.filter { id in speechMarkers.contains { id.localizedCaseInsensitiveContains($0) } },
            chat: ids.filter { id in !notChat.contains { id.localizedCaseInsensitiveContains($0) } },
            fetchedAt: .now
        )
        if let encoded = try? JSONEncoder().encode(lists) {
            UserDefaults.standard.set(encoded, forKey: cacheKey(provider))
        }
        return lists
    }

    /// The saved choice while the provider still offers it; otherwise the best
    /// one it does. With no list yet, the saved choice is used as is.
    static func speech(_ saved: String, in lists: Lists?, of provider: SpeechProvider) -> String {
        resolve(saved, available: lists?.speech, preferred: provider.preferredSpeech)
    }

    static func chat(_ saved: String, in lists: Lists?, of provider: SpeechProvider) -> String {
        resolve(saved, available: lists?.chat, preferred: provider.preferredChat)
    }

    private static func resolve(_ saved: String, available: [String]?, preferred: [String]) -> String {
        guard let available, !available.isEmpty, !available.contains(saved) else { return saved }
        return preferred.first(where: available.contains) ?? available[0]
    }

    /// The usual answer when a model has been retired or never existed.
    static func isMissingModel(status: Int, message: String) -> Bool {
        status == 404 || (status == 400 && message.localizedCaseInsensitiveContains("model"))
    }
}
