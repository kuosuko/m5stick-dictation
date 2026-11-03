import SwiftUI

/// Live tuning for the look: drag a slider, watch the Stick, the pairing card
/// or the home screen change. Values are saved and used by the real screens;
/// 複製設定 puts them on the clipboard to make them the new defaults.
struct LabView: View {
    let link: StickLink
    let store: DictationStore

    @Bindable private var lab = LabSettings.shared
    // `-labPreview 首頁 -labHomeScreen 半折` at launch opens straight to a preview, for screenshots.
    @State private var preview = Preview(rawValue: UserDefaults.standard.string(forKey: "labPreview") ?? "") ?? .model
    @State private var replay = 0
    @State private var pairingStep = PairingStep.found
    @State private var copied = false
    @State private var homeScreen = HomeScreen(rawValue: UserDefaults.standard.string(forKey: "labHomeScreen") ?? "") ?? .outer

    enum HomeScreen: String, CaseIterable {
        case outer = "外螢幕"
        case flat = "打開攤平"
        case halfFolded = "半折"
    }
    @Environment(\.horizontalSizeClass) private var sizeClass

    enum Preview: String, CaseIterable {
        case model = "模型"
        case pairing = "配對"
        case home = "首頁"
    }

    enum PairingStep: String, CaseIterable {
        case found = "找到"
        case connecting = "連線中"
        case connected = "已連線"

        var pairing: StickLink.Pairing {
            switch self {
            case .found: .found(name: "StickS3")
            case .connecting: .connecting(name: "StickS3")
            case .connected: .connected(name: "StickS3")
            }
        }
    }

