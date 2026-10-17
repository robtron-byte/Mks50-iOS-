import SwiftUI

/// Colours inspired by the black MKS-50 rack front with its orange / white print.
enum Theme {
    static let background = Color(red: 0.08, green: 0.08, blue: 0.09)
    static let panel = Color(red: 0.14, green: 0.14, blue: 0.15)
    static let panelEdge = Color(red: 0.24, green: 0.24, blue: 0.26)
    static let accent = Color(red: 1.0, green: 0.48, blue: 0.10)
    static let label = Color(white: 0.82)
    static let dimLabel = Color(white: 0.55)
    static let knobBody = Color(red: 0.2, green: 0.2, blue: 0.21)
    static let led = Color(red: 1.0, green: 0.18, blue: 0.12)
    static let display = Color(red: 0.05, green: 0.09, blue: 0.06)
    static let displayText = Color(red: 0.55, green: 1.0, blue: 0.55)
}

/// A labelled panel section ("DCO", "VCF", ...).
struct PanelSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .foregroundColor(Theme.accent)
                .padding(.bottom, 1)
                .overlay(Rectangle().fill(Theme.accent).frame(height: 1).offset(y: 2), alignment: .bottom)
            content
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.panelEdge, lineWidth: 1))
    }
}

/// Rotary control. Drag vertically (or horizontally) to change, double-tap to reset.
struct Knob: View {
    let label: String
    @Binding var value: Float
    var maxValue: Float = 127
    var defaultValue: Float = 0
    var size: CGFloat = 40
    var display: ((Float) -> String)? = nil

    @State private var dragStart: Float?

    private var fraction: Double { Double(value / maxValue) }

    var body: some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(Theme.label)
                .lineLimit(1)
                .fixedSize()
            ZStack {
                Circle()
                    .trim(from: 0, to: 0.75)
                    .stroke(Theme.panelEdge, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(135))
                Circle()
                    .trim(from: 0, to: 0.75 * fraction)
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(135))
                Circle()
                    .fill(LinearGradient(colors: [Color(white: 0.32), Theme.knobBody],
                                         startPoint: .top, endPoint: .bottom))
                    .padding(6)
                    .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
                Capsule()
                    .fill(Color.white)
                    .frame(width: 2, height: size * 0.22)
                    .offset(y: -size * 0.22)
                    .rotationEffect(.degrees(-135 + 270 * fraction))
            }
            .frame(width: size, height: size)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { g in
                        if dragStart == nil { dragStart = value }
                        let delta = Float(g.translation.width - g.translation.height) / 160 * maxValue
                        let newValue = min(max((dragStart ?? 0) + delta, 0), maxValue).rounded()
                        if newValue != value { value = newValue }
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .onTapGesture(count: 2) { value = defaultValue }
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityValue(display?(value) ?? "\(Int(value))")
            .accessibilityAdjustableAction { dir in
                switch dir {
                case .increment: value = min(maxValue, value + 1)
                case .decrement: value = max(0, value - 1)
                @unknown default: break
                }
            }

            Text(display?(value) ?? "\(Int(value.rounded()))")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(Theme.dimLabel)
                .lineLimit(1)
                .fixedSize()
        }
        .frame(minWidth: size + 6)
    }
}

/// Row of illuminated buttons for discrete values (waveforms, modes, ...).
struct StepSelector: View {
    let label: String
    let options: [String]
    @Binding var value: Float
    var cellWidth: CGFloat = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(Theme.label)
            HStack(spacing: 2) {
                ForEach(options.indices, id: \.self) { i in
                    let selected = Int(value.rounded()) == i
                    Button {
                        value = Float(i)
                    } label: {
                        Text(options[i])
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundColor(selected ? .black : Theme.label)
                            .frame(minWidth: cellWidth, minHeight: 22)
                            .padding(.horizontal, 2)
                            .background(RoundedRectangle(cornerRadius: 3)
                                .fill(selected ? Theme.accent : Theme.knobBody))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }
}

/// Graph of the 4-segment envelope.
struct EnvelopeGraph: View {
    let envelope: EnvelopeSettings

    var body: some View {
        Canvas { ctx, size in
            // Log-ish time axis so short and long segments are both visible.
            func w(_ t: Float) -> CGFloat { CGFloat(log10(1 + t * 1000) / 4.1) }
            let segments = [w(envelope.t1), w(envelope.t2), w(envelope.t3), 0.35, w(envelope.t4)]
            let total = segments.reduce(0, +)
            let scale = size.width / max(total, 0.001)
            let h = size.height - 4
            func y(_ level: Float) -> CGFloat { 2 + h * (1 - CGFloat(level)) }

            var x: CGFloat = 0
            var path = Path()
            path.move(to: CGPoint(x: 0, y: y(0)))
            x += segments[0] * scale; path.addLine(to: CGPoint(x: x, y: y(envelope.l1)))
            x += segments[1] * scale; path.addLine(to: CGPoint(x: x, y: y(envelope.l2)))
            x += segments[2] * scale; path.addLine(to: CGPoint(x: x, y: y(envelope.l3)))
            x += segments[3] * scale; path.addLine(to: CGPoint(x: x, y: y(envelope.l3)))
            x += segments[4] * scale; path.addLine(to: CGPoint(x: x, y: y(0)))

            var fill = path
            fill.addLine(to: CGPoint(x: 0, y: y(0)))
            ctx.fill(fill, with: .color(Theme.accent.opacity(0.15)))
            ctx.stroke(path, with: .color(Theme.accent), lineWidth: 1.5)
        }
        .background(RoundedRectangle(cornerRadius: 4).fill(Theme.display))
    }
}

/// Spring-loaded or latching vertical strip (pitch bend, modulation).
struct ControlStrip: View {
    let label: String
    /// Bipolar strips (pitch bend) center at 0 and spring back.
    var bipolar = false
    let onChange: (Float) -> Void

    @State private var position: Float = 0

    var body: some View {
        VStack(spacing: 3) {
            GeometryReader { geo in
                let height = geo.size.height
                let normalized = bipolar ? (position + 1) / 2 : position
                ZStack(alignment: .top) {
                    RoundedRectangle(cornerRadius: 5).fill(Theme.knobBody)
                    if bipolar {
                        Rectangle().fill(Theme.panelEdge).frame(height: 1).offset(y: height / 2)
                    }
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Theme.accent)
                        .frame(height: 10)
                        .padding(.horizontal, 3)
                        .offset(y: (1 - CGFloat(normalized)) * (height - 10))
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            let n = Float(1 - min(max(g.location.y / height, 0), 1))
                            position = bipolar ? n * 2 - 1 : n
                            onChange(position)
                        }
                        .onEnded { _ in
                            if bipolar {
                                withAnimation(.easeOut(duration: 0.15)) { position = 0 }
                                onChange(0)
                            }
                        }
                )
            }
            Text(label)
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(Theme.dimLabel)
        }
        .frame(width: 26)
    }
}
