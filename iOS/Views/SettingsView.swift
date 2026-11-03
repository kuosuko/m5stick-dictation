import SwiftUI

struct SettingsView: View {
    @Bindable var store: DictationStore
    let link: StickLink
    /// Simulator only: show a paired, connected stick.
    var demo = false
    @Environment(\.dismiss) private var dismiss
    @State private var showingFind = false

    private var page: PageLook { LabSettings.shared.page }
    private var paired: Bool { demo || link.hasPairedStick }
    private var connected: Bool { demo || link.status == .connected }
    private var battery: Int? { demo ? 82 : link.batteryLevel }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    stickCard
                }

                if stickSettings != nil {
                    stickSection
                }

                Section(String(localized: "打字")) {
                    Toggle(String(localized: "鍵盤開著時自動打字"), isOn: $store.autoInsert)
                    Button(String(localized: "打開鍵盤設定"), systemImage: "keyboard") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                }

                Section {
                    Picker(String(localized: "語言"), selection: $store.language) {
                        Text(String(localized: "中文")).tag("zh")
                        Text("English").tag("en")
                        Text(String(localized: "自動")).tag("auto")
                    }
                    Picker(String(localized: "整理成"), selection: $store.polishStyleID) {
                        ForEach(PolishStyle.all) { Text($0.name).tag($0.id) }
                    }
                    TextField(String(localized: "常用寫法"), text: $store.vocabulary, prompt: Text(String(localized: "人名、專有名詞，用逗號隔開")), axis: .vertical)
                        .lineLimit(1...4)
                } header: {
                    Text(String(localized: "轉寫"))
                } footer: {
                    Text(String(localized: "說完後先轉成文字，再照這裡的設定整理一遍；整理不成就照原文送出。"))
                }

                Section {
                    Picker(String(localized: "服務"), selection: $store.providerKind) {
                        Text("Groq").tag(SpeechProvider.Kind.groq)
                        Text("OpenAI").tag(SpeechProvider.Kind.openAI)
                        Text(String(localized: "自訂伺服器")).tag(SpeechProvider.Kind.custom)
                    }
                    if store.providerKind == .custom {
                        TextField(String(localized: "網址"), text: $store.customBaseURL, prompt: Text(SpeechProvider.customPlaceholder))
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onSubmit { Task { await store.refreshModels() } }
                    }
                    SecureField("API key", text: $store.apiKey, prompt: Text(store.provider.keyPrompt))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    modelPicker(String(localized: "轉寫模型"), saved: $store.transcriptionModel, effective: store.effectiveTranscriptionModel,
                                options: store.modelLists?.speech)
                    modelPicker(String(localized: "整理模型"), saved: $store.polishModel, effective: store.effectivePolishModel,
                                options: store.modelLists?.chat)
                } header: {
                    Text(String(localized: "轉寫服務"))
                } footer: {
                    Text(providerFooter)
                }

                Section {
                    NavigationLink("Lab") { LabView(link: link, store: store) }
                } footer: {
                    Text(String(localized: "即時調整 Stick 模型、打光、動態和頁面的樣子。"))
                }

                Section {
                    Button(String(localized: "清除紀錄"), role: .destructive) { store.clearHistory() }
                }
            }
            .navigationTitle(String(localized: "設定"))
            .navigationBarTitleDisplayMode(.inline)
            .task(id: store.providerKind) { await store.refreshModels() }
            .sheet(isPresented: $showingFind) { FindStickView(link: link, demo: demo) }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "完成"), systemImage: "checkmark") { dismiss() }
                }
            }
        }
    }

    /// The device first, like an accessory's own page: the Stick, how it is
    /// doing, and the two things you can do to it.
    private var stickCard: some View {
        HStack(alignment: .center, spacing: 18) {
            StickIllustration(screen: connected ? .ready : .off, height: 104)
            VStack(alignment: .leading, spacing: 4) {
                Text(paired ? StickProtocol.localName : String(localized: "還沒有 Stick"))
                    .font(.system(.headline, design: page.titleDesign.font))
                Text(status)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if paired {
                    HStack(spacing: 10) {
                        Button(String(localized: "尋找"), systemImage: "location.magnifyingglass") { showingFind = true }
                            .tint(page.mark)
                        Button(String(localized: "忘記"), role: .destructive) { link.forget() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.top, 8)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
    }

    private var stickSettings: StickSettings? { demo ? link.settings ?? StickSettings() : link.settings }

    /// Only while connected: the stick holds these, the app just edits them.
    private var stickSection: some View {
        Section {
            labeledSlider(String(localized: "螢幕亮度"), value: level(\.brightness), in: 8...255, low: "sun.min", high: "sun.max")
            Picker(String(localized: "閒置多久變暗"), selection: setting(\.dimAfter)) {
                Text(String(localized: "10 秒")).tag(10)
                Text(String(localized: "20 秒")).tag(20)
                Text(String(localized: "30 秒")).tag(30)
                Text(String(localized: "1 分鐘")).tag(60)
                Text(String(localized: "不變暗")).tag(0)
            }
            Picker(String(localized: "閒置多久關螢幕"), selection: setting(\.sleepAfter)) {
                Text(String(localized: "30 秒")).tag(30)
                Text(String(localized: "1 分鐘")).tag(60)
                Text(String(localized: "2 分鐘")).tag(120)
                Text(String(localized: "4 分鐘")).tag(240)
                Text(String(localized: "不關")).tag(0)
            }
            Picker(String(localized: "閒置多久進入睡眠"), selection: setting(\.deepSleepAfter)) {
                Text(String(localized: "15 秒")).tag(15)
                Text(String(localized: "30 秒")).tag(30)
                Text(String(localized: "1 分鐘")).tag(60)
                Text(String(localized: "2 分鐘")).tag(120)
                Text(String(localized: "4 分鐘")).tag(240)
                Text(String(localized: "不睡")).tag(0)
            }
            Toggle(String(localized: "點一下開始，再點一下送出"), isOn: setting(\.tapToLatch))
            labeledSlider(String(localized: "收音"), value: level(\.micGain), in: 0...32, step: 1, low: "mic", high: "mic.fill")
            labeledSlider(String(localized: "尋找時的音量"), value: level(\.findVolume), in: 20...190, low: "speaker.wave.1", high: "speaker.wave.3")
        } header: {
            Text("Stick")
        } footer: {
            Text(String(localized: "設定存在 Stick 上。睡著的 Stick 按住就醒，醒來就開始錄，連上手機後再送出。說話聽不清楚就把收音調高，破音就調低。"))
        }
    }

    private func labeledSlider(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>,
                               step: Double = 1, low: String, high: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
            Slider(value: value, in: range, step: step) {
                Text(title)
            } minimumValueLabel: {
                Image(systemName: low).foregroundStyle(.secondary)
            } maximumValueLabel: {
                Image(systemName: high).foregroundStyle(.secondary)
            }
        }
    }

    /// One field of the stick's settings, written to it as it changes.
    private func setting<Value>(_ keyPath: WritableKeyPath<StickSettings, Value>) -> Binding<Value> {
        Binding(
            get: { (stickSettings ?? StickSettings())[keyPath: keyPath] },
            set: { value in
                var next = stickSettings ?? StickSettings()
                next[keyPath: keyPath] = value
                link.apply(next)
            }
        )
    }

    private func level(_ keyPath: WritableKeyPath<StickSettings, Int>) -> Binding<Double> {
        let field = setting(keyPath)
        return Binding(get: { Double(field.wrappedValue) }, set: { field.wrappedValue = Int($0.rounded()) })
    }

    private var status: String {
        guard paired else { return String(localized: "打開 Stick，配對卡會自己出現。") }
        guard connected else {
            return link.isAsleep ? String(localized: "在睡；按住 Stick 就醒。") : String(localized: "沒連上；靠近時會自動連回來。")
        }
        return battery.map { String(localized: "已連線 · 電量 \($0)%") } ?? String(localized: "已連線")
    }

    /// Lists what the provider offers now; shows the model in use when the saved
    /// pick was retired. A server without a model list gets a text field.
    @ViewBuilder
    private func modelPicker(_ title: String, saved: Binding<String>, effective: String, options: [String]?) -> some View {
        if let options, !options.isEmpty {
            Picker(title, selection: Binding(get: { effective }, set: { saved.wrappedValue = $0 })) {
                ForEach(options, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.navigationLink)
            .disabled(!store.providerReady)
        } else {
            LabeledContent(title) {
                TextField(title, text: saved, prompt: Text(String(localized: "模型名稱")))
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        }
    }

    private var providerFooter: String {
        guard store.providerReady else {
            if store.providerKind == .custom {
                return String(localized: "填入相容 OpenAI API 的伺服器網址，結尾到 /v1，例如 whisper.cpp 或 LocalAI。")
            }
            return String(localized: "沒有 key 時用 Apple Intelligence 整理，轉寫仍需 \(store.provider.name)。Key 只存在這支手機的鑰匙圈裡。")
        }
        var lines: [String] = []
        if store.effectiveTranscriptionModel != store.transcriptionModel {
            lines.append(String(localized: "\(store.transcriptionModel) 已停用，轉寫改用 \(store.effectiveTranscriptionModel)。"))
        }
        if store.effectivePolishModel != store.polishModel {
            lines.append(String(localized: "\(store.polishModel) 已停用，整理改用 \(store.effectivePolishModel)。"))
        }
        if let fetched = store.modelLists?.fetchedAt {
            lines.append(String(localized: "模型清單更新於 \(fetched.formatted(.relative(presentation: .named)))。"))
        } else {
            lines.append(store.isLoadingModels ? String(localized: "正在讀模型清單。") : String(localized: "還沒讀到模型清單，先用預設的。"))
        }
        return lines.joined(separator: "\n")
    }
}
