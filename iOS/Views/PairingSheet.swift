import SwiftUI

/// The AirPods proximity card, for the Stick. It rises from the bottom of a
/// dimmed screen. On a narrow display it docks just above the bottom edge,
/// corners concentric with the display; on a wide one (the Duo opened) it
/// floats in the middle like the system card. Either way the 連線 button sits
/// in its bottom corners, concentric with the card. On connect the button
/// fades, a circle and check draw in its place, then a battery ring fills. On connect the button closes into a check, then a battery
/// ring fills.
struct PairingCard: View {
    let pairing: StickLink.Pairing
    let batteryLevel: Int?
    let onConnect: () -> Void
    let onClose: () -> Void

    @State private var appeared = false
    @State private var celebrate = 0
    @State private var showRing = false
    @State private var shownBattery = 0
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var lab: LabSettings { LabSettings.shared }

    /// Distance from the display edge to the card, and from the card to the button.
    private static let cardInset: CGFloat = 8
    private static let buttonInset: CGFloat = 14
    /// Corner radius of the floating card, when it is not docked to the display.
    private static let floatingRadius: CGFloat = 46

    private var isFloating: Bool { sizeClass == .regular }

    private var isConnecting: Bool {
        if case .connecting = pairing { return true }
        return false
    }

    private var isConnected: Bool {
        if case .connected = pairing { return true }
        return false
    }

    private var screen: StickModelView.Screen {
        switch pairing {
        case .found: .ready
        case .connecting: .working
        case .connected: .done
        }
    }

    var body: some View {
        ZStack(alignment: isFloating ? .center : .bottom) {
            Color.black.opacity(appeared ? 0.45 : 0)
                .onTapGesture { if !isConnecting { close() } }

            card
                .frame(maxWidth: isFloating ? 420 : 460)
                .padding(.horizontal, Self.cardInset)
                .padding(.bottom, isFloating ? 0 : Self.cardInset)
                .offset(y: appeared ? 0 : 900)
        }
        .ignoresSafeArea()
        .onAppear {
            // A slightly bouncy rise, like the system card coming up from the bottom.
            withAnimation(.spring(duration: 0.6, bounce: 0.2)) { appeared = true }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: isConnecting) { _, connecting in connecting }
        .sensoryFeedback(.success, trigger: isConnected) { _, connected in connected }
        .onChange(of: isConnected, initial: true) { _, connected in
            guard connected else { return }
            celebrate += 1
            Task {
                try? await Task.sleep(for: .milliseconds(1500))
                withAnimation(.spring(duration: 0.5, bounce: 0.15)) { showRing = true }
                countUpBattery()
            }
        }
        .onChange(of: batteryLevel) { countUpBattery() }
    }

    private func close() {
        withAnimation(.spring(duration: 0.4, bounce: 0)) { appeared = false }
        Task {
            try? await Task.sleep(for: .milliseconds(380))
            onClose()
        }
    }

