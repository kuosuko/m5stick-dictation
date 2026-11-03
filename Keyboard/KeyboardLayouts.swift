import Foundation

enum InputLanguage {
    case zhuyin
    case english
}

enum KeyLayer {
    case letters
    case numbers
    case symbols
}

/// One character key: what it shows and what it sends.
struct CharKey: Identifiable, Hashable {
    let label: String
    /// For Zhuyin keys, McBopomofo's standard-layout ASCII key; otherwise the text to insert.
    let output: String
    var id: String { label + output }

    init(_ label: String, _ output: String? = nil) {
        self.label = label
        self.output = output ?? label
    }
}

enum KeyboardLayouts {
    /// 標準（大千）排列, mapped to the keys McBopomofo's StandardLayout expects.
    static let zhuyin: [[CharKey]] = [
        [("ㄅ", "1"), ("ㄉ", "2"), ("ˇ", "3"), ("ˋ", "4"), ("ㄓ", "5"), ("ˊ", "6"), ("˙", "7"), ("ㄚ", "8"), ("ㄞ", "9"), ("ㄢ", "0"), ("ㄦ", "-")],
        [("ㄆ", "q"), ("ㄊ", "w"), ("ㄍ", "e"), ("ㄐ", "r"), ("ㄔ", "t"), ("ㄗ", "y"), ("ㄧ", "u"), ("ㄛ", "i"), ("ㄟ", "o"), ("ㄣ", "p")],
        [("ㄇ", "a"), ("ㄋ", "s"), ("ㄎ", "d"), ("ㄑ", "f"), ("ㄕ", "g"), ("ㄘ", "h"), ("ㄨ", "j"), ("ㄜ", "k"), ("ㄠ", "l"), ("ㄤ", ";")],
        [("ㄈ", "z"), ("ㄌ", "x"), ("ㄏ", "c"), ("ㄒ", "v"), ("ㄖ", "b"), ("ㄙ", "n"), ("ㄩ", "m"), ("ㄝ", ","), ("ㄡ", "."), ("ㄥ", "/")],
    ].map { $0.map { CharKey($0.0, $0.1) } }

    static let english: [[CharKey]] = [
        "qwertyuiop", "asdfghjkl", "zxcvbnm",
    ].map { $0.map { CharKey(String($0)) } }

    static func numbers(for language: InputLanguage) -> [[CharKey]] {
        switch language {
        case .english:
            return keys(["1234567890", "-/:;()$&@\"", ".,?!'"])
        case .zhuyin:
            return keys(["1234567890", "，。、；：「」（）～", "？！…—『』"])
        }
    }

    static func symbols(for language: InputLanguage) -> [[CharKey]] {
        switch language {
        case .english:
            return keys(["[]{}#%^*+=", "_\\|~<>€£¥•", ".,?!'"])
        case .zhuyin:
            return keys(["【】《》〈〉＃％＊＋", "＿＼｜～＜＞＄＆＠・", "？！…—『』"])
        }
    }

    private static func keys(_ rows: [String]) -> [[CharKey]] {
        rows.map { $0.map { CharKey(String($0)) } }
    }
}
