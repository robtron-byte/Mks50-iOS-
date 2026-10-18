import SwiftUI
import UIKit

/// MKS-50 / Alpha Juno look: dark rack-grey panel, white silk-screen print,
/// Roland red and Roland blue as section colours, light grey switch caps and
/// the yellow-green backlit LCD.
enum Theme {
    static let background = Color(red: 0.07, green: 0.072, blue: 0.078)
    static let panel = Color(red: 0.135, green: 0.14, blue: 0.15)        // rack grey
    static let panelEdge = Color(red: 0.26, green: 0.27, blue: 0.29)
    static let accent = Color(red: 0.86, green: 0.21, blue: 0.17)        // Roland red
    static let accentSoft = Color(red: 0.86, green: 0.21, blue: 0.17).opacity(0.22)
    static let label = Color(red: 0.92, green: 0.93, blue: 0.94)         // white print
    static let dimLabel = Color(red: 0.56, green: 0.58, blue: 0.61)
    static let knobBody = Color(red: 0.19, green: 0.195, blue: 0.21)
    static let cell = Color(red: 0.20, green: 0.205, blue: 0.22)
    static let led = Color(red: 1.0, green: 0.18, blue: 0.12)
    static let display = Color(red: 0.66, green: 0.73, blue: 0.33)       // backlit LCD
    static let displayText = Color(red: 0.08, green: 0.11, blue: 0.04)
    /// Text on a lit (coloured) button.
    static let ink = Color(red: 0.06, green: 0.065, blue: 0.07)

    // Section colours (red / blue print of the Alpha Juno, grey caps).
    static let red = Color(red: 0.86, green: 0.21, blue: 0.17)
    static let blue = Color(red: 0.30, green: 0.60, blue: 0.86)
    static let silver = Color(red: 0.72, green: 0.74, blue: 0.77)
    static let white = Color(red: 0.93, green: 0.94, blue: 0.95)
    static let stripes = [red, blue, silver, white]

    /// Colour of a panel section, following the signal flow.
    static func sectionColor(_ title: String) -> Color {
        switch title {
        case "WAVE", "DCO", "PULSE", "VCF", "HPF": return red
        case "LFO", "DCO MOD", "DELAY", "REVERB", "CHORUS": return blue
        case "KEY", "PERFORM", "VOICES": return silver
        default: return white
        }
    }
}

private struct SectionTintKey: EnvironmentKey {
    static let defaultValue = Theme.accent
}

extension EnvironmentValues {
    /// Colour of the enclosing panel section; knobs and buttons light up in it.
    var sectionTint: Color {
        get { self[SectionTintKey.self] }
        set { self[SectionTintKey.self] = newValue }
    }
}

/// Instant visual feedback on touch-down (the default `.plain` style gives
/// none, which makes buttons feel sluggish).
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .brightness(configuration.isPressed ? 0.12 : 0)
            .animation(.easeOut(duration: 0.06), value: configuration.isPressed)
    }
}

/// A labelled panel section ("DCO", "VCF", ...): flat rounded card with a
/// small coloured dot and title, in the style of compact hardware like OP-XY.
struct PanelSection<Content: View>: View {
    let title: String
    var icon: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        let tint = Theme.sectionColor(title)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(tint).frame(width: 7, height: 7)
                Text(title.lowercased())
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .kerning(0.4)
                    .foregroundColor(Theme.dimLabel)
                    .lineLimit(1)
                    .fixedSize()
            }
            content
                .environment(\.sectionTint, tint)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.panel))
    }
}

/// Rotary encoder with a coloured cap. Drag up/down or left/right to change,
/// double-tap to reset. While dragging, a value bubble shows the exact value.
/// Touch handling is UIKit based: it claims the touch immediately, so the
/// knob wins over a surrounding scroll view also for vertical drags.
struct Knob: View {
    let label: String
    @Binding var value: Float
    var maxValue: Float = 127
    var defaultValue: Float = 0
    var size: CGFloat = 44
    var display: ((Float) -> String)? = nil

    @State private var dragStart: Float?
    @Environment(\.sectionTint) private var tint

    private var fraction: Double { Double(value / maxValue) }
    private var valueText: String { display?(value) ?? "\(Int(value.rounded()))" }

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                Circle()
                    .trim(from: 0, to: 0.75)
                    .stroke(Theme.cell, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(135))
                Circle()
                    .trim(from: 0, to: 0.75 * fraction)
                    .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(135))
                Circle()
                    .fill(tint)
                    .padding(7)
                    .shadow(color: .black.opacity(0.5), radius: 1.5, y: 1)
                Capsule()
                    .fill(Theme.ink)
                    .frame(width: 3, height: size * 0.2)
                    .offset(y: -size * 0.16)
                    .rotationEffect(.degrees(-135 + 270 * fraction))
            }
            .frame(width: size, height: size)
            .overlay {
                KnobTouchSurface(
                    onChanged: { t in
                        if dragStart == nil { dragStart = value }
                        let delta = Float(t.width - t.height) / 160 * maxValue
                        let newValue = min(max((dragStart ?? 0) + delta, 0), maxValue).rounded()
                        if newValue != value { value = newValue }
                    },
                    onEnded: { dragStart = nil },
                    onDoubleTap: { value = defaultValue })
            }
            .overlay(alignment: .top) {
                if dragStart != nil {
                    Text(valueText)
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundColor(Theme.ink)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(tint))
                        .fixedSize()
                        .offset(y: -26)
                        .allowsHitTesting(false)
                }
            }
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityValue(valueText)
            .accessibilityAdjustableAction { dir in
                switch dir {
                case .increment: value = min(maxValue, value + 1)
                case .decrement: value = max(0, value - 1)
                @unknown default: break
                }
            }

            Text(label.lowercased())
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(Theme.label)
                .lineLimit(1)
                .fixedSize()
            Text(valueText)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(Theme.dimLabel)
                .lineLimit(1)
                .fixedSize()
        }
        .frame(minWidth: size + 8)
    }
}

