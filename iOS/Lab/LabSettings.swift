import Observation
import SwiftUI
import UIKit

/// A colour that survives JSON, for values tuned in the Lab.
struct RGBA: Codable, Equatable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double = 1

    var color: Color { Color(red: r, green: g, blue: b, opacity: a) }
    var uiColor: UIColor { UIColor(red: r, green: g, blue: b, alpha: a) }

    init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    init(_ color: Color) {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        self.init(r: red, g: green, b: blue, a: alpha)
    }
}

/// Everything about how the 3D Stick looks and moves.
struct StickLook: Codable, Equatable {
    var bodyColor = RGBA(r: 0.115, g: 0.12, b: 0.13)
    var coverColor = RGBA(r: 0.135, g: 0.14, b: 0.15)
    /// The real StickS3's key is blue (M5Stack's product photo).
    var buttonColor = RGBA(r: 0.0, g: 0.36, b: 0.92)
    var bodyRoughness = 0.5
    var coverRoughness = 0.34
    var coverClearcoat = 0.55
    var buttonClearcoat = 0.8
    var screenGlow = 1.4

    var environment = 3.4
    var keyLight = 900.0
    var fillLight = 350.0
    var rimLight = 420.0
    var exposure = 0.35

    var cameraPitch = -0.14
    var cameraDistance = 150.0
    var fieldOfView = 24.0
    var restingYaw = -0.5

    var spinTurns = 2.4
    var spinDuration = 1.7
    var idlePeriod = 14.0
    var dragSensitivity = 0.012
    var celebrateTurns = 1.0
    var celebrateDuration = 0.9
    var celebrateScale = 1.08

    /// Pairing stage: the soft floor light under the model.
    var floorShadow = 0.22
    var modelHeight = 300.0
}

/// Page-level look shared by home and pairing.
struct PageLook: Codable, Equatable {
    enum Design: String, Codable, CaseIterable {
        case standard, rounded, serif

        var font: Font.Design {
            switch self {
            case .standard: .default
            case .rounded: .rounded
            case .serif: .serif
            }
        }
    }

    /// Off = the system background, which follows light and dark mode.
    var customBackground = false
    var background = RGBA(r: 0.96, g: 0.95, b: 0.93)
    /// Black-on-light / white-on-dark by default; the Stick's own orange key
    /// is the only colour. Turn off to use `accent`.
    var monochrome = true
    var accent = RGBA(r: 0.2, g: 0.45, b: 0.95)
    var titleSize = 22.0
    /// 0 = ultralight … 8 = black, matching Font.Weight order.
    var titleWeight = 6.0
    var titleDesign = Design.standard
    var latestSize = 22.0
    var latestDesign = Design.serif
    /// The number on a stat tile.
    var statSize = 26.0
    /// The bento board: space between tiles, around the board, inside a tile.
    var gap = 8.0
    var edge = 12.0
    var tilePadding = 14.0
    var tileRadius = 22.0

    /// Concentric with the screen corner where a tile meets it; `tileRadius` elsewhere.
    var tileShape: ConcentricRectangle {
        ConcentricRectangle(corners: .concentric(minimum: .fixed(tileRadius)))
    }
    /// Share of the Duo's inner display the Stick side takes when opened flat.
    /// Half-folded it always ends at the fold.
    var openStickShare = 0.58

    var accentColor: Color { monochrome ? .primary : accent.color }
    /// Orange, for the one live mark on each figure: the hour being spoken
    /// in, the latest wait, the charge. The Stick's screen uses the same.
    var mark: Color { RGBA(r: 0.98, g: 0.36, b: 0.06).color }
    var backgroundColor: Color { customBackground ? background.color : Color(uiColor: .systemGroupedBackground) }
    /// Tiles on the board: white on the grey page, lifted in the dark.
    var tileColor: Color { Color(uiColor: .secondarySystemGroupedBackground) }
    /// Text and icons drawn on top of `accentColor`.
    var onAccent: Color { monochrome ? Color(uiColor: .systemBackground) : .white }

    var weight: Font.Weight {
        let weights: [Font.Weight] = [.ultraLight, .thin, .light, .regular, .medium, .semibold, .bold, .heavy, .black]
        return weights[min(max(Int(titleWeight.rounded()), 0), weights.count - 1)]
    }
}

/// Values tuned in the Lab. Saved on every change and read by the real
/// screens, so what you dial in is what the app shows.
@MainActor
@Observable
final class LabSettings {
    static let shared = LabSettings()

    var model: StickLook { didSet { save() } }
    var page: PageLook { didSet { save() } }

    private static let key = "labSettings"

    private struct Stored: Codable {
        var model: StickLook
        var page: PageLook
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let stored = Self.load(data) {
            model = stored.model
            page = stored.page
            // Saved before the key was corrected from orange to the real blue.
            if model.buttonColor == RGBA(r: 0.98, g: 0.36, b: 0.06) { model.buttonColor = StickLook().buttonColor }
        } else {
            model = StickLook()
            page = PageLook()
        }
    }

    /// Saved values laid over today's defaults, so a setting added in a later
    /// build doesn't make the whole saved set fail to decode and vanish.
    private static func load(_ data: Data) -> Stored? {
        guard let defaults = try? JSONEncoder().encode(Stored(model: StickLook(), page: PageLook())),
              var merged = (try? JSONSerialization.jsonObject(with: defaults)) as? [String: Any],
              let saved = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        for (section, values) in saved {
            guard let values = values as? [String: Any], var current = merged[section] as? [String: Any] else { continue }
            current.merge(values) { _, saved in saved }
            merged[section] = current
        }
        guard let json = try? JSONSerialization.data(withJSONObject: merged) else { return nil }
        return try? JSONDecoder().decode(Stored.self, from: json)
    }

    func reset() {
        model = StickLook()
        page = PageLook()
    }

    /// Pretty JSON of the current values, to paste back so they become the defaults.
    func exportJSON() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(Stored(model: model, page: page)) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(Stored(model: model, page: page)) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
