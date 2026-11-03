import SwiftUI

/// Whisper's transcript against the polished text, so a wrong "fix" can be
/// caught, and the original copied instead.
struct ChangesView: View {
    let dictation: Dictation
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    private var page: PageLook { LabSettings.shared.page }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let transcript = dictation.transcript, let text = dictation.text {
                        let segments = TextDiff.segments(from: transcript, to: text)
                        Text(TextDiff.attributed(segments, mark: page.mark))
                            .font(.system(size: page.latestSize * 1.3, design: page.latestDesign.font))
                            .lineSpacing(page.latestSize * 0.4)
                            .textSelection(.enabled)
                        Text(String(localized: "劃掉的是 Whisper 聽到、整理時拿掉的；橘色是加上的。改了 \(TextDiff.changeCount(segments)) 處。"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(String(localized: "Whisper 聽到的"))
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(.secondary)
                            Text(transcript)
                                .font(.system(size: page.latestSize, design: page.latestDesign.font))
                                .textSelection(.enabled)
                            HStack(spacing: 16) {
                                if dictation.hasAudio { PlayButton(id: dictation.id) }
                                Button(copied ? String(localized: "已複製") : String(localized: "複製這個"), systemImage: copied ? "checkmark" : "doc.on.doc") {
                                    UIPasteboard.general.string = transcript
                                    copied = true
                                }
                                .font(.footnote.weight(.medium))
                                .buttonStyle(.borderless)
                                .tint(page.mark)
                                .contentTransition(.symbolEffect(.replace))
                            }
                        }
                        .padding(page.tilePadding)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(page.tileColor, in: RoundedRectangle(cornerRadius: page.tileRadius, style: .continuous))
                    } else {
                        Text(String(localized: "這一句沒有整理過，打進去的就是 Whisper 聽到的。"))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(page.backgroundColor)
            .navigationTitle(String(localized: "改了什麼"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "完成"), systemImage: "checkmark") { dismiss() }
                }
            }
        }
    }
}