    private var card: some View {
        let page = lab.page
        return VStack(spacing: 0) {
            Text(pairing.name)
                .font(.system(size: page.titleSize + 10, weight: .bold, design: page.titleDesign.font))
                .multilineTextAlignment(.center)
                .padding(.top, 30)
                .padding(.horizontal, 60)

            StickModelView(look: lab.model, screen: screen, celebrate: celebrate)
                .frame(height: lab.model.modelHeight * 0.78)
                .accessibilityHidden(true)

            footer
                .frame(height: 104, alignment: .bottom)
                .padding(.horizontal, Self.buttonInset)
                .padding(.bottom, Self.buttonInset)
        }
        .frame(maxWidth: .infinity)
        .background(
            ConcentricRectangle(corners: .concentric(minimum: .fixed(isFloating ? Self.floatingRadius : 34)), isUniform: true)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
                .shadow(color: .black.opacity(0.22), radius: 28, y: 8)
        )
        // Floating, the card is far from the display corners, so it becomes the
        // container the button's corners follow.
        .modifier(FloatingContainer(isFloating: isFloating, radius: Self.floatingRadius))
        .overlay(alignment: .topTrailing) {
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.primary)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color(uiColor: .tertiarySystemFill)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "關閉"))
            .padding(18)
            .opacity(isConnecting ? 0 : 1)
        }
        .animation(.spring(duration: 0.45, bounce: 0.15), value: pairing)
    }

    @ViewBuilder
    private var footer: some View {
        if !isConnected {
            connectButton
        } else if !showRing {
            // A circle, then a check, drawn in place, so connecting is unmistakable.
            DrawnCheck(color: lab.page.accentColor)
                .frame(width: 64, height: 64)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.bottom, 20)
                .transition(.opacity)
        } else {
            BatteryRing(level: batteryLevel == nil ? nil : shownBattery)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 14)
                .transition(.opacity.combined(with: .offset(y: 8)))
        }
    }

    private var connectButton: some View {
        Button(action: onConnect) {
            ZStack {
                if isConnecting {
                    ProgressView().tint(lab.page.onAccent)
                } else {
                    Text(String(localized: "連線"))
                }
            }
            .font(.headline)
            .foregroundStyle(lab.page.onAccent)
            .frame(maxWidth: .infinity)
            .frame(height: 58)
            .background(
                ConcentricRectangle(corners: .concentric(minimum: .fixed(20)), isUniform: true)
                    .fill(lab.page.accentColor)
            )
            .contentShape(ConcentricRectangle(corners: .concentric(minimum: .fixed(20)), isUniform: true))
        }
        .buttonStyle(PressScale())
        .allowsHitTesting(!isConnecting)
    }

    private func countUpBattery() {
        guard showRing, let batteryLevel else { return }
        withAnimation(.spring(duration: 1.2, bounce: 0)) { shownBattery = batteryLevel }
    }
}

/// Draws its circle, then its check, like the system's "done" mark.
private struct DrawnCheck: View {
    let color: Color
    @State private var circle: CGFloat = 0
    @State private var check: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size.width
            ZStack {
                Circle()
                    .trim(from: 0, to: circle)
                    .stroke(color, style: StrokeStyle(lineWidth: size * 0.065, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Path { path in
                    path.move(to: CGPoint(x: size * 0.29, y: size * 0.52))
                    path.addLine(to: CGPoint(x: size * 0.44, y: size * 0.66))
                    path.addLine(to: CGPoint(x: size * 0.71, y: size * 0.36))
                }
                .trim(from: 0, to: check)
                .stroke(color, style: StrokeStyle(lineWidth: size * 0.08, lineCap: .round, lineJoin: .round))
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.45)) { circle = 1 }
            withAnimation(.easeOut(duration: 0.3).delay(0.4)) { check = 1 }
        }
        .accessibilityLabel(String(localized: "已連線"))
    }
}

private struct FloatingContainer: ViewModifier {
    let isFloating: Bool
    let radius: CGFloat

    func body(content: Content) -> some View {
        if isFloating {
            content.containerShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else {
            content
        }
    }
}

/// Shrinks a touch on press and springs back, so the tap is felt.
private struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(duration: 0.25, bounce: 0.3), value: configuration.isPressed)
    }
}

/// The ring under each AirPod: fills to the level, number underneath.
private struct BatteryRing: View {
    let level: Int?

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.12), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: Double(level ?? 0) / 100)
                    .stroke(tint, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 44, height: 44)

            Text(level.map { "\($0)%" } ?? String(localized: "已連線"))
                .font(.system(size: 22, weight: .semibold))
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(level ?? 0)))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(level.map { String(localized: "電量 \($0)%") } ?? String(localized: "已連線"))
    }

    private var tint: Color {
        guard let level else { return .green }
        return level < 20 ? .red : .green
    }
}

enum BatteryGlyph {
    static func symbol(for level: Int) -> String {
        switch level {
        case ..<13: "battery.0percent"
        case ..<38: "battery.25percent"
        case ..<63: "battery.50percent"
        case ..<88: "battery.75percent"
        default: "battery.100percent"
        }
    }
}
