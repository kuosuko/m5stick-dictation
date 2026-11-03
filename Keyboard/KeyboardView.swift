import SwiftUI

struct KeyboardView: View {
    let model: KeyboardModel
    @State private var hingePartiallyOpen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let gap: CGFloat = 6
    private let rowGap: CGFloat = 9

    var body: some View {
        VStack(spacing: 0) {
            TopBar(model: model)
                .frame(height: 44)

            GeometryReader { proxy in
                ZStack {
                    if model.isCandidatePanelOpen {
                        CandidatePanel(model: model)
                            .transition(panelTransition)
                    } else if let accessory = model.accessory {
                        AccessoryPanel(model: model, kind: accessory)
                            .transition(panelTransition)
                    } else if model.mode == .home {
                        HomePanel(model: model)
                            .transition(keysTransition)
                    } else {
                        keyArea(size: proxy.size, split: model.allowsSplit ? split(in: proxy) : nil)
                            .transition(keysTransition)
                    }
                }
            }
            .padding(.top, 2)
            .padding(.bottom, 4)
        }
        .modifier(HingeObserver(isPartiallyOpen: $hingePartiallyOpen))
        // One spring for every way the panel opens or closes (button, commit, empty candidates).
        .animation(.spring(duration: 0.32, bounce: 0.12), value: model.isCandidatePanelOpen)
        .animation(.spring(duration: 0.32, bounce: 0.12), value: model.accessory)
        .animation(.spring(duration: 0.32, bounce: 0.12), value: model.mode)
    }

    /// The grid drops down out of the candidate bar; the keys recede behind it.
    private var panelTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -12))
    }

    private var keysTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.97, anchor: .bottom))
    }

    // MARK: Split

    /// Where the keys leave a gap: the left half ends at `leftEnd`, the right starts at `rightStart`.
    private struct Split {
        let leftEnd: CGFloat
        let rightStart: CGFloat
    }

    /// Splits only while the Duo is partly folded like a book. Flat open, closed,
    /// and laptop posture (fold runs across the screen) keep one keyboard.
    private func split(in proxy: GeometryProxy) -> Split? {
        if #available(iOS 27.1, *) {
            // Active only while partly folded; zero-width when flat.
            let folds = proxy.reservedRegions(kind: .division, layoutDirectionBehavior: .fixed)
            if let fold = folds.first(where: { $0.isActive && $0.frame.height >= $0.frame.width }),
               fold.frame.minX > 80, fold.frame.maxX < proxy.size.width - 80 {
                return Split(leftEnd: fold.frame.minX, rightStart: fold.frame.maxX)
            }
        }
        // Keyboard extensions may not get reserved regions; fall back to the hinge.
        guard hingePartiallyOpen, model.isPortrait else { return nil }
        let half = proxy.size.width / 2
        return Split(leftEnd: half - 22, rightStart: half + 22)
    }

    // MARK: Rows

    private func keyArea(size: CGSize, split: Split?) -> some View {
        let rows = KeyboardLayouts.rows(language: model.language, layer: model.layer)
        let bottom = KeyboardLayouts.bottomRow(
            showsGlobe: model.needsGlobe, split: split != nil,
            chinesePunctuation: model.language == .zhuyin && model.layer == .letters
        )
        let columns = KeyboardLayouts.columns(language: model.language, layer: model.layer)
        let all = rows + [bottom]
        let unit = (size.height - rowGap * CGFloat(all.count - 1)) / all.reduce(0) { $0 + $1.scale }

        return VStack(spacing: rowGap) {
            ForEach(all) { row in
                Group {
                    if let split {
                        HStack(spacing: 0) {
                            half(row.left, width: split.leftEnd, columns: columns.half)
                            Spacer(minLength: 0)
                            half(row.right, width: size.width - split.rightStart, columns: columns.half)
                        }
                    } else {
                        half(row.all, width: size.width, columns: columns.whole)
                    }
                }
                .frame(height: unit * row.scale)
            }
        }
    }

    private func half(_ items: [KeyItem], width: CGFloat, columns: Double) -> some View {
        let unit = (width - 6 - gap * (columns - 1)) / columns
        return HStack(spacing: gap) {
            ForEach(items) { item in
                if let weight = item.width {
                    key(item).frame(width: weight * unit + max(weight - 1, 0) * gap)
                } else {
                    key(item)
                }
            }
        }
        .padding(.horizontal, 3)
        .frame(width: width)
    }

    @ViewBuilder
    private func key(_ item: KeyItem) -> some View {
        switch item {
        case .character(let key, _):
            CharacterKey(
                key: key,
                uppercase: model.language == .english && model.shift != .off,
                // Zhuyin keys sit on the QWERTY keys; swiping up types that letter.
                alternate: model.language == .zhuyin && model.layer == .letters ? key.output : nil,
                action: { model.tap(key) },
                alternateAction: { model.type($0) }
            )
        case .literal(let key, let alternate, _):
            CharacterKey(key: key, uppercase: false, alternate: alternate,
                         action: { model.tapLiteral(key) }, alternateAction: { model.tapLiteral(CharKey($0)) })
        case .shift:
            ShiftKey(model: model)
        case .delete:
            DeleteKey(model: model)
        case .layerSwitch:
            FunctionKey(title: model.layer == .numbers ? "#+=" : "123") {
                model.layer = model.layer == .numbers ? .symbols : .numbers
            }
        case .layerToggle:
            FunctionKey(title: layerTitle) {
                model.layer = model.layer == .letters ? .numbers : .letters
            }
        case .language:
            LanguageKey(language: model.language, action: model.toggleLanguage)
        case .globe:
            FunctionKey(systemImage: "globe", label: String(localized: "下一個鍵盤"), action: model.nextKeyboard)
        case .space:
            SpaceKey(model: model)
        case .returnKey:
            FunctionKey(title: returnTitle, prominent: model.isComposing, action: model.returnKey)
        case .kaomoji:
            KaomojiKey(model: model)
        case .cards:
            FunctionKey(systemImage: "person.text.rectangle", label: String(localized: "我的資訊")) { model.open(.cards) }
        case .flex:
            Spacer(minLength: 0)
        }
    }

    private var layerTitle: String {
        guard model.layer == .letters else { return model.language == .zhuyin ? "ㄅㄆㄇ" : "ABC" }
        return "123"
    }

    private var returnTitle: String {
        if model.isComposing { return String(localized: "確認") }
        return model.language == .zhuyin ? String(localized: "換行") : "return"
    }
}

