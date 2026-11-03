import SwiftUI

/// What the illustrated Stick's own screen shows, mirroring the real device.
enum StickScreen: Equatable {
    case off
    case ready
    case listening(levels: [Double])
    case working
    case done
    case problem
}

/// The M5StickS3 rendered from M5Stack's official 3D model (Design/StickRender),
/// with this app's own screen content laid over its glass.
struct StickIllustration: View {
    var screen: StickScreen
    var height: CGFloat = 220


    /// Where the glass sits in `stick-front.png` (orthographic, 26 × 50 mm frame).
    private static let glassCenter = CGPoint(x: 0.5, y: 0.363)
    private static let glassSize = CGSize(width: 0.57, height: 0.5)
    private static let aspect: CGFloat = 780.0 / 1500.0

    /// Loose PNGs in the bundle (not an asset catalog), so load through UIImage.
    static let front = UIImage(named: "stick-front") ?? UIImage()
    static let hero = UIImage(named: "stick-hero") ?? UIImage()

    var body: some View {
        let width = height * Self.aspect
        Image(uiImage: Self.front)
            .resizable()
            .interpolation(.high)
            .frame(width: width, height: height)
            .overlay {
                ScreenContent(screen: screen, size: height * Self.glassSize.height)
                    .frame(width: width * Self.glassSize.width, height: height * Self.glassSize.height)
                    .clipShape(RoundedRectangle(cornerRadius: width * 0.02))
                    .position(x: width * Self.glassCenter.x, y: height * Self.glassCenter.y)
            }
            .background(alignment: .bottom) {
                // Soft contact shadow so it sits on the page instead of floating.
                Ellipse()
                    .fill(Color.black.opacity(0.22))
                    .frame(width: width * 0.78, height: height * 0.045)
                    .blur(radius: height * 0.03)
                    .offset(y: height * 0.01)
            }
            .accessibilityHidden(true)
    }
}

private struct ScreenContent: View {
    let screen: StickScreen
    let size: CGFloat
    @State private var spinning = false

    var body: some View {
        ZStack {
            switch screen {
            case .off:
                Color.clear
            case .ready:
                Image(systemName: "mic.fill")
                    .font(.system(size: size * 0.2, weight: .semibold))
                    .foregroundStyle(.white)
            case .listening(let levels):
                LevelBars(levels: levels, height: size * 0.3)
            case .working:
                Circle()
                    .trim(from: 0, to: 0.28)
                    .stroke(Color.white, style: StrokeStyle(lineWidth: size * 0.035, lineCap: .round))
                    .frame(width: size * 0.26, height: size * 0.26)
                    .rotationEffect(.degrees(spinning ? 360 : 0))
                    .onAppear {
                        withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { spinning = true }
                    }
            case .done:
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.2, weight: .bold))
                    .foregroundStyle(.white)
            case .problem:
                Image(systemName: "exclamationmark")
                    .font(.system(size: size * 0.2, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .transition(.opacity)
        .animation(.easeOut(duration: 0.2), value: screen)
    }
}

/// The real loudness of the last packets the Stick sent, newest on the right.
struct LevelBars: View {
    let levels: [Double]
    let height: CGFloat
    var bars = 9
    var color = Color.white

    var body: some View {
        let recent = Array(levels.suffix(bars))
        let padded = Array(repeating: 0.0, count: max(bars - recent.count, 0)) + recent
        HStack(alignment: .center, spacing: height * 0.09) {
            ForEach(padded.indices, id: \.self) { index in
                Capsule()
                    .fill(color)
                    .frame(width: height * 0.11, height: max(height * 0.1, height * padded[index]))
            }
        }
        .frame(height: height)
        .animation(.spring(duration: 0.18, bounce: 0), value: padded)
    }
}
