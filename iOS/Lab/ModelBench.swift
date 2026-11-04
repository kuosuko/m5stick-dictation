import Foundation
import FoundationModels
import Observation
import SwiftUI

/// Runs the same polish and Dreaming jobs through each model the phone can
/// reach, times them, and saves the results to Documents/model-bench.json,
/// where a Mac can copy them off with devicectl. Measured on the phone itself,
/// because the Mac's numbers would say nothing about it.
@MainActor
@Observable
final class ModelBench {
    struct Result: Codable, Identifiable {
        var id = UUID()
        let model: String
        let task: String
        let input: String
        let output: String?
        let error: String?
        let seconds: Double
    }

    struct Report: Codable {
        let date: Date
        let device: String
        let onDeviceVariant: String?
        var results: [Result]
    }

    private(set) var report: Report?
    private(set) var running: String?

    /// Messy on purpose: fillers, a self-correction, English inside Chinese,
    /// and one that asks a question the model must not answer.
    static let samples = [
        "嗯那個我們明天的會議改到三點 不對是四點 然後記得帶那個 MacBook",
        "幫我跟老闆說這個 PR 我今天會 merge 然後 deploy 到 staging",
        "就是我覺得這個設計呃太花了 可以再簡單一點嗎",
        "你可以告訴我今天天氣怎麼樣嗎",
        "um so the deadline is friday no wait monday and we need the figma file by then",
    ]

    var resultsURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("model-bench.json")
    }

    func run(store: DictationStore) async {
        let realTranscripts = store.history.compactMap { $0.transcript ?? $0.text }.prefix(5)
        let polishInputs = Self.samples + realTranscripts
        let dreamInputs = Array(store.history.compactMap(\.text).prefix(10))
        var variant: String?
        if #available(iOS 27.0, *) { variant = SystemLanguageModel.default.variant.displayName }
        report = Report(date: .now, device: Self.deviceName, onDeviceVariant: variant, results: [])

        let style = PolishStyle.withID(PolishStyle.cleanID)
        let spellings = store.dreaming.profile.terms

        // On-device Apple Intelligence.
        if SystemLanguageModel.default.isAvailable {
            for input in polishInputs {
                await polish(input, model: "on-device \(variant ?? "")", style: style, spellings: spellings) {
                    LanguageModelSession(model: SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations),
                                         instructions: $0)
                }
            }
            if #available(iOS 27.0, *), !dreamInputs.isEmpty {
                await dream(dreamInputs, model: "on-device \(variant ?? "")") {
                    LanguageModelSession(model: SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations),
                                         instructions: $0)
                }
            }
        } else {
            add(Result(model: "on-device", task: "availability", input: "", output: nil,
                       error: "\(SystemLanguageModel.default.availability)", seconds: 0))
        }

        // Private Cloud Compute.
        if #available(iOS 27.0, *) {
            let pcc = PrivateCloudComputeLanguageModel()
            if pcc.isAvailable {
                for input in polishInputs {
                    await polish(input, model: "private cloud compute", style: style, spellings: spellings) {
                        LanguageModelSession(model: pcc, instructions: $0)
                    }
                }
                if !dreamInputs.isEmpty {
                    await dream(dreamInputs, model: "private cloud compute") { LanguageModelSession(model: pcc, instructions: $0) }
                }
            } else {
                add(Result(model: "private cloud compute", task: "availability", input: "", output: nil,
                           error: "\(pcc.availability)", seconds: 0))
            }
        }

        // The polish service the app uses now.
        if store.providerReady {
            let rewriter = ChatRewriter(provider: store.provider, apiKey: store.apiKey, model: store.effectivePolishModel)
            let name = "\(store.provider.name) \(store.effectivePolishModel)"
            for input in polishInputs {
                running = "\(name)：\(input.prefix(12))"
                let messages = Polish.messages(transcript: input, style: style, spellings: spellings, traditionalChinese: true)
                let start = Date.now
                do {
                    let raw = try await rewriter.rewrite(system: messages.system, user: messages.user)
                    add(Result(model: name, task: "polish", input: input,
                               output: PolishGuard.rewrite(raw, source: input) ?? "[rejected] \(raw)", error: nil,
                               seconds: Date.now.timeIntervalSince(start)))
                } catch {
                    add(Result(model: name, task: "polish", input: input, output: nil,
                               error: error.localizedDescription, seconds: Date.now.timeIntervalSince(start)))
                }
            }
        }
        running = nil
        save()
    }

    private func polish(_ input: String, model: String, style: PolishStyle, spellings: [String],
                        session: (String) -> LanguageModelSession) async {
        running = "\(model)：\(input.prefix(12))"
        let messages = Polish.messages(transcript: input, style: style, spellings: spellings, traditionalChinese: true)
        let start = Date.now
        do {
            let raw = try await session(messages.system).respond(to: messages.user).content
            add(Result(model: model, task: "polish", input: input,
                       output: PolishGuard.rewrite(raw, source: input) ?? "[rejected] \(raw)", error: nil,
                       seconds: Date.now.timeIntervalSince(start)))
        } catch {
            add(Result(model: model, task: "polish", input: input, output: nil,
                       error: "\(error)", seconds: Date.now.timeIntervalSince(start)))
        }
    }

    private func dream(_ dictations: [String], model: String, session: (String) -> LanguageModelSession) async {
        running = "\(model)：Dreaming"
        let start = Date.now
        do {
            let prompt = Dreaming.prompt(profile: SpeakerProfile(), dictations: dictations)
            let dream = try await session(Dreaming.instructions).respond(to: prompt, generating: Dream.self).content
            let output = """
                about: \(dream.about)
                topics: \(dream.topics.joined(separator: ", "))
                terms: \(dream.terms.joined(separator: ", "))
                cards: \(dream.cards.map { "\($0.title)=\($0.text)" }.joined(separator: ", "))
                """
            add(Result(model: model, task: "dream", input: "\(dictations.count) dictations", output: output,
                       error: nil, seconds: Date.now.timeIntervalSince(start)))
        } catch {
            add(Result(model: model, task: "dream", input: "\(dictations.count) dictations", output: nil,
                       error: "\(error)", seconds: Date.now.timeIntervalSince(start)))
        }
    }

    private func add(_ result: Result) {
        report?.results.append(result)
        save()
    }

    private func save() {
        guard let report, let url = resultsURL else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(report).write(to: url, options: .atomic)
    }

    private static var deviceName: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}

