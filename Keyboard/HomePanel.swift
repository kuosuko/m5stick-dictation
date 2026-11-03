import SwiftUI

/// The Stick keyboard. Typing happens on the system keyboard; this one is
/// for Stick results. A waiting result is already in the field by the time
/// this shows; here are the shortcuts as big buttons, the recent results to
/// insert again, and keys for the small fixes after an insert.
struct HomePanel: View {
    let model: KeyboardModel

    var body: some View {
        VStack(spacing: 9) {
            shortcuts
                .frame(height: 64)
            recent
                .frame(maxHeight: .infinity)
            bottomRow
                .frame(height: 46)
        }
        .padding(.horizontal, 3)
    }

    private var shortcuts: some View {
        HStack(spacing: 6) {
            ShortcutButton(systemImage: "arrow.uturn.backward", title: String(localized: "上一句"),
                           disabled: model.inbox.recent.isEmpty) {
                if let latest = model.inbox.recent.first { model.insertAgain(latest) }
            }
            ShortcutButton(systemImage: "person.text.rectangle", title: String(localized: "我的資訊")) { model.open(.cards) }
            ShortcutButton(text: "^_^", title: String(localized: "顏文字")) { model.open(.kaomoji) }
        }
    }

    @ViewBuilder
    private var recent: some View {
        if model.inbox.recent.isEmpty {
            VStack(spacing: 10) {
                ParrotMark(height: 22)
                Text(String(localized: "用 Stick 說的話會出現在這裡"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(model.inbox.recent.prefix(12)) { item in
                        RecentRow(item: item) { model.insertAgain(item) }
                        if item.id != model.inbox.recent.prefix(12).last?.id {
                            Divider().padding(.leading, 12)
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    private var bottomRow: some View {
        GeometryReader { proxy in
            let globe = model.needsGlobe
            let gap: CGFloat = 6
            // Widths in key units; space takes what is left.
            let fixed: [CGFloat] = (globe ? [1.2] : []) + [1.3, 1.9]
            let unit = (proxy.size.width - gap * CGFloat(fixed.count)) / (fixed.reduce(0, +) + 4)
            HStack(spacing: gap) {
                if globe {
                    FunctionKey(systemImage: "globe", label: String(localized: "下一個鍵盤"), action: model.nextKeyboard)
                        .frame(width: unit * 1.2)
                }
                SpaceKey(model: model)
                DeleteKey(model: model)
                    .frame(width: unit * 1.3)
                FunctionKey(systemImage: "return", label: String(localized: "換行"), action: model.returnKey)
                    .frame(width: unit * 1.9)
            }
        }
    }
}

/// A shortcut big enough to hit without looking: a symbol over its name.
private struct ShortcutButton: View {
    var systemImage: String?
    var text: String?
    let title: String
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Group {
                    if let systemImage {
                        Image(systemName: systemImage).font(.system(size: 19, weight: .medium))
                    } else {
                        Text(text ?? "").font(.system(size: 16, weight: .medium))
                    }
                }
                .frame(height: 22)
                Text(title).font(.system(size: 12))
            }
            .opacity(disabled ? 0.35 : 1)
        }
        .buttonStyle(PressStyle())
        .disabled(disabled)
    }
}

/// One past result. Tapping types it again; the touch handling matches the
/// keys (a Button in the keyboard missed taps).
private struct RecentRow: View {
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
