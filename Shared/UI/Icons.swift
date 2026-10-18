import SwiftUI

/// Draws a DCO waveform straight from the engine's `ChopShape`, so the icon
/// always shows exactly what the oscillator produces.
struct WaveIcon: View {
    let shape: ChopShape
    /// Phase range across the icon width. Pulse shapes run on the pulse phase
    /// (1 = one cycle); saw / sub shapes on the master phase (0.25 = one cycle).
    var span: Float = 2

    var body: some View {
        Canvas { ctx, size in
            let steps = 96
            var path = Path()
            for i in 0...steps {
                let p = Float(i) / Float(steps) * span
                let v = shape.naive(p.truncatingRemainder(dividingBy: 1))
                let x = CGFloat(i) / CGFloat(steps) * size.width
                let y = size.height * (1 - CGFloat(v))
                if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            ctx.stroke(path, with: .foreground, style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
        }
        .frame(width: 26, height: 14)
        .accessibilityHidden(true)
    }
}

/// 0...3 level bars (sub level, noise level).
struct LevelIcon: View {
    let level: Int

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(1...3, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .frame(width: 4, height: CGFloat(4 + i * 3))
                    .opacity(i <= level ? 1 : 0.25)
            }
        }
        .frame(height: 14)
        .accessibilityHidden(true)
    }
}

/// Envelope mode: normal / inverted, with a velocity wedge for "dynamics".
struct EnvModeIcon: View {
    let inverted: Bool
    let dynamics: Bool
    var gate = false

    var body: some View {
        HStack(spacing: 2) {
            Canvas { ctx, size in
                let w = size.width, h = size.height
                var path = Path()
                if gate {
                    path.move(to: CGPoint(x: 0, y: h))
                    path.addLine(to: CGPoint(x: w * 0.12, y: h))
                    path.addLine(to: CGPoint(x: w * 0.12, y: 1))
                    path.addLine(to: CGPoint(x: w * 0.85, y: 1))
                    path.addLine(to: CGPoint(x: w * 0.85, y: h))
                    path.addLine(to: CGPoint(x: w, y: h))
                } else {
                    func y(_ v: CGFloat) -> CGFloat { inverted ? 1 + v * (h - 2) : h - 1 - v * (h - 2) }
                    path.move(to: CGPoint(x: 0, y: y(0)))
                    path.addLine(to: CGPoint(x: w * 0.2, y: y(1)))
                    path.addLine(to: CGPoint(x: w * 0.45, y: y(0.6)))
                    path.addLine(to: CGPoint(x: w * 0.75, y: y(0.6)))
                    path.addLine(to: CGPoint(x: w, y: y(0)))
                }
                ctx.stroke(path, with: .foreground, style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
            }
            .frame(width: 24, height: 14)
            if dynamics {
                Image(systemName: "hand.tap.fill").font(.system(size: 9, weight: .bold))
            }
        }
        .accessibilityHidden(true)
    }
}

/// HPF position: bass boost / flat / two high-pass settings.
struct HPFIcon: View {
    let mode: Int

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            var path = Path()
            switch mode {
            case 0:     // bass boost
                path.move(to: CGPoint(x: 0, y: h * 0.2))
                path.addCurve(to: CGPoint(x: w * 0.55, y: h * 0.55),
                              control1: CGPoint(x: w * 0.3, y: h * 0.2), control2: CGPoint(x: w * 0.35, y: h * 0.55))
                path.addLine(to: CGPoint(x: w, y: h * 0.55))
            case 1:     // flat
                path.move(to: CGPoint(x: 0, y: h * 0.5))
                path.addLine(to: CGPoint(x: w, y: h * 0.5))
            default:    // high-pass, cutoff further right for 3
                let knee = mode == 2 ? w * 0.35 : w * 0.6
                path.move(to: CGPoint(x: knee - w * 0.25, y: h))
                path.addCurve(to: CGPoint(x: knee + w * 0.15, y: h * 0.3),
                              control1: CGPoint(x: knee, y: h * 0.9), control2: CGPoint(x: knee, y: h * 0.3))
                path.addLine(to: CGPoint(x: w, y: h * 0.3))
            }
            ctx.stroke(path, with: .foreground, style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
        }
        .frame(width: 26, height: 14)
        .accessibilityHidden(true)
    }
}

