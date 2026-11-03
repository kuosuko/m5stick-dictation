import SwiftUI

/// Stick's parrot, the same pixels as on the Stick's screen and the app icon.
struct ParrotMark: View {
    var height: CGFloat = 15

    static let color = Color(red: 236 / 255, green: 186 / 255, blue: 64 / 255)
    private static let rows = [
        "......####....",
        ".....######...",
        ".....###.#####",
        ".....######..#",
        "....#######...",
        "...########...",
        "...#######....",
        "..######......",
        ".####.#.#.....",
        "####..........",
    ]

    var body: some View {
        let cell = height / CGFloat(Self.rows.count)
        Canvas { context, _ in
            for (r, row) in Self.rows.enumerated() {
                for (c, ch) in row.enumerated() where ch == "#" {
                    context.fill(Path(CGRect(x: CGFloat(c) * cell, y: CGFloat(r) * cell, width: cell, height: cell)),
                                 with: .color(Self.color))
                }
            }
        }
        .frame(width: cell * CGFloat(Self.rows[0].count), height: height)
        .accessibilityHidden(true)
    }
}
