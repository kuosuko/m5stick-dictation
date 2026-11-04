import SwiftUI

/// Rewrites the last sentence the keyboard typed: tap a style, or hold the
/// Stick and say what to change ("shorter", "make it a question").
struct RefinePanel: View {
    let model: KeyboardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let target = model.refineTarget {
                Text(target)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
                FlowRow(spacing: 8) {
                    ForEach(model.refineStyles) { style in
                        Button(style.name) { model.refine(style) }
                            .buttonStyle(PillStyle())
                            .disabled(model.refineState == .working)
                    }
                }
                status
            } else {
                Text(String(localized: "用 Stick 說的話打進來後，可以在這裡改寫"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(24)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.top, 6)
    }

    @ViewBuilder
    private var status: some View {
        HStack(spacing: 8) {
            switch model.refineState {
            case .idle:
                ParrotMark(height: 11)
                Text(String(localized: "或按住 Stick，說你想怎麼改"))
            case .working:
                ProgressView().controlSize(.small)
                Text(String(localized: "改寫中…"))
            case .done:
                Image(systemName: "checkmark")
                Text(String(localized: "已改寫"))
                Spacer(minLength: 0)
                Button(String(localized: "復原"), action: model.undoRefine)
                    .buttonStyle(PillStyle())
            case .failed(let message):
                Image(systemName: "exclamationmark.circle")
                Text(message)
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .frame(minHeight: 34)
    }
}

/// A rounded choice, lit while pressed like the keys.
private struct PillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 16)
            .frame(height: 38)
            .background(KeyFace(pressed: configuration.isPressed).clipShape(Capsule()))
            .contentShape(Capsule())
    }
}

/// Left to right, wrapping.
private struct FlowRow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += lineHeight + spacing; lineHeight = 0 }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: proposal.width ?? widest, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += lineHeight + spacing; lineHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
