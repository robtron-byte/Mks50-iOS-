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
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .heavy, design: .rounded))
                .foregroundColor(Theme.accent)
                .padding(.bottom, 1)
                .overlay(Rectangle().fill(Theme.accent).frame(height: 1).offset(y: 2), alignment: .bottom)
            content
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.panelEdge, lineWidth: 1))
    }
}

/// Rotary control. Drag vertically (or horizontally) to change, double-tap to reset.
struct Knob: View {
    let label: String
    @Binding var value: Float
    var maxValue: Float = 127
    var defaultValue: Float = 0
    var size: CGFloat = 50
    var display: ((Float) -> String)? = nil

    @State private var dragStart: Float?

    private var fraction: Double { Double(value / maxValue) }

    var body: some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Theme.label)
                .lineLimit(1)
                .fixedSize()
            ZStack {
                Circle()
                    .trim(from: 0, to: 0.75)
                    .stroke(Theme.panelEdge, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(135))
                Circle()
                    .trim(from: 0, to: 0.75 * fraction)
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
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
            // High priority so the knob wins over the page's scroll view.
            .highPriorityGesture(
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
                .font(.system(size: 11, weight: .medium, design: .monospaced))
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
    var cellWidth: CGFloat = 34

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Theme.label)
            HStack(spacing: 3) {
                ForEach(options.indices, id: \.self) { i in
                    let selected = Int(value.rounded()) == i
                    Button {
                        value = Float(i)
                    } label: {
                        Text(options[i])
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundColor(selected ? .black : Theme.label)
                            .frame(minWidth: cellWidth, minHeight: 32)
                            .padding(.horizontal, 3)
                            .background(RoundedRectangle(cornerRadius: 5)
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

/// Large text button, optionally lit (toggle state).
struct BigButton: View {
    let title: String
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundColor(active ? .black : Theme.label)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(minWidth: 72, minHeight: 44)
                .background(RoundedRectangle(cornerRadius: 8).fill(active ? Theme.accent : Theme.knobBody))
        }
        .buttonStyle(.plain)
    }
}

/// Square icon button (≥ 44 pt touch target).
struct StepButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(Theme.label)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.knobBody))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
