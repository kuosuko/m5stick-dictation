import SwiftUI

struct SetupState: Equatable {
    var stickPaired: Bool
    var keyboardReady: Bool
    var hasKey: Bool

    var isComplete: Bool { stickPaired && keyboardReady && hasKey }
}

/// Home as a bento board: tight tiles on a grey page, each one thing. The
/// Stick and its numbers, the latest result big, earlier ones in a list,
/// and the shortcuts the keyboard also has. One column on the outer display;
/// on the inner display the board splits into two pages at the fold.
struct HomeView: View {
    let link: StickLink
    @Bindable var store: DictationStore
    var demo: DemoScenario?
    /// Lab preview only: pretend the Duo is half-folded (true) or flat (false).
    var previewHalfFolded: Bool?

    @State private var sheet: HomeSheet?
    @State private var showingLab = false
    @State private var hingePartiallyOpen = false

    enum HomeSheet: String, Identifiable {
        case settings
        case cards
        case kaomoji
        case find

        var id: String { rawValue }
    }
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var isUpright = true
    /// Whether the bars sit in the Duo's side rail, as iOS reports it; nil
    /// before iOS 27.1, where orientation has to stand in.
    @State private var barsAtSide: Bool?
    @Environment(\.scenePhase) private var scenePhase

    private var history: [Dictation] { demo?.history ?? store.history }
    private var battery: Int? { demo?.battery ?? link.batteryLevel }
    private var connected: Bool { demo != nil || link.status == .connected }
    private var page: PageLook { LabSettings.shared.page }
    private var today: DayStats { DayStats(history: history) }

