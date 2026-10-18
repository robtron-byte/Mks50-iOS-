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

    // Section colours: MKS-50 blue, Roland red, grey caps, white print.
    static let red = Color(red: 0.86, green: 0.21, blue: 0.17)
    static let blue = Color(red: 0.20, green: 0.50, blue: 0.86)          // MKS-50 blue
    static let silver = Color(red: 0.72, green: 0.74, blue: 0.77)
    static let white = Color(red: 0.93, green: 0.94, blue: 0.95)
    static let stripes = [red, blue, silver, white]

    /// Colour of a panel section, following the signal flow.
    static func sectionColor(_ title: String) -> Color {
        switch title {
        case "WAVE", "DCO", "PULSE", "LFO", "DCO MOD", "DELAY", "REVERB", "CHORUS", "ARP", "SEQ", "PATTERN": return blue
        case "VCF", "HPF": return red
        case "KEY", "PERFORM", "VOICES": return silver
        default: return white
        }
    }

    /// Small monospaced type: the pixel-display feel of compact hardware.
    static func pixel(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// Corner radius for cells, keys and cards: nearly square, pixel-like.
    static let corner: CGFloat = 3
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
                Rectangle().fill(tint).frame(width: 6, height: 6)
                Text(title.lowercased())
                    .font(Theme.pixel(11, .bold))
                    .foregroundColor(Theme.dimLabel)
                    .lineLimit(1)
                    .fixedSize()
            }
            content
                .environment(\.sectionTint, tint)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: Theme.corner + 1).fill(Theme.panel))
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

    static let ledCount = 13

    private var fraction: Double { Double(value / maxValue) }
    private var valueText: String { display?(value) ?? "\(Int(value.rounded()))" }

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                // Pixel LED ring: 13 square dots over 270°.
                ForEach(0..<Knob.ledCount, id: \.self) { i in
                    let lit = Double(i) <= fraction * Double(Knob.ledCount - 1) + 0.001 && fraction > 0
                    Rectangle()
                        .fill(lit ? tint : Theme.cell)
                        .frame(width: 3, height: 3)
                        .offset(y: -size / 2 + 1.5)
                        .rotationEffect(.degrees(-135 + 270 * Double(i) / Double(Knob.ledCount - 1)))
                }
                Circle()
                    .fill(tint)
                    .padding(8)
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
                        .font(Theme.pixel(14, .bold))
                        .foregroundColor(Theme.ink)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: Theme.corner).fill(tint))
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
                .font(Theme.pixel(10))
                .foregroundColor(Theme.label)
                .lineLimit(1)
                .fixedSize()
            Text(valueText)
                .font(Theme.pixel(10, .regular))
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
    /// Every tap without movement (step buttons); nil for knobs.
    var onTap: (() -> Void)? = nil

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
            // The knob's own coordinates: always match what is on screen
            // (window coordinates can be mirrored or rotated in landscape).
            let p = g.location(in: g.view)
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
                } else if g.state == .ended, let onTap = parent.onTap {
                    onTap()
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
    var cellWidth: CGFloat = 30
    var accessibilityNames: [String] = []
    /// Label left of the cells instead of above (saves height).
    var inline = false
    @ViewBuilder let cell: (_ index: Int, _ selected: Bool) -> Cell
    @Environment(\.sectionTint) private var tint

    var body: some View {
        Group {
            if inline {
                HStack(spacing: 8) {
                    title.frame(width: 52, alignment: .leading)
                    cells
                }
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    title
                    cells
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    private var title: some View {
        Text(label.lowercased())
            .font(Theme.pixel(10))
            .foregroundColor(Theme.label)
            .lineLimit(1)
    }

    private var cells: some View {
        HStack(spacing: 3) {
            ForEach(0..<count, id: \.self) { i in
                let selected = Int(value.rounded()) == i
                Button {
                    if !selected { value = Float(i) }
                } label: {
                    cell(i, selected)
                        .foregroundColor(selected ? Theme.ink : Theme.label)
                        .frame(minWidth: cellWidth, minHeight: 28)
                        .padding(.horizontal, 2)
                        .background(RoundedRectangle(cornerRadius: Theme.corner)
                            .fill(selected ? tint : Theme.cell))
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityLabel(accessibilityNames.indices.contains(i) ? accessibilityNames[i] : "\(i)")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

extension StepSelector where Cell == Text {
    /// Plain text cells.
    init(label: String, options: [String], value: Binding<Float>, cellWidth: CGFloat = 30,
         inline: Bool = false) {
        self.init(label: label, count: options.count, value: value, cellWidth: cellWidth,
                  accessibilityNames: options, inline: inline) { i, _ in
            Text(options[i]).font(Theme.pixel(11, .bold))
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
                Text(title.lowercased()).font(Theme.pixel(12, .bold)).lineLimit(1)
            }
            .foregroundColor(active ? Theme.ink : Theme.label)
            .padding(.horizontal, 12)
            .frame(minWidth: 64, minHeight: 40)
            .background(RoundedRectangle(cornerRadius: Theme.corner).fill(active ? Theme.blue : Theme.cell))
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
                .background(RoundedRectangle(cornerRadius: Theme.corner).fill(Theme.cell))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(label)
    }
}

/// Touch-down / touch-up area for the play pad, UIKit based like the knobs:
/// it reacts on the first touch without delay, also near the screen edges
/// and inside scroll views.
struct PressSurface: UIViewRepresentable {
    var onDown: () -> Void
    var onUp: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> TouchView {
        let view = TouchView()
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ view: TouchView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator {
        var parent: PressSurface
        init(parent: PressSurface) { self.parent = parent }
    }

    /// Raw touches instead of a gesture recognizer: touchesBegan arrives as
    /// soon as the finger lands, without waiting for gesture arbitration.
    final class TouchView: UIView {
        weak var coordinator: Coordinator?
        private var touching = 0

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            if touching == 0 { coordinator?.parent.onDown() }
            touching += touches.count
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { lift(touches.count) }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { lift(touches.count) }

        private func lift(_ count: Int) {
            guard touching > 0 else { return }
            touching = max(0, touching - count)
            if touching == 0 { coordinator?.parent.onUp() }
        }
    }
}

/// True for an iPhone held upright (narrow width, tall height).
struct PortraitReader {
    static func isPortrait(_ h: UserInterfaceSizeClass?, _ v: UserInterfaceSizeClass?) -> Bool {
        h == .compact && v == .regular
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