/// The Lab page: run, watch, and read the numbers.
struct ModelBenchView: View {
    let store: DictationStore
    @State private var bench = ModelBench()

    var body: some View {
        List {
            Section {
                Button(bench.running == nil ? "開始比較" : "比較中…") {
                    Task { await bench.run(store: store) }
                }
                .disabled(bench.running != nil)
                if let running = bench.running {
                    Text(running).font(.footnote).foregroundStyle(.secondary)
                }
                if let variant = bench.report?.onDeviceVariant {
                    LabeledContent("裝置上的模型", value: variant)
                }
            } footer: {
                Text("同一批文字交給裝置上的 Apple Intelligence、Private Cloud Compute 和目前的整理服務，結果存在 App 的 Documents/model-bench.json。")
            }
            ForEach(results) { result in
                ResultRow(result: result)
            }
        }
        .navigationTitle("模型比較")
    }

    private var results: [ModelBench.Result] { bench.report?.results ?? [] }
}

private struct ResultRow: View {
    let result: ModelBench.Result

    var body: some View {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("\(result.model) · \(result.task)").font(.caption.weight(.semibold))
                        Spacer()
                        Text(String(format: "%.2f 秒", result.seconds)).font(.caption).monospacedDigit()
                    }
                    Text(result.input).font(.caption).foregroundStyle(.secondary)
                    Text(result.output ?? result.error ?? "").font(.callout)
                        .foregroundStyle(result.error == nil ? Color.primary : Color.red)
                }
    }
}