    private var setup: SetupState {
        demo?.setup ?? SetupState(
            stickPaired: link.hasPairedStick,
            keyboardReady: store.keyboardReady,
            hasKey: store.providerReady
        )
    }

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                // Two pages on the inner display, and on the outer one held
                // sideways, where the stacked board would not fit.
                if sizeClass == .regular || verticalSizeClass == .compact {
                    wide(proxy)
                } else {
                    narrow(width: proxy.size.width)
                }
                Color.clear
                    .onChange(of: proxy.size, initial: true) { _, size in isUpright = size.height > size.width }
            }
            .background(page.backgroundColor)
            .modifier(VerticalBarObserver(barsAtSide: $barsAtSide))
            // The bottom bar is only at the bottom on the inner display held
            // upright; everywhere else it is in the side rail, and the board
            // may use the strip iOS still keeps free for it.
            .modifier(FreeBottomStrip(barsAtBottom: barsAtSide.map { !$0 } ?? (sizeClass == .regular && isUpright)))
            // The shortcuts the keyboard also has, and settings. On the Duo's
            // outer display iOS moves this bar to the side rail.
            .toolbar {
                ToolbarItemGroup(placement: .bottomBar) {
                    Button(String(localized: "我的資訊"), systemImage: "person.text.rectangle") { sheet = .cards }
                    Button(String(localized: "顏文字"), systemImage: "face.smiling") { sheet = .kaomoji }
                    Spacer()
                    Button(String(localized: "設定"), systemImage: "gearshape") { sheet = .settings }
                }
            }
        }
        .sheet(item: $sheet) { item in
            switch item {
            case .settings: SettingsView(store: store, link: link, demo: demo != nil)
            case .cards: SheetStack { CardsEditor() }
            case .kaomoji: SheetStack { KaomojiEditor() }
            case .find: FindStickView(link: link, demo: demo != nil)
            }
        }
        // Floats over everything, like the AirPods card.
        .overlay {
            if let pairing = demo?.pairing ?? link.pairing {
                PairingCard(pairing: pairing, batteryLevel: battery, onConnect: link.pair, onClose: link.dismissPairing)
            }
        }
        .sheet(isPresented: $showingLab) {
            SheetStack { LabView(link: link, store: store) }
        }
        .onAppear {
            if demo?.opensLab == true { showingLab = true }
            if demo?.opensFind == true { sheet = .find }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active { store.refreshSetup() }
        }
        .modifier(HingeObserver(isPartiallyOpen: $hingePartiallyOpen))
        .animation(.spring(duration: 0.45, bounce: 0), value: hingePartiallyOpen)
        .overlay(alignment: .top) { DreamingBadge(dreaming: store.dreaming) }
    }

    // MARK: Layouts

    /// Tiles sit on a four-unit grid; `span(n)` is the width of n units.
    private func unit(for width: CGFloat) -> CGFloat {
        (width - page.edge * 2 - page.gap * 3) / 4
    }

    private func narrow(width: CGFloat) -> some View {
        let unit = unit(for: width)
        let gap = page.gap
        func span(_ n: CGFloat) -> CGFloat { unit * n + gap * (n - 1) }
        // No page scroll: the board is the screen. The top row keeps its
        // square tiles; the latest and earlier tiles share what is left
        // equally and scroll inside themselves when they run out.
        return VStack(spacing: gap) {
            HStack(spacing: gap) {
                stickTile(height: span(2))
                    .frame(width: span(2), height: span(2))
                VStack(spacing: gap) {
                    batteryTile
                    TodayTile(stats: today, page: page)
                }
                .frame(width: span(2), height: span(2))
            }
            latestTile(display: true)
                .frame(maxHeight: .infinity)
            if !setup.isComplete {
                Tile(page: page) { SetupChecklist(setup: setup) { sheet = .settings } }
            }
            if history.count > 1 {
                earlierTile(rows: Array(history.dropFirst()), scrolls: true)
                    .frame(maxHeight: .infinity)
            }
        }
        .padding(.horizontal, page.edge)
        .padding(.vertical, page.edge)
    }

    private func wide(_ proxy: GeometryProxy) -> some View {
        let flatEdge = proxy.size.width * page.openStickShare
        let fold = halfFoldedSplit(in: proxy) ?? (flatEdge, flatEdge)
        let gap = page.gap
        return HStack(spacing: 0) {
            leftPage(width: fold.leftEnd - page.edge - gap / 2)
                .padding(.leading, page.edge)
                .padding(.trailing, gap / 2)
                .frame(width: fold.leftEnd)
            Spacer(minLength: 0)
            rightPage(width: proxy.size.width - fold.rightStart - page.edge - gap / 2)
                .padding(.leading, gap / 2)
                .padding(.trailing, page.edge)
                .frame(width: proxy.size.width - fold.rightStart)
        }
        .padding(.vertical, page.edge)
    }

    private func leftPage(width: CGFloat) -> some View {
        let unit = (width - page.gap * 3) / 4
        let gap = page.gap
        func span(_ n: CGFloat) -> CGFloat { unit * n + gap * (n - 1) }
        return VStack(spacing: gap) {
            HStack(spacing: gap) {
                stickTile(height: span(2))
                    .frame(width: span(2), height: span(2))
                VStack(spacing: gap) {
                    batteryTile
                    TodayTile(stats: today, page: page)
                }
                .frame(width: span(2), height: span(2))
            }
            // Fills the page like the list opposite, so both columns read as one board.
            latestTile(display: true)
                .frame(maxHeight: .infinity)
            if !setup.isComplete {
                Tile(page: page) { SetupChecklist(setup: setup) { sheet = .settings } }
            }
        }
    }

    private func rightPage(width: CGFloat) -> some View {
        let unit = (width - page.gap * 3) / 4
        let gap = page.gap
        func span(_ n: CGFloat) -> CGFloat { unit * n + gap * (n - 1) }
        return VStack(spacing: gap) {
            // Squares, like the battery and today tiles opposite.
            HStack(spacing: gap) {
                LatencyTile(stats: today, page: page)
                WeekTile(stats: today, page: page)
            }
            .frame(height: span(2))
            earlierTile(rows: Array(history.dropFirst()), scrolls: true)
                .frame(maxHeight: .infinity)
        }
    }


    /// Either side of the fold, but only while the Duo is half-folded like a
    /// book (fold running top to bottom). Flat, or folded like a laptop: nil.
    private func halfFoldedSplit(in proxy: GeometryProxy) -> (leftEnd: CGFloat, rightStart: CGFloat)? {
        let middle = proxy.size.width / 2
        if let previewHalfFolded { return previewHalfFolded ? (middle, middle) : nil }
        if #available(iOS 27.1, *),
           let hinge = proxy.reservedRegions(kind: .division, layoutDirectionBehavior: .fixed)
               .first(where: { $0.isActive && $0.frame.height >= $0.frame.width }) {
            return (hinge.frame.minX, hinge.frame.maxX)
        }
        // The system may not report the region; the hinge itself still says.
        guard hingePartiallyOpen, proxy.size.height > proxy.size.width else { return nil }
        return (middle, middle)
    }

    // MARK: Tiles

    private func stickTile(height: CGFloat) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let phase = demo?.phase ?? HomePhase.current(link: link, store: store, now: context.date)
            StickTile(phase: phase, now: context.date, page: page, height: height)
        }
    }

    private var batteryTile: some View {
        // Only a paired stick can be looked for.
        Button {
            sheet = .find
        } label: {
            BatteryTile(level: connected ? battery : nil, connected: connected, asleep: link.isAsleep, page: page)
        }
        .buttonStyle(.plain)
        .disabled(!(demo != nil || link.hasPairedStick))
        .accessibilityHint(String(localized: "尋找 Stick"))
    }

    /// `display`: the tile is tall, so the text is set large and centred,
    /// like a quote, instead of sitting in the top corner of a white block.
    private func latestTile(display: Bool = false) -> some View {
        Tile(page: page) {
            if let latest = history.first {
                LatestCard(dictation: latest, page: page, display: display)
            } else {
                Text(String(localized: "用 Stick 說的話會出現在這裡"))
                    .font(.system(size: page.latestSize * 0.8, design: page.latestDesign.font))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// The earlier dictations down a timeline. With room to spare the rows
    /// spread along it; with more rows than room, they scroll.
    private func earlierTile(rows: [Dictation], scrolls: Bool) -> some View {
        Tile(page: page) {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "稍早"))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)
                if rows.isEmpty {
                    Text(String(localized: "還沒有更早的"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if scrolls {
                    // Spread over at least the tile's height, so a few rows
                    // fill it and more than fit scroll. (ViewThatFits always
                    // took the spread version, whose rows squeeze to fit.)
                    GeometryReader { proxy in
                        ScrollView {
                            HistoryTimeline(rows: rows, mark: page.mark, spread: true)
                                .frame(minHeight: proxy.size.height, alignment: .top)
                        }
                        .scrollIndicators(.hidden)
                        .scrollBounceBehavior(.basedOnSize)
                    }
                } else {
                    HistoryTimeline(rows: rows, mark: page.mark, spread: false)
                }
            }
        }
    }

}

// MARK: - Numbers

/// What today's dictations add up to, for the stat tiles.
struct DayStats {
    let count: Int
    let weekCount: Int
    let seconds: Double
    let averageLatency: Double?
    /// Seconds spoken in each hour of today, midnight first.
    let hourSeconds: [Double]
    /// Dictations on each of the last seven days, oldest first.
    let dayCounts: [Int]
    /// Today's waits, newest first.
    let latencies: [Double]

    init(history: [Dictation], now: Date = .now) {
        let calendar = Calendar.current
        let done = history.filter { $0.text != nil && calendar.isDate($0.date, inSameDayAs: now) }
        let week = history.filter { $0.text != nil && now.timeIntervalSince($0.date) < 7 * 86400 }
        weekCount = week.count
        count = done.count
        seconds = done.reduce(0) { $0 + $1.audioSeconds }
        averageLatency = done.isEmpty ? nil : done.reduce(0) { $0 + $1.latency } / Double(done.count)
        latencies = done.map(\.latency)
        var hours = [Double](repeating: 0, count: 24)
        for item in done { hours[calendar.component(.hour, from: item.date)] += item.audioSeconds }
        hourSeconds = hours
        let today = calendar.startOfDay(for: now)
        dayCounts = (0..<7).reversed().map { back in
            let day = calendar.date(byAdding: .day, value: -back, to: today) ?? today
            return week.filter { calendar.isDate($0.date, inSameDayAs: day) }.count
        }
    }

    var countText: String { String(localized: "\(count) 段") }
    var weekCountText: String { String(localized: "\(weekCount) 段") }

    var secondsText: String {
        let whole = Int(seconds.rounded())
        return whole >= 60 ? String(localized: "\(whole / 60) 分 \(whole % 60) 秒") : String(localized: "\(whole) 秒")
    }

    var latencyText: String {
        averageLatency.map { String(format: String(localized: "%.1f 秒"), $0) } ?? "—"
    }
}

private struct FreeBottomStrip: ViewModifier {
    let barsAtBottom: Bool

    func body(content: Content) -> some View {
        content.ignoresSafeArea(.container, edges: barsAtBottom ? [] : .bottom)
    }
}

// MARK: - Tile parts

/// One rounded block on the board. Content sits top-left and the tile
/// stretches to whatever frame it is given. A tile beside the screen edge
/// takes a corner concentric with the display's own; the rest use the
/// board's radius.
private struct Tile<Content: View, Underlay: View>: View {
    let page: PageLook
    /// Drawn between the tile's surface and its content, inside the shape.
    let underlay: Underlay
    let content: Content

    init(page: PageLook, @ViewBuilder underlay: () -> Underlay = { EmptyView() },
         @ViewBuilder content: () -> Content) {
        self.page = page
        self.underlay = underlay()
        self.content = content()
    }

    var body: some View {
        content
            .padding(page.tilePadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background {
                page.tileShape.fill(page.tileColor)
                underlay
            }
    }
}

/// The label and the number on the left, the drawing on the right, all
/// sitting on the same bottom line.
private struct FigureTile<Figure: View>: View {
    let label: String
    let value: String
    let detail: String
    let page: PageLook
    var warning = false
    @ViewBuilder let figure: Figure

    var body: some View {
        Tile(page: page) {
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(label)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 6)
                    Text(value)
                        .font(.system(size: page.statSize, weight: .semibold, design: page.titleDesign.font))
                        .foregroundStyle(warning ? Color.red : Color.primary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .contentTransition(.numericText())
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .fixedSize(horizontal: true, vertical: false)
                figure
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }
        .animation(.spring(duration: 0.3, bounce: 0), value: value)
    }
}

/// A battery drawn the way the status bar draws one, filled to the level.
private struct BatteryTile: View {
    let level: Int?
    let connected: Bool
    var asleep = false
    let page: PageLook

    var body: some View {
        FigureTile(label: "Stick", value: connected ? level.map { "\($0)%" } ?? String(localized: "已連線") : "—",
                   detail: connected ? String(localized: "電量") : asleep ? String(localized: "在睡") : String(localized: "沒連上"), page: page, warning: low) {
            HStack(spacing: 2) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.3), lineWidth: 1.5)
                    .frame(width: 38, height: 18)
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                            .fill(low ? Color.red : page.mark)
                            .padding(3.5)
                            .frame(width: 38 * fraction)
                    }
                Capsule()
                    .fill(Color.primary.opacity(0.3))
                    .frame(width: 2, height: 7)
            }
            .padding(.bottom, 4)
            .animation(.spring(duration: 0.6, bounce: 0), value: fraction)
        }
    }

    private var fraction: CGFloat { connected ? CGFloat(level ?? 0) / 100 : 0 }
    private var low: Bool { connected && (level ?? 100) < 15 }
}