    var body: some View {
        Group {
            if sizeClass == .regular {
                HStack(spacing: 0) {
                    previewPane.frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
                    controls.frame(width: 400)
                }
            } else {
                VStack(spacing: 0) {
                    previewPane.frame(height: 360)
                    Divider()
                    controls
                }
            }
        }
        .navigationTitle("Lab")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu("更多", systemImage: "ellipsis") {
                    Button(copied ? "已複製" : "複製設定", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = lab.exportJSON()
                        copied = true
                    }
                    Button("回到預設值", systemImage: "arrow.counterclockwise", role: .destructive) { lab.reset() }
                }
            }
        }
    }

    // MARK: Preview

    private var previewPane: some View {
        VStack(spacing: 12) {
            Picker("預覽", selection: $preview) {
                ForEach(Preview.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.top, 10)

            ZStack {
                switch preview {
                case .model:
                    StickModelView(look: lab.model, replay: replay)
                case .pairing:
                    PairingCard(pairing: pairingStep.pairing, batteryLevel: 82, onConnect: {}, onClose: {})
                        .id(pairingStep)
                case .home:
                    // The outer display, or the inner one opened flat (669 × 951 pt).
                    GeometryReader { proxy in
                        let inner = homeScreen != .outer
                        let screen = inner ? CGSize(width: 669, height: 951) : CGSize(width: 402, height: 874)
                        let scale = min(proxy.size.width / screen.width, proxy.size.height / screen.height)
                        HomeView(link: link, store: store, demo: .preview,
                                 previewHalfFolded: inner ? homeScreen == .halfFolded : nil)
                            .environment(\.horizontalSizeClass, inner ? .regular : .compact)
                            .frame(width: screen.width, height: screen.height)
                            // The real display's corner, so edge tiles preview their concentric corner.
                            .clipShape(.rect(cornerRadius: 55, style: .continuous))
                            .containerShape(.rect(cornerRadius: 55, style: .continuous))
                            .scaleEffect(scale)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .allowsHitTesting(false)
                    }
                }
            }
            .clipped()

            HStack {
                switch preview {
                case .model:
                    Button("重播進場", systemImage: "arrow.counterclockwise") { replay += 1 }
                case .pairing:
                    Picker("步驟", selection: $pairingStep) {
                        ForEach(PairingStep.allCases, id: \.self) { Text($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                case .home:
                    Picker("螢幕", selection: $homeScreen) {
                        ForEach(HomeScreen.allCases, id: \.self) { Text($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
        .background(lab.page.backgroundColor)
    }

    // MARK: Controls

    private var controls: some View {
        Form {
            Section("材質") {
                color("機身", $lab.model.bodyColor)
                color("前蓋", $lab.model.coverColor)
                color("按鍵", $lab.model.buttonColor)
                slider("機身粗糙度", $lab.model.bodyRoughness, 0...1)
                slider("前蓋粗糙度", $lab.model.coverRoughness, 0...1)
                slider("前蓋光澤", $lab.model.coverClearcoat, 0...1)
                slider("按鍵光澤", $lab.model.buttonClearcoat, 0...1)
                slider("螢幕亮度", $lab.model.screenGlow, 0...4)
            }
            Section("打光") {
                slider("環境光", $lab.model.environment, 0...8)
                slider("主光", $lab.model.keyLight, 0...3000, step: 10)
                slider("補光", $lab.model.fillLight, 0...2000, step: 10)
                slider("輪廓光", $lab.model.rimLight, 0...2000, step: 10)
                slider("曝光", $lab.model.exposure, -2...2)
            }
            Section("攝影機") {
                slider("俯仰", $lab.model.cameraPitch, -0.8...0.8)
                slider("距離", $lab.model.cameraDistance, 80...260, step: 1)
                slider("焦距（視角）", $lab.model.fieldOfView, 10...60, step: 1)
                slider("停下的角度", $lab.model.restingYaw, -1.6...1.6)
            }
            Section("動態") {
                slider("進場圈數", $lab.model.spinTurns, 0...5)
                slider("進場時間", $lab.model.spinDuration, 0.3...4)
                slider("自轉一圈秒數（0 = 不轉）", $lab.model.idlePeriod, 0...40, step: 1)
                slider("拖曳靈敏度", $lab.model.dragSensitivity, 0.002...0.03, digits: 3)
                slider("連上時轉幾圈", $lab.model.celebrateTurns, 0...3)
                slider("連上時轉多久", $lab.model.celebrateDuration, 0.3...3)
                slider("連上時放大", $lab.model.celebrateScale, 1...1.3)
                Button("重播進場", systemImage: "arrow.counterclockwise") {
                    preview = .model
                    replay += 1
                }
            }
            Section("配對卡片") {
                slider("模型高度", $lab.model.modelHeight, 160...440, step: 1)
                slider("落地陰影", $lab.model.floorShadow, 0...0.6)
            }
            Section("頁面") {
                Toggle("黑白（不用主題色）", isOn: $lab.page.monochrome)
                if !lab.page.monochrome {
                    color("主題色", $lab.page.accent)
                }
                Toggle("自訂背景色", isOn: $lab.page.customBackground)
                if lab.page.customBackground {
                    color("背景色", $lab.page.background)
                }
                slider("格子間距", $lab.page.gap, 2...24, step: 1)
                slider("板子邊距", $lab.page.edge, 0...32, step: 1)
                slider("格子內距", $lab.page.tilePadding, 6...28, step: 1)
                slider("格子圓角", $lab.page.tileRadius, 0...40, step: 1)
                slider("數字字級", $lab.page.statSize, 18...44, step: 1)
                slider("標題字級", $lab.page.titleSize, 14...48, step: 1)
                slider("標題粗細", $lab.page.titleWeight, 0...8, step: 1)
                Picker("字體", selection: $lab.page.titleDesign) {
                    Text("標準").tag(PageLook.Design.standard)
                    Text("圓角").tag(PageLook.Design.rounded)
                    Text("襯線").tag(PageLook.Design.serif)
                }
                slider("最新結果字級", $lab.page.latestSize, 14...40, step: 1)
                Picker("最新結果字體", selection: $lab.page.latestDesign) {
                    Text("標準").tag(PageLook.Design.standard)
                    Text("圓角").tag(PageLook.Design.rounded)
                    Text("襯線").tag(PageLook.Design.serif)
                }
                slider("打開攤平時 Stick 那側的寬度", $lab.page.openStickShare, 0.4...0.75)
            }
        }
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>,
                        step: Double? = nil, digits: Int = 2) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(value.wrappedValue, format: .number.precision(.fractionLength(step == nil ? digits : 0)))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if let step {
                Slider(value: value, in: range, step: step)
            } else {
                Slider(value: value, in: range)
            }
        }
    }

    private func color(_ title: String, _ value: Binding<RGBA>) -> some View {
        ColorPicker(title, selection: Binding(get: { value.wrappedValue.color }, set: { value.wrappedValue = RGBA($0) }),
                    supportsOpacity: false)
    }
}
