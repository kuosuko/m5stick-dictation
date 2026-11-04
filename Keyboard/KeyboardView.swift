import SwiftUI

/// The Stick keyboard: a status bar over the home page, or over the 我的資訊
/// and kaomoji panels. Typing itself stays on the system keyboard.
struct KeyboardView: View {
    let model: KeyboardModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            TopBar(model: model)
                .frame(height: 44)

            ZStack {
                if let accessory = model.accessory {
                    AccessoryPanel(model: model, kind: accessory)
                        .transition(panelTransition)
                } else {
                    HomePanel(model: model)
                        .transition(homeTransition)
                }
            }
            .frame(maxHeight: .infinity)
            .padding(.top, 2)
            .padding(.bottom, 4)
        }
        .animation(.spring(duration: 0.32, bounce: 0.12), value: model.accessory)
    }

    private var panelTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -12))
    }

    private var homeTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.97, anchor: .bottom))
    }
}

// MARK: - Kaomoji and 我的資訊

private struct AccessoryPanel: View {
    let model: KeyboardModel
    let kind: KeyboardModel.Accessory

    @State private var category = Self.allID
    private static let allID = "all"
    private static let mineID = "mine"

    var body: some View {
        VStack(spacing: 6) {
            // Back sits on top, where the thumb already is after opening
            // the panel from the home's big buttons.
            HStack(spacing: 6) {
                Button(action: model.closeAccessory) {
                    Label(String(localized: "返回"), systemImage: "chevron.left")
                        .font(.system(size: 15, weight: .medium))
                }
                .buttonStyle(PressStyle(function: true))
                .frame(width: 84)
                if kind == .kaomoji {
                    categoryBar
                } else {
                    Text(title)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
                DeleteKey(model: model).frame(width: 52)
            }
            .frame(height: 40)

            ScrollView {
                switch kind {
                case .kaomoji: kaomojiGrid
                case .cards: cardGrid
                case .history: historyList
                case .more: moreGrid
                case .refine: RefinePanel(model: model)
                }
            }
            .scrollIndicators(.hidden)
            .id(category)
        }
        // A swipe to the right goes back too, like a navigation stack.
        .gesture(
            DragGesture(minimumDistance: 30)
                .onEnded { value in
                    if value.translation.width > 80, abs(value.translation.height) < 50 { model.closeAccessory() }
                }
        )
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }

    private var title: String {
        switch kind {
        case .cards: String(localized: "我的資訊")
        case .history: String(localized: "最近的結果")
        case .more: String(localized: "更多")
        case .refine: String(localized: "改寫上一句")
        case .kaomoji: ""
        }
    }

    @ViewBuilder
    private var historyList: some View {
        let items = Array(model.inbox.recent.prefix(20))
        if items.isEmpty {
            Text(String(localized: "用 Stick 說的話會出現在這裡"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(24)
                .frame(maxWidth: .infinity)
        } else {
            VStack(spacing: 0) {
                ForEach(items) { item in
                    RecentRow(item: item) { model.insertAgain(item) }
                    if item.id != items.last?.id { Divider().padding(.leading, 12) }
                }
            }
        }
    }

    private static let moreMarks = ["？", "！", "、", "：", "；", "……", "「", "」", "（", "）", "～", "＠", "#", "%"]

    private var moreGrid: some View {
        VStack(spacing: 10) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 10) {
                ForEach(Self.moreMarks, id: \.self) { mark in
                    RoundKey(text: mark) { model.type(mark) }
                        .frame(height: 46)
                }
            }
            HStack(spacing: 8) {
                RoundKey(systemImage: "chevron.left", label: String(localized: "游標往左")) { model.moveCursor(by: -1) }
                RoundKey(systemImage: "chevron.right", label: String(localized: "游標往右")) { model.moveCursor(by: 1) }
                RoundKey(systemImage: "space", label: String(localized: "空白"), action: model.space)
                RoundKey(systemImage: "doc.on.clipboard", label: String(localized: "貼上"), action: model.paste)
                RoundKey(systemImage: "return", label: String(localized: "換行"), action: model.returnKey)
                RoundKey(systemImage: "delete.left", label: String(localized: "刪除"), action: model.delete)
            }
            .frame(height: 46)
        }
        .padding(.top, 4)
    }

    /// 全部 first so everything is one scroll away; 我的 only once there are some.
    private var categories: [Kaomoji.Category] {
        let all = Kaomoji.Category(id: Self.allID, name: String(localized: "全部"), items: model.allKaomoji)
        let mine = model.snippets.kaomoji.isEmpty
            ? []
            : [Kaomoji.Category(id: Self.mineID, name: String(localized: "我的"), items: model.snippets.kaomoji)]
        return [all] + mine + Kaomoji.presets
    }

    private var kaomojiGrid: some View {
        let items = categories.first { $0.id == category }?.items ?? Kaomoji.presets[0].items
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 6)], spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, kaomoji in
                Button { model.insert(kaomoji: kaomoji) } label: {
                    Text(kaomoji)
                        .font(.system(size: 15))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .padding(.horizontal, 6)
                }
                .buttonStyle(PressStyle())
                .frame(height: 40)
            }
        }
    }

    private var categoryBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(categories) { item in
                    let selected = item.id == category
                    Button { category = item.id } label: {
                        Text(item.name)
                            .font(.system(size: 14, weight: selected ? .semibold : .regular))
                            .foregroundStyle(selected ? Color.primary : Color.secondary)
                            .padding(.horizontal, 10)
                            .frame(maxHeight: .infinity)
                            .background(
                                Capsule().fill(selected ? Color.primary.opacity(0.1) : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
    }

    @ViewBuilder
    private var cardGrid: some View {
        if model.snippets.cards.isEmpty {
            Text(String(localized: "到 Stick App 的設定 › 我的資訊，加入地址、Email、電話這些常打的資料。"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(24)
                .frame(maxWidth: .infinity)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 6)], spacing: 6) {
                ForEach(model.snippets.cards) { card in
                    Button { model.insert(card: card.text) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(card.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(card.text)
                                .font(.callout)
                                .lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                    }
                    .buttonStyle(PressStyle())
                    .frame(height: 62)
                }
            }
        }
    }
}

// MARK: - Top bar

private struct TopBar: View {
    let model: KeyboardModel

    var body: some View {
        Group {
            if !model.hasFullAccess {
                hint(String(localized: "到設定 › 一般 › 鍵盤 › Stick 打開「允許完整取用」，才收得到 Stick 的文字"))
            } else if let item = model.pending {
                Button { model.insert(item) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down.to.line")
                            .accessibilityLabel(String(localized: "插入"))
                        Text(item.text)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.callout)
                    .padding(.horizontal, 14)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                HStack(spacing: 0) {
                    switch model.inbox.phase {
                    case .recording: hint(String(localized: "正在收音…"), tint: .red)
                    case .transcribing: hint(String(localized: "轉寫中…"), tint: .orange)
                    case .failed: hint(model.inbox.message ?? String(localized: "轉寫失敗"), tint: .red)
                    case .idle:
                        HStack(spacing: 0) {
                            ParrotMark(height: 12).padding(.leading, 14)
                            hint(String(localized: "按住 Stick 說話")).padding(.leading, -6)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func hint(_ text: String, tint: Color = .secondary) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 14)
    }
}

// MARK: - Keys

struct KeyFace: View {
    var function = false
    var pressed = false
    @Environment(\.colorScheme) private var scheme

    /// Translucent and well rounded like the iOS 27 system keys, so the
    /// keyboard's glass backdrop shows through.
    var body: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(Color.white.opacity(opacity))
            .shadow(color: .black.opacity(scheme == .dark ? 0.18 : 0.07), radius: 0.5, y: 0.5)
    }

    private var opacity: Double {
        // Character keys are the brighter ones; pressing swaps the two looks.
        let bright = function == pressed
        switch scheme {
        case .dark: return bright ? 0.24 : 0.1
        default: return bright ? 0.78 : 0.34
        }
    }
}

struct PressStyle: ButtonStyle {
    var function = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(KeyFace(function: function, pressed: configuration.isPressed))
            .foregroundStyle(.primary)
            .contentShape(Rectangle())
            // Lights at once, fades on release, so even a quick tap shows.
            .animation(configuration.isPressed ? nil : .easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// Tap for space; drag sideways to move the cursor, one character per step.
struct SpaceKey: View {
    let model: KeyboardModel

    @State private var dragging = false
    @State private var stepsTaken = 0
    @State private var pressed = false

    private static let step: CGFloat = 9

    var body: some View {
        Text(String(localized: "空白"))
            .font(.system(size: 16))
            .opacity(dragging ? 0 : 1)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(KeyFace(pressed: pressed && !dragging))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        pressed = true
                        if !dragging, abs(value.translation.width) > 12 {
                            dragging = true
                            stepsTaken = 0
                        }
                        guard dragging else { return }
                        let steps = Int(value.translation.width / Self.step)
                        if steps != stepsTaken {
                            model.moveCursor(by: steps - stepsTaken)
                            stepsTaken = steps
                        }
                    }
                    .onEnded { _ in
                        if !dragging { model.space() }
                        dragging = false
                        pressed = false
                    }
            )
            .accessibilityElement()
            .accessibilityLabel(String(localized: "空白"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { model.space() }
    }
}

struct FunctionKey: View {
    var title: String?
    var systemImage: String?
    var label: String?
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if let systemImage {
                    Image(systemName: systemImage).accessibilityLabel(label ?? "")
                } else {
                    Text(title ?? "").font(.system(size: 15))
                }
            }
            .foregroundStyle(prominent ? Color.white : Color.primary)
        }
        .buttonStyle(PressStyle(function: true))
        .overlay {
            if prominent {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.accentColor)
                    .overlay(Text(title ?? "").font(.system(size: 15)).foregroundStyle(.white))
                    .allowsHitTesting(false)
            }
        }
    }
}

/// Deletes on touch-down, then repeats while held.
struct DeleteKey: View {
    let model: KeyboardModel
    @State private var repeatTask: Task<Void, Never>?
    @State private var pressed = false

    var body: some View {
        Image(systemName: "delete.left")
            .font(.system(size: 17))
            .accessibilityLabel(String(localized: "刪除"))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(KeyFace(function: true, pressed: pressed))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !pressed else { return }
                        pressed = true
                        model.delete()
                        // Characters first; held on, whole words, like the system keyboard.
                        repeatTask = Task {
                            try? await Task.sleep(for: .milliseconds(450))
                            var repeats = 0
                            while !Task.isCancelled {
                                let byWord = repeats >= 12
                                if byWord { model.deleteWord() } else { model.delete() }
                                repeats += 1
                                try? await Task.sleep(for: .milliseconds(byWord ? 160 : 80))
                            }
                        }
                    }
                    .onEnded { _ in
                        pressed = false
                        repeatTask?.cancel()
                        repeatTask = nil
                    }
            )
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { model.delete() }
    }
}
