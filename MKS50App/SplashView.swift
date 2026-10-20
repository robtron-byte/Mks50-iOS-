import SwiftUI

/// Start screen shown for about two seconds when the app opens: the
/// Alpha Juno-2 front panel idea (big alpha dial, backlit 2-line LCD,
/// colour stripes) drawn the Teenage Engineering KO II way: dot grid,
/// square keys, tiny monospaced labels. Tap to skip.
struct SplashView: View {
    let onFinish: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()
    @State private var finished = false

    private var duration: Double { reduceMotion ? 0.9 : 2.3 }

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSince(start)
            GeometryReader { geo in
                let wide = geo.size.width > geo.size.height
                ZStack {
                    Theme.background
                    DotGrid().opacity(0.5)
                    VStack(spacing: wide ? 18 : 28) {
                        header
                        if wide {
                            HStack(spacing: 28) {
                                AlphaDial(t: t, still: reduceMotion).frame(width: 150, height: 150)
                                VStack(alignment: .leading, spacing: 16) {
                                    SplashLCD(t: t, still: reduceMotion)
                                    PadRow(t: t, still: reduceMotion)
                                }
                            }
                        } else {
                            AlphaDial(t: t, still: reduceMotion).frame(width: 170, height: 170)
                            SplashLCD(t: t, still: reduceMotion)
                            PadRow(t: t, still: reduceMotion)
                        }
                        footer
                    }
                    .padding(24)
                    .frame(maxWidth: 640)
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .onChangeCompat(of: t >= duration) { done in
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

    private func finish() {
        guard !finished else { return }
        finished = true
        onFinish()
    }

    private var header: some View {
        HStack(spacing: 10) {
            // Colour stripes, as on the Juno front panels.
            HStack(spacing: 3) {
                ForEach(Theme.stripes.indices, id: \.self) { i in
                    Rectangle().fill(Theme.stripes[i]).frame(width: 14, height: 4)
                }
            }
            Text("MKS50 · 6 VOICE POLYPHONIC SYNTHESIZER")
                .font(Theme.pixel(9, .bold))
                .foregroundColor(Theme.dimLabel)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Spacer(minLength: 0)
        }
    }

    private var footer: some View {
        HStack {
            Text("DCO · HPF · VCF · VCA · CHORUS")
            Spacer(minLength: 8)
            Text("TAP TO START")
                .foregroundColor(Theme.label)
        }
        .font(Theme.pixel(9, .bold))
        .foregroundColor(Theme.dimLabel)
    }
}

/// KO II style dot pattern on the body.
private struct DotGrid: View {
    var body: some View {
        Canvas { ctx, size in
            let step: CGFloat = 14
            var y: CGFloat = step / 2
            while y < size.height {
                var x: CGFloat = step / 2
                while x < size.width {
                    ctx.fill(Path(ellipseIn: CGRect(x: x - 0.75, y: y - 0.75, width: 1.5, height: 1.5)),
                             with: .color(Theme.hairline))
                    x += step
                }
                y += step
            }
        }
    }
}

/// The Alpha Juno's big alpha dial: a knob whose LED ring fills up while
/// the pointer sweeps once, then settles.
private struct AlphaDial: View {
    let t: Double
    let still: Bool

    private static let dots = 24
    /// 0 ... 1: sweep progress (eased).
    private var progress: Double {
        if still { return 1 }
        let x = min(max((t - 0.15) / 1.4, 0), 1)
        return 1 - pow(1 - x, 3)
    }

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let ringRadius = size / 2 - 5
            let lit = Int((progress * Double(AlphaDial.dots)).rounded())
            ZStack {
                ForEach(0..<AlphaDial.dots, id: \.self) { i in
                    let angle = AlphaDial.angle(Double(i) / Double(AlphaDial.dots - 1))
                    Circle()
                        .fill(i < lit ? AlphaDial.colour(i) : Theme.hairline)
                        .frame(width: 5, height: 5)
                        .offset(x: CGFloat(cos(angle)) * ringRadius, y: CGFloat(sin(angle)) * ringRadius)
                }
                Circle()
                    .fill(Theme.cell)
                    .overlay(Circle().stroke(Theme.hairline, lineWidth: 1))
                    .frame(width: size * 0.72, height: size * 0.72)
                // Grip dimples on the dial face.
                ForEach(0..<12, id: \.self) { i in
                    let angle = Double(i) / 12 * 2 * .pi + progress * 4.7
                    Circle()
                        .fill(Theme.panel)
                        .frame(width: size * 0.06, height: size * 0.06)
                        .offset(x: CGFloat(cos(angle)) * size * 0.28, y: CGFloat(sin(angle)) * size * 0.28)
                }
                // Pointer.
                Capsule()
                    .fill(Theme.orange)
                    .frame(width: 4, height: size * 0.18)
                    .offset(y: -size * 0.2)
                    .rotationEffect(.radians(AlphaDial.angle(progress) + .pi / 2))
                Text("α")
                    .font(.system(size: size * 0.2, weight: .bold, design: .rounded))
                    .foregroundColor(Theme.label)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    /// Dial travel from 7 to 5 o'clock (radians, 0 = 3 o'clock).
    static func angle(_ fraction: Double) -> Double {
        let startAngle = 0.75 * Double.pi
        return startAngle + fraction * 1.5 * .pi
    }

    static func colour(_ i: Int) -> Color {
        Theme.encoders[min(i * Theme.encoders.count / dots, Theme.encoders.count - 1)]
    }
}

/// Backlit 2-line LCD: types the name, then the patch line.
private struct SplashLCD: View {
    let t: Double
    let still: Bool

    private static let line1 = "MKS-50  SYNTH"
    private static let line2 = "A11 READY  ♪"

    private func typed(_ text: String, from: Double) -> String {
        if still { return text }
        let count = Int(max(0, (t - from) / 0.045))
        return String(text.prefix(count))
    }

    var body: some View {
        let cursorOn = Int(t * 3) % 2 == 0 && !still
        VStack(alignment: .leading, spacing: 4) {
            Text(typed(SplashLCD.line1, from: 0.25) + (t < 1.0 && cursorOn ? "▌" : ""))
            Text(typed(SplashLCD.line2, from: 1.0) + (t >= 1.0 && cursorOn ? "▌" : ""))
        }
        .font(.system(size: 18, weight: .bold, design: .monospaced))
        .foregroundColor(Theme.readout)
        .frame(width: 220, height: 56, alignment: .leading)
        .padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.display))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.hairline, lineWidth: 1))
    }
}

/// KO II style square keys playing a short electro rhythm.
private struct PadRow: View {
    let t: Double
    let still: Bool

    /// Which key lights on each 16th (electro-funk pattern), -1 = none.
    private static let pattern = [0, -1, 4, 2, -1, 6, 0, 5, -1, 3, 0, -1, 7, 1, 4, -1]

    var body: some View {
        let step = still ? -1 : Int(t / 0.11)
        let active = step >= 0 && step < PadRow.pattern.count ? PadRow.pattern[step] : -1
        HStack(spacing: 6) {
            ForEach(0..<8, id: \.self) { i in
                let lit = i == active
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(lit ? Theme.encoders[i % Theme.encoders.count] : Theme.cell)
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(lit ? .clear : Theme.hairline, lineWidth: 1)
                    Text("\(i + 1)")
                        .font(Theme.pixel(9, .bold))
                        .foregroundColor(lit ? Theme.ink : Theme.dimLabel)
                        .padding(4)
                }
                .frame(width: 26, height: 26)
            }
        }
    }
}
