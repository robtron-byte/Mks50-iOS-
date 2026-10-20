import SwiftUI

/// Start screen shown for under two seconds when the app opens: the alpha
/// dial of the Alpha Juno-2 reduced to an LED ring and a pointer, with the
/// name below, Teenage Engineering style. Everything sits in one 144 pt
/// column on an 8 pt grid. Tap to skip.
struct SplashView: View {
    let onFinish: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()
    @State private var finished = false

    /// Grid unit and column width (18 units).
    private static let unit: CGFloat = 8
    private static let column: CGFloat = 18 * unit

    private var duration: Double { reduceMotion ? 0.8 : 1.8 }

    var body: some View {
        TimelineView(.animation) { context in
            let elapsed = context.date.timeIntervalSince(start)
            let t = reduceMotion ? 10 : elapsed       // reduce motion: final state
            VStack(alignment: .leading, spacing: 0) {
                AlphaRing(progress: ease((t - 0.1) / 0.9))
                    .frame(width: SplashView.column, height: SplashView.column)
                Spacer().frame(height: 4 * SplashView.unit)
                stripes(ease((t - 0.7) / 0.4))
                Spacer().frame(height: 2 * SplashView.unit)
                Text("MKS50")
                    .font(.system(size: 4 * SplashView.unit, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.label)
                    .frame(height: 5 * SplashView.unit, alignment: .leading)
                    .opacity(ease((t - 0.8) / 0.4))
                Text("POLYPHONIC SYNTHESIZER")
                    .font(Theme.pixel(9, .bold))
                    .foregroundColor(Theme.dimLabel)
                    .frame(height: 2 * SplashView.unit, alignment: .leading)
                    .opacity(ease((t - 0.95) / 0.4))
            }
            .frame(width: SplashView.column, alignment: .leading)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background)
            .onChangeCompat(of: elapsed >= duration) { done in
                if done { finish() }
            }
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { finish() }
        .accessibilityElement()
        .accessibilityLabel("MKS50 Synth")
        .accessibilityHint("Tap to start")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { finish() }
    }

    /// Four colour bars spanning the column (4 × 30 pt + 3 × 8 pt gaps).
    private func stripes(_ progress: Double) -> some View {
        HStack(spacing: SplashView.unit) {
            ForEach(Theme.stripes.indices, id: \.self) { i in
                Rectangle()
                    .fill(Theme.stripes[i])
                    .frame(width: (SplashView.column - 3 * SplashView.unit) / 4, height: SplashView.unit / 2)
                    .opacity(min(max(progress * 4 - Double(i), 0), 1))
            }
        }
    }

    private func ease(_ x: Double) -> Double {
        let c = min(max(x, 0), 1)
        return 1 - pow(1 - c, 3)
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        onFinish()
    }
}

/// The alpha dial: 16 LED dots on a 7-to-5 o'clock arc that light up
/// as the pointer sweeps once.
private struct AlphaRing: View {
    let progress: Double

    private static let dots = 16

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let radius = size / 2 - 4
            let lit = Int((progress * Double(AlphaRing.dots)).rounded())
            ZStack {
                ForEach(0..<AlphaRing.dots, id: \.self) { i in
                    let angle = AlphaRing.angle(Double(i) / Double(AlphaRing.dots - 1))
                    Circle()
                        .fill(i < lit ? Theme.label : Theme.hairline)
                        .frame(width: 6, height: 6)
                        .offset(x: CGFloat(cos(angle)) * radius, y: CGFloat(sin(angle)) * radius)
                }
                Circle()
                    .stroke(Theme.hairline, lineWidth: 1)
                    .frame(width: size * 2 / 3, height: size * 2 / 3)
                Capsule()
                    .fill(Theme.orange)
                    .frame(width: 4, height: size / 6)
                    .offset(y: -size / 6)
                    .rotationEffect(.radians(AlphaRing.angle(progress) + .pi / 2))
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    /// Dial travel from 7 to 5 o'clock (radians, 0 = 3 o'clock).
    static func angle(_ fraction: Double) -> Double {
        0.75 * .pi + fraction * 1.5 * .pi
    }
}