private struct HingeObserver: ViewModifier {
    @Binding var isPartiallyOpen: Bool

    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            content.onHingeChange { _, context in
                isPartiallyOpen = context.hinge?.status == .partiallyOpen
            }
        } else {
            content
        }
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
                    Text(String(localized: "我的資訊"))
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
                }
            }
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

    /// 全部 first so everything is one scroll away; 我的 only once there are some.
    private var categories: [Kaomoji.Category] {
        let all = Kaomoji.Category(id: Self.allID, name: String(localized: "全部"), items: model.stripKaomoji)
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

// MARK: - Candidate panel

/// Every candidate for the segment being chosen: the rest of the sentence on
/// its own row, then phrases in wider cells, then single characters.
private struct CandidatePanel: View {
    let model: KeyboardModel

    var body: some View {
        let rest = model.candidates.first(where: \.isWholeRest)
        let others = model.candidates.filter { !$0.isWholeRest }
        let phrases = others.filter { $0.value.count > 1 }
        let singles = others.filter { $0.value.count <= 1 }

        ScrollView {
            VStack(spacing: 6) {
                SegmentPicker(model: model)
                if let rest {
                    cell(rest, prominent: true)
                }
                grid(phrases, minimum: 104)
                grid(singles, minimum: 50)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
        .id(model.focusIndex)
    }

    private func grid(_ items: [ZhuyinCandidate], minimum: CGFloat) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minimum), spacing: 6)], spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, candidate in
                cell(candidate, prominent: false)
            }
        }
    }

    private func cell(_ candidate: ZhuyinCandidate, prominent: Bool) -> some View {
        Button { model.select(candidate) } label: {
            Text(candidate.value)
                .font(.system(size: 20, weight: prominent ? .semibold : .regular))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, 8)
        }
        .buttonStyle(PressStyle())
        .frame(height: 44)
    }
}

/// The sentence split into segments; tap one to change just that part.
private struct SegmentPicker: View {
    let model: KeyboardModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(model.segments.enumerated()), id: \.offset) { _, segment in
                    let focused = segment.start == model.focusIndex
                    Button { model.focus(segment) } label: {
                        Text(segment.text)
                            .font(.system(size: 18, weight: focused ? .semibold : .regular))
                            .foregroundStyle(focused ? Color.white : Color.primary)
                            .padding(.horizontal, 10)
                            .frame(height: 34)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(focused ? Color.accentColor : Color.primary.opacity(0.06))
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(focused ? .isSelected : [])
                }
            }
        }
        .padding(.bottom, 2)
    }
}