/// LFO waveform icon (two cycles).
struct LFOIcon: View {
    let shape: Int

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            var path = Path()
            func y(_ v: Float) -> CGFloat { h * 0.5 - CGFloat(v) * (h * 0.5 - 1) }
            switch shape {
            case 5, 6:
                // Sample & hold steps / smooth random curve with fixed "random" values.
                let values: [Float] = [0.2, -0.7, 0.9, -0.2, 0.5, -0.9]
                let step = w / CGFloat(values.count)
                path.move(to: CGPoint(x: 0, y: y(values[0])))
                for (i, v) in values.enumerated() {
                    let x0 = CGFloat(i) * step
                    if shape == 5 {
                        path.addLine(to: CGPoint(x: x0, y: y(v)))
                        path.addLine(to: CGPoint(x: x0 + step, y: y(v)))
                    } else {
                        let prev = i == 0 ? v : values[i - 1]
                        path.addCurve(to: CGPoint(x: x0 + step, y: y(v)),
                                      control1: CGPoint(x: x0 + step * 0.5, y: y(prev)),
                                      control2: CGPoint(x: x0 + step * 0.5, y: y(v)))
                    }
                }
            default:
                let steps = 64
                for i in 0...steps {
                    let p = Float(i) / Float(steps) * 2
                    let v = LFOShape.value(shape, phase: p - floorf(p))
                    let pt = CGPoint(x: CGFloat(i) / CGFloat(steps) * w, y: y(v))
                    if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                }
            }
            ctx.stroke(path, with: .foreground, style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
        }
        .frame(width: 26, height: 14)
        .accessibilityHidden(true)
    }
}

/// Picks the right icon (or text) for one selector cell of a parameter.
struct SelectorCell: View {
    let param: Param
    let index: Int

    var body: some View {
        switch param {
        case .dcoPulse where index > 0:
            WaveIcon(shape: Self.pulseShape(index), span: 2)
        case .dcoSaw where index > 0:
            WaveIcon(shape: Self.sawShape(index), span: 0.5)   // 2 cycles (master phase = 4 cycles)
        case .dcoSub:
            WaveIcon(shape: Self.subShape(index), span: 1)     // shows -1 and -2 oct subs
        case .dcoPulse, .dcoSaw:
            Text("off").font(Theme.pixel(10, .bold))
        case .dcoSubLevel, .dcoNoiseLevel:
            if index == 0 {
                Text("off").font(Theme.pixel(10, .bold))
            } else {
                LevelIcon(level: index)
            }
        case .dcoEnvMode, .vcfEnvMode:
            EnvModeIcon(inverted: index == 1 || index == 3, dynamics: index >= 2)
        case .vcaEnvMode:
            EnvModeIcon(inverted: false, dynamics: index >= 2, gate: index == 1 || index == 3)
        case .hpfCutoff:
            HPFIcon(mode: index)
        case .lfoWave:
            LFOIcon(shape: index)
        case .keyMode:
            VStack(spacing: 1) {
                Image(systemName: ["pianokeys", "music.note.list", "1.circle", "square.stack.3d.up"][min(index, 3)])
                    .font(.system(size: 12, weight: .semibold))
                Text((param.valueStrings?[index] ?? "").lowercased()).font(Theme.pixel(8, .bold))
            }
        case .chorus, .pulseSync, .delaySync, .delayPingPong, .lfoSync, .lfoKeySync,
             .arpOn, .arpHold, .seqOn:
            HStack(spacing: 4) {
                Circle().frame(width: 6, height: 6).opacity(index == 1 ? 1 : 0.3)
                Text(index == 1 ? "on" : "off").font(Theme.pixel(11, .bold))
            }
        default:
            Text((param.valueStrings?[index] ?? "\(index)").lowercased())
                .font(Theme.pixel(11, .bold))
        }
    }

    // Representative shapes (PW 0.3 so PWM-able waves show their gate).
    private static func settings(pulse: Int = 0, saw: Int = 0, sub: Int = 0) -> DCOSettings {
        var s = DCOSettings()
        s.configure(pulse: pulse, saw: saw, sub: sub, pw: 0.3)
        return s
    }
    static func pulseShape(_ i: Int) -> ChopShape { settings(pulse: i).pulse }
    static func sawShape(_ i: Int) -> ChopShape { settings(saw: i).saw }
    static func subShape(_ i: Int) -> ChopShape { settings(sub: i).sub }
}
