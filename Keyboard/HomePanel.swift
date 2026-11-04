import SwiftUI

/// The Stick keyboard's home: short, because typing happens on the system
/// keyboard. A waiting result is already in the field by the time this shows;
/// here are the marks and keys for the small fixes after an insert, and the
/// shortcuts. Older results and more marks open as panels.
struct HomePanel: View {
    let model: KeyboardModel

    var body: some View {
        VStack(spacing: 10) {
            marks
                .frame(height: 50)
            bottomRow
                .frame(height: 46)
        }
        .padding(.horizontal, 3)
        .frame(maxHeight: .infinity, alignment: .bottom)
    }

    /// The shortcuts, and what a dictation most often still needs after it lands.
    private var marks: some View {
        HStack(spacing: 8) {
            LastKey(model: model)
            RoundKey(systemImage: "person.text.rectangle", label: String(localized: "我的資訊")) { model.open(.cards) }
            RoundKey(systemImage: "wand.and.sparkles", label: String(localized: "改寫")) { model.open(.refine) }
            RoundKey(text: "，") { model.type("，") }
            RoundKey(text: "。") { model.type("。") }
            // Where the system keyboard has it: the right end of the row above return.
            DeleteKey(model: model)
                .clipShape(Circle())
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: .infinity)
        }
    }

    private var bottomRow: some View {
        GeometryReader { proxy in
            let globe = model.needsGlobe
            let gap: CGFloat = 6
            // Widths in key units; space takes what is left.
            let fixed: [CGFloat] = (globe ? [1.2] : []) + [1.3, 1.3, 1.4]
            let unit = (proxy.size.width - gap * CGFloat(fixed.count)) / (fixed.reduce(0, +) + 4)
            HStack(spacing: gap) {
                if globe {
                    FunctionKey(systemImage: "globe", label: String(localized: "下一個鍵盤"), action: model.nextKeyboard)
                        .frame(width: unit * 1.2)
                }
                FunctionKey(title: "^_^", label: String(localized: "顏文字")) { model.open(.kaomoji) }
                    .frame(width: unit * 1.3)
                SpaceKey(model: model)
                FunctionKey(title: "？！#", label: String(localized: "更多符號")) { model.open(.more) }
                    .frame(width: unit * 1.3)
                FunctionKey(systemImage: "return", label: String(localized: "換行"), action: model.returnKey)
                    .frame(width: unit * 1.4)
            }
        }
    }
}

/// A mark or action in a circle.
struct RoundKey: View {
    var text: String?
    var systemImage: String?
    var label: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 17, weight: .medium))
                        .accessibilityLabel(label ?? "")
                } else {
                    Text(text ?? "").font(.system(size: 20))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(RoundPressStyle())
    }
}

private struct RoundPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .background(KeyFace(pressed: configuration.isPressed).clipShape(Circle()))
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .contentShape(Circle())
            .animation(configuration.isPressed ? nil : .easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// Tap: the last result again. Hold: the older ones.
private struct LastKey: View {
    let model: KeyboardModel
    @State private var pressed = false

    private var latest: SharedInbox.Item? { model.inbox.recent.first }

    var body: some View {
        Image(systemName: "arrow.uturn.backward")
            .font(.system(size: 17, weight: .medium))
            .opacity(latest == nil ? 0.35 : 1)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(KeyFace(pressed: pressed).clipShape(Circle()))
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .contentShape(Circle())
            .gesture(
                LongPressGesture(minimumDuration: 0.35)
                    .onEnded { _ in model.open(.history) }
                    .exclusively(before: TapGesture().onEnded { if let latest { model.insertAgain(latest) } })
            )
            // Only drives the pressed look; runs alongside the tap / hold gesture.
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in pressed = true }
                    .onEnded { _ in pressed = false }
            )
            .accessibilityElement()
            .accessibilityLabel(String(localized: "上一句"))
            .accessibilityHint(String(localized: "按住看更早的結果"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { if let latest { model.insertAgain(latest) } }
            .accessibilityAction(named: String(localized: "更早的結果")) { model.open(.history) }
    }
}

/// One past result. Tapping types it again; the touch handling matches the
/// keys (a Button in the keyboard missed taps).
struct RecentRow: View {
    let item: SharedInbox.Item
    let action: () -> Void

    @State private var pressed = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(item.text)
                .font(.system(size: 16))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(item.date, style: .time)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(pressed ? 0.08 : 0))
        )
        .contentShape(Rectangle())
        // One gesture for both: it highlights on touch, and a release that
        // barely moved is the tap. With a separate onTapGesture beside it,
        // this drag inside the ScrollView swallowed every tap (seen on device).
        // A scroll takes the touch away, so scrolling never types.
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressed = true }
                .onEnded { value in
                    pressed = false
                    if hypot(value.translation.width, value.translation.height) < 10 { action() }
                }
        )
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(String(localized: "再插入一次"))
    }
}
