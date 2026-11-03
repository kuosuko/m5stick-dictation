import Foundation

/// What each HTTP attempt spent its time on, from URLSessionTaskMetrics, to
/// tell a slow network from a slow provider.
final class NetworkTrace: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    var summary: String { lock.withLock { lines.joined(separator: " | ") } }

    func note(_ line: String) { lock.withLock { lines.append(line) } }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard let t = metrics.transactionMetrics.last else { return }
        func span(_ name: String, _ start: Date?, _ end: Date?) -> String? {
            guard let start, let end else { return nil }
            return name + String(format: " %.2f", end.timeIntervalSince(start))
        }
        let parts = [
            span("dns", t.domainLookupStartDate, t.domainLookupEndDate),
            span("connect", t.connectStartDate, t.connectEndDate),
            span("tls", t.secureConnectionStartDate, t.secureConnectionEndDate),
            span("upload", t.requestStartDate, t.requestEndDate),
            span("wait", t.requestEndDate, t.responseStartDate),
            span("download", t.responseStartDate, t.responseEndDate),
        ].compactMap { $0 }
        let how = [
            t.isReusedConnection ? "reused" : "new",
            t.isCellular ? "cellular" : "wifi",
            t.networkProtocolName ?? "?",
        ]
        note((parts + how).joined(separator: " "))
    }
}

struct Transcriber: Sendable {
    enum Failure: Error, LocalizedError {
        case missingKey(String)
        case http(String, Int, String)
        case emptyResult

        var errorDescription: String? {
            switch self {
            case .missingKey(let provider): String(localized: "還沒設定 \(provider) API key")
            case .http(let provider, 401, _): String(localized: "\(provider) API key 無效")
            case .http(let provider, let status, let message): String(localized: "\(provider) 回應 \(status)：\(message)")
            case .emptyResult: String(localized: "沒有聽到內容")
            }
        }
    }

    /// What Whisper writes for silence or noise, learned from subtitle data.
    /// Compared against the whole result with spaces and punctuation removed.
    private static let silencePhrases: Set<String> = [
        "謝謝觀看", "謝謝收看", "謝謝大家觀看", "感謝觀看", "請不吝點贊訂閱轉發打賞支持明鏡與點點欄目",
        "明鏡需要您的支持歡迎訂閱明鏡", "字幕由amaraorg社區提供", "字幕byamaraorg", "thanksforwatching",
        "thankyouforwatching", "ご視聴ありがとうございました",
    ]
    let provider: SpeechProvider
    let apiKey: String
    let language: String?
    // No `prompt`, ever: Whisper reads it as text spoken before the audio, so it
    // echoes it back on silence and can drop the start of what was said.
    /// Without a prompt Whisper often answers Chinese in simplified characters.
    var traditionalChinese = true
    /// Picked from the provider's live list (`ProviderModels`).
    var model: String

    /// Opens the TLS connection while the user is still talking, so the
    /// upload afterwards does not wait for a handshake. URLSession.shared
    /// keeps it open and reuses it.
    /// The model list is small and cheap to ask for.
    static func warmUp(_ provider: SpeechProvider, apiKey: String) async {
        guard !apiKey.isEmpty || !provider.needsKey else { return }
        var request = URLRequest(url: provider.endpoint("models"))
        request.timeoutInterval = 5
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        _ = try? await URLSession.shared.data(for: request)
    }

    /// `audio` is an M4A (AAC) or WAV file; `filename`'s extension tells the provider which.
    func transcribe(audio: Data, filename: String, trace: NetworkTrace? = nil) async throws -> String {
        guard !apiKey.isEmpty || !provider.needsKey else { throw Failure.missingKey(provider.name) }

        let boundary = "stick-\(UUID().uuidString)"
        var request = URLRequest(url: provider.endpoint("audio/transcriptions"))
        request.httpMethod = "POST"
        // Turbo answers in well under a second; past this, retrying beats waiting.
        request.timeoutInterval = 15
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var fields = ["model": model, "response_format": "json", "temperature": "0"]
        if let language, !language.isEmpty { fields["language"] = language }

        let body = Self.multipart(fields: fields, file: audio, filename: filename, boundary: boundary)
        let (data, status) = try await Self.send(request, body: body, trace: trace)

        guard status == 200 else {
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error.message
            throw Failure.http(provider.name, status, message ?? HTTPURLResponse.localizedString(forStatusCode: status))
        }
        var text = try JSONDecoder().decode(Result.self, from: data).text
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if traditionalChinese {
            text = text.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? text
        }
        guard !text.isEmpty, !Self.isSilencePhrase(text) else { throw Failure.emptyResult }
        return text
    }

    /// One quick retry for the failures that a second try usually fixes: a
    /// reused connection the server had already closed, a dropped network
    /// while switching between Wi-Fi and cellular, a busy server.
    private static func send(_ request: URLRequest, body: Data, trace: NetworkTrace?) async throws -> (Data, Int) {
        for attempt in 1...2 {
            do {
                let (data, response) = try await URLSession.shared.upload(for: request, from: body, delegate: trace)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                trace?.note("HTTP \(status)")
                if attempt == 1, status == 429 || status >= 500 {
                    try await Task.sleep(for: .milliseconds(400))
                    continue
                }
                return (data, status)
            } catch let error as URLError where attempt == 1 && retryable.contains(error.code) {
                trace?.note("retry after \(error.code.rawValue)")
                try await Task.sleep(for: .milliseconds(250))
            }
        }
        throw URLError(.unknown)
    }

    private static let retryable: Set<URLError.Code> = [
        .networkConnectionLost, .timedOut, .cannotConnectToHost, .dnsLookupFailed, .secureConnectionFailed,
    ]

    private static func isSilencePhrase(_ text: String) -> Bool {
        let bare = text.lowercased().unicodeScalars
            .filter { !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.punctuationCharacters.contains($0) && !CharacterSet.symbols.contains($0) }
        return silencePhrases.contains(String(String.UnicodeScalarView(bare)))
    }

    private static func multipart(fields: [String: String], file: Data, filename: String, boundary: String) -> Data {
        var body = Data()
        func line(_ string: String) { body.append(Data((string + "\r\n").utf8)) }
        for (name, value) in fields.sorted(by: { $0.key < $1.key }) {
            line("--\(boundary)")
            line("Content-Disposition: form-data; name=\"\(name)\"")
            line("")
            line(value)
        }
        line("--\(boundary)")
        line("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"")
        line("Content-Type: " + (filename.hasSuffix(".m4a") ? "audio/mp4" : "audio/wav"))
        line("")
        body.append(file)
        line("")
        line("--\(boundary)--")
        return body
    }

    private struct Result: Decodable { let text: String }
    private struct ErrorBody: Decodable {
        struct Detail: Decodable { let message: String }
        let error: Detail
    }
}