/// One word in the candidate or association bar. Uses the same touch
/// handling as the keys, which catch every tap; a Button here missed some.
private struct BarCandidate: View {
    let text: String
    var bold = false
    let action: () -> Void

    @State private var pressed = false

    var body: some View {
        Text(text)
            .font(.system(size: 20, weight: bold ? .semibold : .regular))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(pressed ? 0.1 : 0))
                    .padding(.vertical, 5)
            )
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !pressed {
                            pressed = true
                            KeyTiming.shared.touchDown(key: "candidate", eventTime: value.time)
                        }
                    }
                    .onEnded { value in
                        pressed = false
                        // A finger that drifts a little still means this word.
                        guard abs(value.translation.width) < 30, abs(value.translation.height) < 30 else { return }
                        KeyTiming.shared.measure(key: "candidate", action)
                    }
            )
            .accessibilityElement()
            .accessibilityLabel(text)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
    }
}

/// Lays items out left to right and leaves out whatever no longer fits.
/// The first item always shows, truncated if it is wider than the row.
private struct FittingRow: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 44)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (index, subview) in subviews.enumerated() {
            let ideal = subview.sizeThatFits(ProposedViewSize(width: nil, height: bounds.height))
            let width = index == 0 ? min(ideal.width, bounds.width) : ideal.width
            let fits = x + width <= bounds.maxX
            // Past the edge, out of reach; once one is left out, so are the rest.
            let origin = fits ? CGPoint(x: x, y: bounds.minY) : CGPoint(x: bounds.maxX + 2000, y: bounds.minY)
            subview.place(at: origin, proposal: ProposedViewSize(width: width, height: bounds.height))
            x = fits ? x + width : .infinity
        }
    }
}

private struct BarButton: View {
    let systemImage: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.medium))
                .frame(width: 36)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

// MARK: - Top bar

private struct TopBar: View {
    let model: KeyboardModel