/// Transparent UIKit touch area for knobs. A long-press recogniser with zero
/// delay begins on touch-down, which keeps a parent scroll view from taking
/// over vertical drags.
struct KnobTouchSurface: UIViewRepresentable {
    var onChanged: (CGSize) -> Void
    var onEnded: () -> Void
    var onDoubleTap: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let press = UILongPressGestureRecognizer(target: context.coordinator,
                                                 action: #selector(Coordinator.handle(_:)))
        press.minimumPressDuration = 0
        press.allowableMovement = .greatestFiniteMagnitude
        view.addGestureRecognizer(press)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject {
        var parent: KnobTouchSurface
        private var start: CGPoint = .zero
        private var moved = false
        private var lastTap: CFTimeInterval = 0

        init(parent: KnobTouchSurface) { self.parent = parent }

        @objc func handle(_ g: UILongPressGestureRecognizer) {
            // Window coordinates: independent of any scaling of the panel.
            let p = g.location(in: nil)
            switch g.state {
            case .began:
                start = p
                moved = false
            case .changed:
                let t = CGSize(width: p.x - start.x, height: p.y - start.y)
                if !moved && abs(t.width) < 3 && abs(t.height) < 3 { return }
                moved = true
                parent.onChanged(t)
            case .ended, .cancelled, .failed:
                if moved {
                    parent.onEnded()
                } else if g.state == .ended {
                    let now = CACurrentMediaTime()
                    if now - lastTap < 0.3 {
                        parent.onDoubleTap()
                        lastTap = 0
                    } else {
                        lastTap = now
                    }
                }
                moved = false
            default:
                break
            }
        }
    }
}

/// Row of illuminated buttons for discrete values. Cells can show text or
/// icons (waveforms, envelope modes, ...).
struct StepSelector<Cell: View>: View {
    let label: String
    let count: Int
    @Binding var value: Float
    var cellWidth: CGFloat = 34
    var accessibilityNames: [String] = []
    @ViewBuilder let cell: (_ index: Int, _ selected: Bool) -> Cell
    @Environment(\.sectionTint) private var tint

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.lowercased())
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(Theme.label)
            HStack(spacing: 3) {
                ForEach(0..<count, id: \.self) { i in
                    let selected = Int(value.rounded()) == i
                    Button {
                        if !selected { value = Float(i) }
                    } label: {
                        cell(i, selected)
                            .foregroundColor(selected ? Theme.ink : Theme.label)
                            .frame(minWidth: cellWidth, minHeight: 30)
                            .padding(.horizontal, 3)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(selected ? tint : Theme.cell))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableButtonStyle())
                    .accessibilityLabel(accessibilityNames.indices.contains(i) ? accessibilityNames[i] : "\(i)")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

extension StepSelector where Cell == Text {
    /// Plain text cells.
    init(label: String, options: [String], value: Binding<Float>, cellWidth: CGFloat = 34) {
        self.init(label: label, count: options.count, value: value, cellWidth: cellWidth,
                  accessibilityNames: options) { i, _ in
            Text(options[i]).font(.system(size: 12, weight: .bold, design: .rounded))
        }
    }
}

/// Graph of the 4-segment envelope (LCD style).
struct EnvelopeGraph: View {
    let envelope: EnvelopeSettings

    var body: some View {
        Canvas { ctx, size in
            // Log-ish time axis so short and long segments are both visible.
            func w(_ t: Float) -> CGFloat { CGFloat(log10(1 + t * 1000) / 4.1) }
            let segments = [w(envelope.t1), w(envelope.t2), w(envelope.t3), 0.35, w(envelope.t4)]
            let total = segments.reduce(0, +)
            let scale = size.width / max(total, 0.001)
            let h = size.height - 8
            func y(_ level: Float) -> CGFloat { 4 + h * (1 - CGFloat(level)) }

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
            ctx.fill(fill, with: .color(Theme.displayText.opacity(0.15)))
            ctx.stroke(path, with: .color(Theme.displayText), lineWidth: 2)
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.display))
    }
}

/// Large text button with optional icon, optionally lit (toggle state).
struct BigButton: View {
    let title: String
    var icon: String? = nil
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon { Image(systemName: icon).font(.system(size: 13, weight: .bold)) }
                Text(title).font(.system(size: 12, weight: .bold, design: .rounded)).lineLimit(1)
            }
            .foregroundColor(active ? Theme.ink : Theme.label)
            .padding(.horizontal, 12)
            .frame(minWidth: 64, minHeight: 40)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(active ? Theme.accent : Theme.cell))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
    }
}

/// Square icon button.
struct StepButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(Theme.label)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.cell))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(label)
    }
}

extension View {
    /// `onChange` without deprecation warnings on iOS 17+ that still runs on iOS 16.
    @ViewBuilder
    func onChangeCompat<V: Equatable>(of value: V, perform action: @escaping (V) -> Void) -> some View {
        if #available(iOS 17.0, *) {
            onChange(of: value) { _, newValue in action(newValue) }
        } else {
            onChange(of: value, perform: action)
        }
    }
}
