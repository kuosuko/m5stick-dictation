import SwiftUI
import UIKit

/// Walk around with this open: the disc grows as the stick gets closer, the
/// phone taps faster, and a connected stick can be made to chirp.
struct FindStickView: View {
    let link: StickLink
    /// Simulator only: a wandering signal stands in for Bluetooth.
    var demo = false
    @Environment(\.dismiss) private var dismiss
    @State private var fakeSignal: Double?
    @State private var fakeRSSI: Int?
    @State private var fakeSounding = false

    private var page: PageLook { LabSettings.shared.page }
    private var signal: Double? { demo ? fakeSignal : link.signal }
    private var rssi: Int? { demo ? fakeRSSI : link.rssi }
    private var connected: Bool { demo || link.status == .connected }
    private var sounding: Bool { demo ? fakeSounding : link.isSounding }
    /// Haptics restart when the reading crosses into another band.
    private var band: Int { signal.map { Int($0 * 6) } ?? -1 }

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                // Room for the words and the button under the rings, on the
                // inner display held sideways too.
                let side = min(proxy.size.width * 0.74, proxy.size.height - 250)
                VStack(spacing: 0) {
                    Spacer()
                    Field(signal: signal, connected: connected, size: side)
                    Spacer()
                    VStack(alignment: .leading, spacing: 8) {
                        // The word and the raw reading side by side: the
                        // number moves on every sample, the word only on a band.
                        HStack(alignment: .firstTextBaseline) {
                            Text(reading.title)
                                .font(.system(size: 30, weight: .semibold, design: page.titleDesign.font))
                                .contentTransition(.opacity)
                            Spacer()
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text(rssi.map(String.init) ?? "—")
                                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                                    .monospacedDigit()
                                    .contentTransition(.numericText(value: Double(rssi ?? 0)))
                                Text("dBm")
                                    .font(.footnote.weight(.medium))
                                    .foregroundStyle(.secondary)
                            }
                            .foregroundStyle(rssi == nil ? .secondary : .primary)
                            .animation(.spring(duration: 0.35, bounce: 0), value: rssi)
                        }
                        Text(reading.detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(width: side)
                    .animation(.spring(duration: 0.3, bounce: 0), value: reading.title)
                    .padding(.bottom, 32)
                    soundButton
                        .padding(.bottom, 24)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(page.backgroundColor)
            .navigationTitle(String(localized: "尋找 Stick"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "完成"), systemImage: "checkmark") { dismiss() }
                }
            }
        }
        .onAppear { if !demo { link.startFinding() } }
        .onDisappear { if !demo { link.stopFinding() } }
        .task(id: band) { await tap() }
        .task { if demo { await wander() } }
    }

    private var soundButton: some View {
        VStack(spacing: 10) {
            Button(sounding ? String(localized: "停止聲音") : String(localized: "播放聲音"), systemImage: sounding ? "speaker.slash.fill" : "speaker.wave.2.fill") {
                if demo { fakeSounding.toggle() } else { link.setSound(!sounding) }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(page.mark)
            .disabled(!connected)
            if !connected {
                Text(String(localized: "連上後才能讓它響"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var reading: (title: String, detail: String) {
        guard let signal else {
            return connected
                ? (String(localized: "正在聽"), String(localized: "帶著手機走動看看。"))
                : (String(localized: "聽不到"), String(localized: "Stick 可能關機了，或不在附近。帶著手機到別的房間試試。"))
        }
        switch signal {
        case ..<0.25: return (String(localized: "很遠"), String(localized: "朝一個方向走，Stick 往中間靠就對了。"))
        case ..<0.5: return (String(localized: "有點距離"), String(localized: "大概在隔壁房間的距離。"))
        case ..<0.8: return (String(localized: "靠近了"), String(localized: "幾步之內，翻翻附近。"))
        default: return (String(localized: "就在這裡"), String(localized: "伸手就拿得到。"))
        }
    }

    /// Taps faster the closer the stick is, like Find My does.
    private func tap() async {
        guard signal != nil else { return }
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.prepare()
        while !Task.isCancelled {
            let strength = signal ?? 0
            generator.impactOccurred(intensity: 0.4 + 0.6 * strength)
            try? await Task.sleep(for: .seconds(1.2 - strength))
        }
    }

    private func wander() async {
        let start = Date.now
        while !Task.isCancelled {
            let t = Date.now.timeIntervalSince(start)
            fakeSignal = 0.5 + 0.45 * sin(t / 2.5)
            fakeRSSI = Int(-95 + fakeSignal! * 50 + Double.random(in: -2...2))
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}

/// Four distance rings around the phone, one per word below, and the Stick
/// itself on the ring it is heard at; it slides inward as you get closer.
/// Nothing heard: it waits outside the rings, dimmed.
private struct Field: View {
    let signal: Double?
    /// A connected stick is awake, so its screen is lit.
    let connected: Bool
    let size: CGFloat

    private static let stickHeight: CGFloat = 54

    var body: some View {
        ZStack {
            ForEach(1...4, id: \.self) { ring in
                Circle()
                    .strokeBorder(Color.primary.opacity(ring == 4 ? 0.14 : 0.08), lineWidth: 1)
                    .frame(width: size * CGFloat(ring) / 4, height: size * CGFloat(ring) / 4)
            }
            Circle()
                .fill(Color.primary)
                .frame(width: 7, height: 7)
            StickIllustration(screen: connected ? .ready : .off, height: Self.stickHeight)
                .opacity(signal == nil ? 0.35 : 1)
                .offset(y: -distance)
        }
        .frame(width: size, height: size + Self.stickHeight)
        .animation(.spring(duration: 0.6, bounce: 0), value: distance)
        .animation(.spring(duration: 0.3, bounce: 0), value: signal == nil)
        .accessibilityLabel(signal.map { String(localized: "訊號 \(Int($0 * 100))%") } ?? String(localized: "聽不到"))
    }

    /// Outer ring at no signal, a short step from the centre at full.
    private var distance: CGFloat {
        guard let signal else { return size / 2 + Self.stickHeight * 0.6 }
        return size / 2 * (1 - CGFloat(signal) * 0.82)
    }
}
