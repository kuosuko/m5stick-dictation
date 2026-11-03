import Foundation

enum Kaomoji {
    struct Category: Identifiable {
        let id: String
        let name: String
        let items: [String]
    }

    static let presets: [Category] = [
        Category(id: "happy", name: String(localized: "開心"), items: [
            "(＾▽＾)", "(≧▽≦)", "ヽ(＾Д＾)ﾉ", "(๑˃ᴗ˂)ﻭ", "٩(◕‿◕)۶", "(´▽`)", "(*^▽^*)", "o(≧▽≦)o",
            "(ﾉ◕ヮ◕)ﾉ*:･ﾟ✧", "＼(^o^)／", "(｡◕‿◕｡)", "ᕕ( ᐛ )ᕗ", "(•̀ᴗ•́)و", "(⁎˃ᆺ˂)",
        ]),
        Category(id: "love", name: String(localized: "喜歡"), items: [
            "(♡˙︶˙♡)", "(´∀｀)♡", "(｡♥‿♥｡)", "(づ￣ ³￣)づ", "(っ˘з(˘⌣˘ )", "♡(˃͈ દ ˂͈ ༶ )",
            "(*˘︶˘*).｡.:*♡", "(灬º‿º灬)♡", "( ˘ ³˘)♥", "(๑♡⌓♡๑)", "(◍•ᴗ•◍)❤",
        ]),
        Category(id: "sad", name: String(localized: "難過"), items: [
            "(╥﹏╥)", "(ಥ﹏ಥ)", "(´；ω；`)", "(T_T)", "(；へ：)", "(っ˘̩╭╮˘̩)っ", "( ´•̥̥̥ω•̥̥̥` )",
            "(´°̥̥̥̥̥̥̥̥ω°̥̥̥̥̥̥̥̥｀)", "(｡•́︿•̀｡)", "o(╥﹏╥)o",
        ]),
        Category(id: "angry", name: String(localized: "生氣"), items: [
            "(╬ Ò﹏Ó)", "(╯°□°)╯︵ ┻━┻", "(ノಠ益ಠ)ノ彡┻━┻", "(¬_¬)", "(｀へ´)", "ヽ(`Д´)ﾉ",
            "(#`Д´)", "(ꐦ°᷄д°᷅)", "(￣^￣)", "(・`ω´・)",
        ]),
        Category(id: "meh", name: String(localized: "無奈"), items: [
            "¯\\_(ツ)_/¯", "(ー_ー)!!", "(￣ー￣)", "(´-ω-`)", "(-_-;)", "(._.)", "┐(￣ヘ￣)┌",
            "(；一_一)", "(￣～￣;)", "( ˘･з･)",
        ]),
        Category(id: "surprised", name: String(localized: "驚訝"), items: [
            "(⊙_⊙)", "Σ(ﾟДﾟ)", "(°ロ°)", "(O_O)", "(ﾟoﾟ;)", "w(°ｏ°)w", "(⊙ˍ⊙)", "(ﾟДﾟ;)",
            "(〇o〇;)", "Σ(°△°|||)",
        ]),
        Category(id: "hello", name: String(localized: "打招呼"), items: [
            "(^_^)/", "ヾ(＾∇＾)", "(*・ω・)ﾉ", "(￣▽￣)ノ", "ヾ(・ω・*)", "(｡･ω･)ﾉﾞ", "(・∀・)ノ",
            "m(_ _)m", "(*_ _)人", "(・ω・)b",
        ]),
        Category(id: "animals", name: String(localized: "動物"), items: [
            "ฅ^•ﻌ•^ฅ", "(=^･ω･^=)", "U・ᴥ・U", "(ᵔᴥᵔ)", "ʕ•ᴥ•ʔ", "(・⊝・)", "<(｀^´)>", "(°)#))<<",
            "/(・ × ・)\\", "(=①ω①=)",
        ]),
    ]
}