    var body: some View {
        Group {
            if model.isComposing {
                HStack(spacing: 0) {
                    if model.focusIndex > 0 {
                        BarButton(systemImage: "chevron.left", label: String(localized: "上一段"), action: model.moveFocusBackward)
                    }
                    if model.isCandidatePanelOpen {
                        Spacer(minLength: 0)
                    } else {
                        // Not a scroll view: a tap that drifts a little would
                        // start a scroll and be dropped. The ⌄ panel has the rest.
                        FittingRow {
                            ForEach(Array(model.candidates.prefix(20).enumerated()), id: \.offset) { index, candidate in
                                BarCandidate(text: candidate.value, bold: index == 0) { model.select(candidate) }
                            }
                        }
                        .padding(.horizontal, 4)
                        .clipped()
                    }
                    if model.canMoveFocusForward {
                        BarButton(systemImage: "chevron.right", label: String(localized: "下一段"), action: model.moveFocusForward)
                    }
                    if !model.candidates.isEmpty {
                        Divider().padding(.vertical, 10)
                        Button(action: model.toggleCandidatePanel) {
                            Image(systemName: "chevron.down")
                                .font(.body.weight(.medium))
                                .rotationEffect(.degrees(model.isCandidatePanelOpen ? 180 : 0))
                                .frame(width: 44)
                                .frame(maxHeight: .infinity)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(model.isCandidatePanelOpen ? String(localized: "收起候選字") : String(localized: "展開候選字"))
                    }
                }
            } else if model.showsKaomojiStrip {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 0) {
                        ForEach(model.stripKaomoji, id: \.self) { kaomoji in
                            Button { model.insert(kaomoji: kaomoji) } label: {
                                Text(kaomoji)
                                    .font(.system(size: 16))
                                    .lineLimit(1)
                                    .padding(.horizontal, 10)
                                    .frame(maxHeight: .infinity)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 4)
                }
            } else if !model.associations.isEmpty {
                FittingRow {
                    ForEach(Array(model.associations.prefix(20).enumerated()), id: \.offset) { _, association in
                        BarCandidate(text: association.value) { model.accept(association: association) }
                    }
                }
                .padding(.horizontal, 4)
                .clipped()
            } else if !model.suggestions.isEmpty {
                HStack(spacing: 0) {
                    ForEach(Array(model.suggestions.enumerated()), id: \.offset) { index, suggestion in
                        if index > 0 { Divider().padding(.vertical, 10) }
                        Button { model.accept(suggestion: suggestion) } label: {
                            Text(suggestion)
                                .font(.system(size: 17))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else if !model.hasFullAccess {
                hint(String(localized: "到設定 › 一般 › 鍵盤 › Stick 打開「允許完整取用」，才收得到 Stick 的文字"))
            } else if model.engineFailed {
                hint(String(localized: "注音詞庫載入失敗"), tint: .red)
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

/// Types on release and shows the enlarged letter while held, like the system
/// keyboard. Keys with an alternate type it when swiped up.
private struct CharacterKey: View {
    let key: CharKey
    let uppercase: Bool
    let alternate: String?
    let action: () -> Void
    let alternateAction: (String) -> Void

    @State private var pressed = false
    @State private var swipedUp = false

    private static let swipeDistance: CGFloat = 18

    var body: some View {
        let label = uppercase ? key.label.uppercased() : key.label
        Text(label)
            .font(.system(size: key.label.count > 1 ? 16 : 22))
            .minimumScaleFactor(0.6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topTrailing) {
                if let alternate {
                    Text(alternate)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 3)
                        .padding(.trailing, 4)
                }
            }
            .background(KeyFace(pressed: pressed))
            .overlay(alignment: .top) {
                if pressed {
                    KeyPreview(text: swipedUp ? (alternate ?? label) : label)
                        .offset(y: -58)
                        .allowsHitTesting(false)
                }
            }
            .zIndex(pressed ? 1 : 0)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !pressed {
                            pressed = true
                            KeyTiming.shared.touchDown(key: key.id, eventTime: value.time)
                        }
                        swipedUp = alternate != nil && value.translation.height < -Self.swipeDistance
                    }
                    .onEnded { value in
                        let up = alternate != nil && value.translation.height < -Self.swipeDistance
                        // Off the instant the finger lifts, like the system keyboard.
                        pressed = false
                        swipedUp = false
                        KeyTiming.shared.measure(key: key.id) {
                            if up, let alternate {
                                alternateAction(alternate)
                            } else if abs(value.translation.width) < 30, value.translation.height < 30 {
                                action()
                            }
                        }
                    }
            )
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
    }
}

private struct KeyPreview: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 30))
            .frame(minWidth: 48, minHeight: 52)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.regularMaterial)
                    .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
            )
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
        Text(model.language == .zhuyin ? String(localized: "空白") : "space")
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
                            model.beginCursorDrag()
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
            .accessibilityLabel(model.language == .zhuyin ? String(localized: "空白") : "space")
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

/// Tap: a row of kaomoji in the candidate bar. Hold: the full panel.
struct KaomojiKey: View {
    let model: KeyboardModel
    @State private var pressed = false

    var body: some View {
        Text("^_^")
            .font(.system(size: 15))
            .foregroundStyle(model.showsKaomojiStrip ? Color.accentColor : Color.primary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(KeyFace(function: true, pressed: pressed))
            .contentShape(Rectangle())
            .gesture(
                LongPressGesture(minimumDuration: 0.35)
                    .onEnded { _ in model.open(.kaomoji) }
                    .exclusively(before: TapGesture().onEnded { model.toggleKaomojiStrip() })
            )
            // Only drives the pressed look; runs alongside the tap / hold gesture.
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in pressed = true }
                    .onEnded { _ in pressed = false }
            )
            .accessibilityElement()
            .accessibilityLabel(String(localized: "顏文字"))
            .accessibilityHint(String(localized: "按住打開完整的顏文字面板"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { model.toggleKaomojiStrip() }
    }
}

private struct LanguageKey: View {
    let language: InputLanguage
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 2) {
                Text(verbatim: "中").foregroundStyle(language == .zhuyin ? .primary : .tertiary)
                Text(verbatim: "英").foregroundStyle(language == .english ? .primary : .tertiary)
            }
            .font(.system(size: 15, weight: .medium))
            .accessibilityLabel(language == .zhuyin ? String(localized: "切換到英文") : String(localized: "切換到注音"))
        }
        .buttonStyle(PressStyle(function: true))
    }
}

private struct ShiftKey: View {
    let model: KeyboardModel

    var body: some View {
        Button(action: model.tapShift) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .accessibilityLabel("Shift")
        }
        .buttonStyle(PressStyle(function: model.shift == .off))
    }

    private var icon: String {
        switch model.shift {
        case .off: "shift"
        case .once: "shift.fill"
        case .locked: "capslock.fill"
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
