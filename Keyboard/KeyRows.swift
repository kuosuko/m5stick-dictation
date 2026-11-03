import Foundation

/// A key and how much room it takes, in key-width units.
enum KeyItem: Identifiable {
    /// A nil width shares whatever the row has left with the other stretching keys.
    case character(CharKey, width: Double? = 1)
    /// Types its text as is, never through the Zhuyin engine: the number
    /// row, and the ， beside space. Swiping up types `alternate`.
    case literal(CharKey, alternate: String? = nil, width: Double? = nil)
    case shift(width: Double)
    case delete(width: Double)
    /// 123 ⇄ #+= inside the number layers.
    case layerSwitch(width: Double)
    /// letters ⇄ numbers, on the bottom row.
    case layerToggle(width: Double)
    case language(width: Double)
    case globe(width: Double)
    case space(String)
    case returnKey(width: Double)
    /// Opens the kaomoji panel, on the number pages.
    case kaomoji(width: Double)
    /// Opens the 我的資訊 cards, between space and return.
    case cards(width: Double)
    case flex(String)

    var id: String {
        switch self {
        case .character(let key, _): "c" + key.id
        case .literal(let key, _, _): "t" + key.id
        case .shift: "shift"
        case .delete: "delete"
        case .layerSwitch: "layerSwitch"
        case .layerToggle: "layerToggle"
        case .language: "language"
        case .globe: "globe"
        case .space(let tag): "space" + tag
        case .returnKey: "return"
        case .kaomoji: "kaomoji"
        case .cards: "cards"
        case .flex(let tag): "flex" + tag
        }
    }

    /// nil for items that stretch to fill the row.
    var width: Double? {
        switch self {
        case .character(_, let width), .literal(_, _, let width):
            width
        case .shift(let width), .delete(let width), .layerSwitch(let width), .layerToggle(let width),
             .language(let width), .globe(let width), .returnKey(let width), .kaomoji(let width), .cards(let width):
            width
        case .space, .flex:
            nil
        }
    }
}

/// A row split where the split keyboard divides it; joined when not split.
struct KeyRow: Identifiable {
    let id: Int
    let left: [KeyItem]
    let right: [KeyItem]
    /// Height relative to a full row.
    var scale: Double = 1

    var all: [KeyItem] { left + right }
}

extension KeyboardLayouts {
    /// Key columns a full row is laid out against, whole and per half.
    static func columns(language: InputLanguage, layer: KeyLayer) -> (whole: Double, half: Double) {
        language == .zhuyin && layer == .letters ? (11, 6) : (10, 5)
    }

    /// A shorter row of digits above the letters, so numbers need no page switch.
    static let numberRowScale = 0.8

    static func rows(language: InputLanguage, layer: KeyLayer) -> [KeyRow] {
        switch (layer, language) {
        case (.letters, .zhuyin):
            let rows = zhuyin
            return [
                numberRow,
                halves(0, rows[0], at: 6),
                halves(1, rows[1], at: 5),
                halves(2, rows[2], at: 5),
                KeyRow(id: 3, left: chars(rows[3].prefix(5)), right: chars(rows[3].dropFirst(5)) + [.delete(width: 1)]),
            ]
        case (.letters, .english):
            let rows = english
            return [
                numberRow,
                halves(0, rows[0], at: 5),
                halves(1, rows[1], at: 5),
                KeyRow(
                    id: 2,
                    left: [.shift(width: 1.35), .flex("l")] + chars(rows[2].prefix(5)),
                    right: chars(rows[2].dropFirst(5)) + [.flex("r"), .delete(width: 1.35)]
                ),
            ]
        case (.numbers, _), (.symbols, _):
            let rows = layer == .numbers ? numbers(for: language) : symbols(for: language)
            let last = rows[2]
            let split = (last.count + 1) / 2
            // Punctuation stretches to share what is left, so six Chinese marks
            // plus the kaomoji key fit as well as five English ones.
            // The top row sits where the number row is on the letters page, at the same height.
            let top = halves(0, rows[0], at: 5)
            return [
                KeyRow(id: top.id, left: top.left, right: top.right, scale: numberRowScale),
                halves(1, rows[1], at: 5),
                KeyRow(
                    id: 2,
                    left: [.layerSwitch(width: 1.3), .kaomoji(width: 1.3)] + chars(last.prefix(split), width: nil),
                    right: chars(last.dropFirst(split), width: nil) + [.delete(width: 1.3)]
                ),
            ]
        }
    }

    /// The split version gets a space bar on each side, like the system split keyboard.
    /// Zhuyin letters get a ， beside space (swipe up for 。), so a sentence
    /// doesn't need the 123 page.
    static func bottomRow(showsGlobe: Bool, split: Bool, chinesePunctuation: Bool) -> KeyRow {
        let left: [KeyItem] = [.layerToggle(width: 1.5), .language(width: 1.5)] + (showsGlobe ? [.globe(width: 1.2)] : [])
        let comma: [KeyItem] = chinesePunctuation ? [.literal(CharKey("，"), alternate: "。", width: 1)] : []
        let right: [KeyItem] = comma + [.cards(width: 1.2), .returnKey(width: 2)]
        if split {
            return KeyRow(id: 99, left: left + [.space("l")], right: [.space("r")] + right)
        }
        return KeyRow(id: 99, left: left + [.space("")], right: right)
    }

    private static var numberRow: KeyRow {
        let digits = "1234567890".map { KeyItem.literal(CharKey(String($0))) }
        return KeyRow(id: 10, left: Array(digits.prefix(5)), right: Array(digits.dropFirst(5)), scale: numberRowScale)
    }

    private static func halves(_ id: Int, _ keys: [CharKey], at index: Int) -> KeyRow {
        KeyRow(id: id, left: chars(keys.prefix(index)), right: chars(keys.dropFirst(index)))
    }

    private static func chars<S: Sequence>(_ keys: S, width: Double? = 1) -> [KeyItem] where S.Element == CharKey {
        keys.map { .character($0, width: width) }
    }
}