/// When today was spoken: one bar per hour, as tall as the talk in it.
private struct TodayTile: View {
    let stats: DayStats
    let page: PageLook

    var body: some View {
        FigureTile(label: String(localized: "今天"), value: stats.countText, detail: stats.secondsText, page: page) {
            // Two-hour slots: a bar per hour would be too thin beside the number.
            let slots = stride(from: 0, to: 24, by: 2).map { stats.hourSeconds[$0] + stats.hourSeconds[$0 + 1] }
            Bars(values: slots, highlight: Calendar.current.component(.hour, from: .now) / 2, mark: page.mark)
                .frame(height: 28)
        }
    }
}

/// The last seven days, today at the right.
private struct WeekTile: View {
    let stats: DayStats
    let page: PageLook

    var body: some View {
        FigureTile(label: String(localized: "這週"), value: stats.weekCountText, detail: String(localized: "七天內"), page: page) {
            Bars(values: stats.dayCounts.map(Double.init), highlight: 6, mark: page.mark, spacing: 4)
                .frame(height: 44)
        }
    }
}

/// Each wait today as a dot on a 0–3 second line; the average is the mark.
private struct LatencyTile: View {
    let stats: DayStats
    let page: PageLook
    private let scale = 3.0

    var body: some View {
        FigureTile(label: String(localized: "放開到出字"), value: stats.latencyText, detail: String(localized: "今天平均"), page: page) {
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.08))
                        .frame(height: 3)
                    ForEach(Array(stats.latencies.enumerated()), id: \.offset) { _, wait in
                        Circle()
                            .fill(Color.primary.opacity(0.25))
                            .frame(width: 7, height: 7)
                            .offset(x: width * min(wait / scale, 1) - 3.5)
                    }
                    if let average = stats.averageLatency {
                        Capsule()
                            .fill(page.mark)
                            .frame(width: 3, height: 14)
                            .offset(x: width * min(average / scale, 1) - 1.5)
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 20)
            .padding(.bottom, 6)
        }
    }
}

