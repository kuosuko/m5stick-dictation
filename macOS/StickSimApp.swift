import SwiftUI

@main
struct StickSimApp: App {
    @State private var stick = StickPeripheral()

    var body: some Scene {
        WindowGroup("StickSim") {
            StickSimView(stick: stick)
        }
        .windowResizability(.contentSize)
    }
}

struct StickSimView: View {
    let stick: StickPeripheral
    @State private var isHolding = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 20) {
            StickBody(screen: stick.screen, isHolding: isHolding)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in press() }
                        .onEnded { _ in release() }
                )

            Text(stick.isConnected ? "按住空白鍵或機身說話" : "在 iPhone 上打開 App 連線")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(32)
        .frame(width: 320)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(.space, phases: [.down, .up]) { event in
            switch event.phase {
            case .down: press()
            case .up: release()
            default: break
            }
            return .handled
        }
    }

    private func press() {
        guard !isHolding else { return }
        isHolding = true
        Task { await stick.pressButton() }
    }

    private func release() {
        guard isHolding else { return }
        isHolding = false
        stick.releaseButton()
    }
}

/// A rough M5StickS3 front: 48 × 24 mm body, 1.14" 135 × 240 screen.
private struct StickBody: View {
    let screen: StickPeripheral.Screen
    let isHolding: Bool

    private let scale: CGFloat = 1.3

    var body: some View {
        VStack(spacing: 18) {
            StickScreen(screen: screen)
                .frame(width: 135 * scale, height: 240 * scale)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            Capsule()
                .fill(isHolding ? Color.orange : Color.orange.opacity(0.75))
                .frame(width: 64, height: 22)
                .overlay(Capsule().strokeBorder(.black.opacity(0.25)))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 22)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Color(white: 0.16))
                .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
        )
        .scaleEffect(isHolding ? 0.98 : 1)
        .animation(.spring(duration: 0.25, bounce: 0.3), value: isHolding)
    }
}

private struct StickScreen: View {
    let screen: StickPeripheral.Screen

    var body: some View {
        ZStack {
            Color.black
            TimelineView(.periodic(from: .now, by: 0.1)) { context in
                content(now: context.date)
                    .padding(14)
            }
        }
        .foregroundStyle(.white)
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        switch screen {
        case .off:
            label("藍牙未開啟", detail: "到系統設定打開藍牙", tint: .gray)
        case .waiting:
            label("等待連線", detail: StickProtocol.localName, tint: .gray)
        case .ready:
            label("已連線", detail: "按住說話", tint: .green)
        case .recording(let since):
            label(String(format: "%.1f 秒", now.timeIntervalSince(since)), detail: "錄音中", tint: .red)
        case .transcribing:
            label("轉寫中", detail: nil, tint: .orange)
        case .done(let text):
            VStack(alignment: .leading, spacing: 8) {
                Text("已複製")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.green)
                Text(text)
                    .font(.system(size: 15))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        case .failed(let message):
            label("失敗", detail: message, tint: .red)
        case .finding:
            label("在這裡", detail: "按一下就不響了", tint: .orange)
        }
    }

    private func label(_ title: String, detail: String?, tint: Color) -> some View {
        VStack(spacing: 10) {
            Circle().fill(tint).frame(width: 10, height: 10)
            Text(title).font(.system(size: 22, weight: .semibold)).monospacedDigit()
            if let detail {
                Text(detail).font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
            }
        }
    }
}
