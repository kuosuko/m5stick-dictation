import SwiftUI

/// 我的資訊: cards the keyboard can type in one tap.
struct CardsEditor: View {
    @State private var cards = SharedSnippets.read().cards
    @State private var editing: SharedSnippets.Card?

    var body: some View {
        List {
            if cards.isEmpty {
                Text(String(localized: "加入地址、Email、電話這些常打的資料，在鍵盤上按一下就能打出來。"))
                    .foregroundStyle(.secondary)
            }
            ForEach(cards) { card in
                Button { editing = card } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(card.title).font(.headline)
                        Text(card.text)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .tint(.primary)
            }
            .onDelete { cards.remove(atOffsets: $0); save() }
            .onMove { cards.move(fromOffsets: $0, toOffset: $1); save() }
        }
        .navigationTitle(String(localized: "我的資訊"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(String(localized: "新增"), systemImage: "plus") {
                    editing = SharedSnippets.Card(title: "", text: "")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                EditToggle()
            }
        }
        .sheet(item: $editing) { card in
            CardEditor(card: card) { saved in
                if let index = cards.firstIndex(where: { $0.id == saved.id }) {
                    cards[index] = saved
                } else {
                    cards.append(saved)
                }
                save()
            }
        }
    }

    private func save() {
        let current = cards
        SharedSnippets.update { $0.cards = current }
    }
}

private struct CardEditor: View {
    @State var card: SharedSnippets.Card
    let onSave: (SharedSnippets.Card) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                TextField(String(localized: "名稱，例如：住家地址"), text: $card.title)
                TextField(String(localized: "內容"), text: $card.text, axis: .vertical)
                    .lineLimit(3...8)
            }
            .navigationTitle(card.title.isEmpty ? String(localized: "新的資訊") : card.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "取消"), systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "儲存"), systemImage: "checkmark") {
                        onSave(card)
                        dismiss()
                    }
                    .disabled(card.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

/// The user's own kaomoji, shown first in the keyboard's kaomoji panel.
struct KaomojiEditor: View {
    @State private var items = SharedSnippets.read().kaomoji
    @State private var draft = ""

    var body: some View {
        List {
            Section {
                HStack {
                    TextField(String(localized: "貼上或輸入顏文字"), text: $draft)
                        .onSubmit(add)
                    Button(String(localized: "加入"), action: add)
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } footer: {
                Text(String(localized: "加入的顏文字會排在鍵盤顏文字面板的「我的」分類。"))
            }
            Section {
                ForEach(items, id: \.self) { Text($0) }
                    .onDelete { items.remove(atOffsets: $0); save() }
                    .onMove { items.move(fromOffsets: $0, toOffset: $1); save() }
            }
        }
        .navigationTitle(String(localized: "顏文字"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { EditToggle() }
        }
    }

    private func add() {
        let value = draft.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, !items.contains(value) else { return }
        items.insert(value, at: 0)
        draft = ""
        save()
    }

    private func save() {
        let current = items
        SharedSnippets.update { $0.kaomoji = current }
    }
}

/// Edit mode behind an icon: an item with a title only never moves into the
/// Duo's side rail, so it would be left alone up top.
struct EditToggle: View {
    @Environment(\.editMode) private var editMode

    var body: some View {
        let editing = editMode?.wrappedValue.isEditing == true
        Button(editing ? String(localized: "結束編輯") : String(localized: "編輯"), systemImage: editing ? "pencil.slash" : "pencil") {
            withAnimation { editMode?.wrappedValue = editing ? .inactive : .active }
        }
        .contentTransition(.symbolEffect(.replace))
    }
}