/// The Stick with its screen mirrored, and what it is doing underneath.
private struct StickTile: View {
    let phase: HomePhase
    let now: Date
    let page: PageLook
    let height: CGFloat

    var body: some View {
        Tile(page: page) {
            VStack(alignment: .leading, spacing: 0) {
                StickIllustration(screen: phase.screen, height: max(height - page.tilePadding * 2 - 58, 60))
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 6)
                HStack(spacing: 6) {
                    ParrotMark(height: 13)
                    Text(phase.title)
                        .font(.system(size: 15, weight: .semibold, design: page.titleDesign.font))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Text(phase.subtitle(now: now))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .id(phase.kind)
            .transition(.opacity)
        }
        .animation(.spring(duration: 0.35, bounce: 0), value: phase.kind)
    }
}

/// Thin bars from the bottom, scaled to the tallest; empty hours show as a dot.
private struct Bars: View {
    let values: [Double]
    var highlight: Int?
    var mark: Color = .primary
    var spacing: CGFloat = 2

    var body: some View {
        GeometryReader { proxy in
            let top = max(values.max() ?? 0, 1)
            let width = (proxy.size.width - spacing * CGFloat(values.count - 1)) / CGFloat(values.count)
            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                    Capsule()
                        .fill(index == highlight && value > 0 ? mark : Color.primary.opacity(value > 0 ? 0.35 : 0.08))
                        .frame(width: width, height: max(proxy.size.height * value / top, width))
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .animation(.spring(duration: 0.5, bounce: 0), value: values)
    }
}

// MARK: - Setup

private struct SetupChecklist: View {
    let setup: SetupState
    let openAppSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(String(localized: "還差幾步"))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 6)
            step(String(localized: "連上 Stick"), detail: String(localized: "打開 Stick 放在手機旁邊"), done: setup.stickPaired)
            Divider().padding(.leading, 36)
            step(String(localized: "加入 Stick 鍵盤"), detail: String(localized: "設定 › 一般 › 鍵盤，並打開「允許完整取用」"), done: setup.keyboardReady) {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            Divider().padding(.leading, 36)
            step(String(localized: "設定轉寫服務"), detail: String(localized: "Groq、OpenAI 或自己的伺服器"), done: setup.hasKey, action: openAppSettings)
        }
    }

    private func step(_ title: String, detail: String, done: Bool, action: (() -> Void)? = nil) -> some View {
        HStack(spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(done ? Color.accentColor : Color.secondary.opacity(0.5))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(done ? .secondary : .primary)
                if !done {
                    Text(detail).font(.footnote).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if !done, let action {
                Button(String(localized: "前往"), action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Results

private struct LatestCard: View {
    let dictation: Dictation
    let page: PageLook
    /// Large, centred type that fills a tall tile; long text steps down in
    /// size, and only scrolls once the normal size does not fit either.
    var display = false
    @State private var copied = false
    @State private var showingChanges = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(meta)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            if let text = dictation.text {
                if display {
                    ViewThatFits(in: .vertical) {
                        ForEach([2.0, 1.6, 1.3], id: \.self) { factor in
                            body(text, size: page.latestSize * factor)
                                .frame(maxHeight: .infinity, alignment: .center)
                        }
                        scrolling(text)
                    }
                } else {
                    scrolling(text)
                }
            } else {
                Text(dictation.error ?? String(localized: "沒有轉成功"))
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            if let text = dictation.text {
                HStack {
                    if dictation.hasAudio {
                        PlayButton(id: dictation.id)
                    }
                    if dictation.transcript != nil {
                        Button(String(localized: "改了什麼"), systemImage: "text.redaction") { showingChanges = true }
                            .font(.footnote.weight(.medium))
                            .buttonStyle(.borderless)
                            .tint(.secondary)
                    }
                    Spacer()
                    Button(copied ? String(localized: "已複製") : String(localized: "複製"), systemImage: copied ? "checkmark" : "doc.on.doc") {
                        UIPasteboard.general.string = text
                        copied = true
                    }
                    .font(.footnote.weight(.medium))
                    .buttonStyle(.borderless)
                    .tint(page.mark)
                    .contentTransition(.symbolEffect(.replace))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: dictation.id) { copied = false }
        .sheet(isPresented: $showingChanges) { ChangesView(dictation: dictation) }
    }

    private func body(_ text: String, size: CGFloat) -> some View {
        Text(text)
            .font(.system(size: size, design: page.latestDesign.font))
            .lineSpacing(size * 0.3)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func scrolling(_ text: String) -> some View {
        ScrollView {
            body(text, size: page.latestSize)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
    }

    private var meta: String {
        let time = dictation.date.formatted(date: .omitted, time: .shortened)
        return String(format: String(localized: "最新 · %@ · %.1f 秒"), time, dictation.audioSeconds)
    }
}

/// Rows down a line, one dot per dictation, newest at the top.
private struct HistoryTimeline: View {
    let rows: [Dictation]
    let mark: Color
    /// Share the height out between the rows instead of stacking them.
    let spread: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { dictation in
                HistoryRow(dictation: dictation, dot: dictation.id == rows.first?.id ? mark : Color.primary.opacity(0.4))
                    .frame(maxHeight: spread ? .infinity : nil, alignment: .top)
            }
        }
        .background(alignment: .leading) {
            Rectangle()
                .fill(Color.primary.opacity(0.1))
                .frame(width: 1.5)
                .padding(.leading, HistoryRow.dotSize / 2 - 0.75)
                .padding(.vertical, 12)
        }
    }
}

private struct HistoryRow: View {
    let dictation: Dictation
    var dot: Color = Color.primary.opacity(0.4)
    static let dotSize: CGFloat = 7
    @State private var showingChanges = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(dictation.text == nil ? Color.red.opacity(0.6) : dot)
                .frame(width: Self.dotSize, height: Self.dotSize)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(dictation.date, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Text(dictation.text ?? dictation.error ?? "")
                    .font(.subheadline)
                    .foregroundStyle(dictation.text == nil ? .secondary : .primary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .contextMenu {
            if let text = dictation.text {
                Button(String(localized: "複製"), systemImage: "doc.on.doc") { UIPasteboard.general.string = text }
            }
            if dictation.transcript != nil {
                Button(String(localized: "改了什麼"), systemImage: "text.redaction") { showingChanges = true }
            }
            if dictation.hasAudio {
                Button(String(localized: "聽原音"), systemImage: "play") { Playback.shared.toggle(dictation.id) }
            }
        }
        .sheet(isPresented: $showingChanges) { ChangesView(dictation: dictation) }
    }
}

/// Plays the recording behind a dictation; a second tap stops it.
struct PlayButton: View {
    let id: UUID
    private var playback: Playback { Playback.shared }

    var body: some View {
        let playing = playback.isPlaying(id)
        Button(playing ? String(localized: "停止") : String(localized: "聽原音"), systemImage: playing ? "stop.fill" : "play.fill") {
            playback.toggle(id)
        }
        .font(.footnote.weight(.medium))
        .buttonStyle(.borderless)
        .tint(.secondary)
        .contentTransition(.symbolEffect(.replace))
    }
}

/// Asks iOS which side the vertical bar is on (nil: the bars are horizontal),
/// instead of guessing from the orientation.
private struct VerticalBarObserver: ViewModifier {
    @Binding var barsAtSide: Bool?

    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            content.modifier(Reader(barsAtSide: $barsAtSide))
        } else {
            content
        }
    }

    @available(iOS 27.1, *)
    private struct Reader: ViewModifier {
        @Environment(\.toolbarVerticalEdge) private var edge
        @Binding var barsAtSide: Bool?

        func body(content: Content) -> some View {
            content.onChange(of: edge, initial: true) { _, edge in barsAtSide = edge != nil }
        }
    }
}

/// Follows the Duo's hinge; nothing to follow before iOS 27.1.
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

/// Editors opened from the home board get their own navigation and a way out.
private struct SheetStack<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content.toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "完成"), systemImage: "checkmark") { dismiss() }
                }
            }
        }
    }
}

/// While Stick reads the latest dictations, and for a moment after: what it learned.
private struct DreamingBadge: View {
    let dreaming: Dreaming

    var body: some View {
        Group {
            if dreaming.isDreaming {
                badge {
                    ProgressView().controlSize(.small)
                    Text(String(localized: "正在從最近的聽寫認識你"))
                }
            } else if let change = dreaming.lastChange {
                badge {
                    Image(systemName: "checkmark")
                    Text(change)
                }
                .task {
                    try? await Task.sleep(for: .seconds(4))
                    dreaming.clearLastChange()
                }
            }
        }
        .animation(.spring(duration: 0.4, bounce: 0), value: dreaming.isDreaming)
        .animation(.spring(duration: 0.4, bounce: 0), value: dreaming.lastChange)
    }

    private func badge(@ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 8) {
            ParrotMark(height: 12)
            content()
        }
        .font(.footnote.weight(.medium))
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .glassEffect(.regular, in: .capsule)
        .padding(.top, 6)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
