import SwiftUI
import UIKit

/// Teenage Engineering-inspired look (OP-1 / OP-XY): near-black body, flat
/// surfaces separated by hairlines instead of shadows, white keys for the
/// selected state, small lowercase monospaced type, and the OP-1's four
/// encoder colours (blue, green, white, orange) as the only colour.
enum Theme {
    // Body
    static let background = Color(red: 0.043, green: 0.043, blue: 0.047)     // #0B0B0C
    static let panel = Color(red: 0.086, green: 0.086, blue: 0.094)          // #161618
    static let cell = Color(red: 0.133, green: 0.133, blue: 0.145)           // #222225 key
    static let hairline = Color(red: 0.19, green: 0.19, blue: 0.205)         // #303034
    static let panelEdge = hairline
    static let knobBody = cell

    // Type
    static let label = Color(red: 0.93, green: 0.93, blue: 0.92)             // #EDEDEB
    static let dimLabel = Color(red: 0.54, green: 0.54, blue: 0.57)          // #8A8A91
    /// Text on a lit (white or coloured) key.
    static let ink = Color(red: 0.05, green: 0.05, blue: 0.055)

    // OP-1 encoder colours
    static let blue = Color(red: 0.20, green: 0.47, blue: 1.0)               // #3378FF
    static let green = Color(red: 0.11, green: 0.80, blue: 0.47)             // #1CCC78
    static let white = Color(red: 0.91, green: 0.91, blue: 0.89)             // #E8E8E3
    static let orange = Color(red: 1.0, green: 0.37, blue: 0.13)             // #FF5E21
    static let encoders = [blue, green, white, orange]

    // Roles
    static let accent = orange                  // record, alerts, brand
    static let accentSoft = orange.opacity(0.22)
    static let led = orange
    static let red = orange                     // legacy name: "hot" colour
    static let silver = white
    static let stripes = encoders
    /// Selected keys / tabs: OP-XY white.
    static let selected = white

    // Screen: black OLED with white type and coloured graphics.
    static let display = Color.black
    static let displayText = Color(red: 0.96, green: 0.96, blue: 0.95)
    static let readout = green

    /// Colour of a panel section (title mark and single knobs), following
    /// the signal flow: sources blue, modulation green, filter / drive
    /// orange, envelopes / amp / keys white.
    static func sectionColor(_ title: String) -> Color {
        switch title {
        case "WAVE", "DCO", "PULSE", "DELAY", "SEQ": return blue
        case "LFO", "DCO MOD", "REVERB", "ARP", "PATTERN", "CHORUS": return green
        case "VCF", "HPF", "DIST": return orange
        default: return white
        }
    }

    /// Small monospaced type: the pixel-display feel of compact hardware.
    static func pixel(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// Corner radius for keys; cards use `cardCorner`.
    static let corner: CGFloat = 4
    static let cardCorner: CGFloat = 8
}

private struct SectionTintKey: EnvironmentKey {
    static let defaultValue = Theme.accent
}

private struct KnobSizeKey: EnvironmentKey {
    static let defaultValue: CGFloat = 44
}

private struct EncoderColorKey: EnvironmentKey {
    static let defaultValue: Color? = nil
}

extension EnvironmentValues {
    /// OP-1 encoder colour of a knob in a knob row; nil elsewhere.
    var encoderColor: Color? {
        get { self[EncoderColorKey.self] }
        set { self[EncoderColorKey.self] = newValue }
    }

    /// Knob diameter; the panel scales it with the screen width.
    var knobSize: CGFloat {
        get { self[KnobSizeKey.self] }
        set { self[KnobSizeKey.self] = newValue }
    }

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

/// A labelled panel section ("dco", "vcf", ...): flat card, hairline edge,
/// a coloured mark and a lowercase title followed by a rule, as printed on
/// TE hardware.
struct PanelSection<Content: View>: View {
    let title: String
    var icon: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        let tint = Theme.sectionColor(title)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Circle().fill(tint).frame(width: 6, height: 6)
                Text(title.lowercased())
                    .font(Theme.pixel(11, .medium))
                    .foregroundColor(Theme.label)
                    .lineLimit(1)
                    .fixedSize()
                Rectangle().fill(Theme.hairline).frame(height: 1)
            }
            content
                .environment(\.sectionTint, tint)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 12)
        // Sections share the full row width instead of hugging their content.
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.cardCorner).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardCorner).stroke(Theme.hairline, lineWidth: 1))
    }
}

/// Counts knobs while a knob row's content is built, so each knob gets the
/// OP-1 encoder colour of its position (blue, green, white, orange).
final class EncoderCounter {
    private var index: Int?

    func beginRow() { index = 0 }
    func endRow() { index = nil }

    /// Colour for the next knob in the current row; nil outside a row.
    func next() -> Color? {
        guard let i = index else { return nil }
        index = i + 1
        return Theme.encoders[i % Theme.encoders.count]
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
    /// Fixed diameter; nil follows the panel's `knobSize`.
    var fixedSize: CGFloat? = nil
    var display: ((Float) -> String)? = nil

    @State private var dragStart: Float?
    @Environment(\.sectionTint) private var tint
    @Environment(\.knobSize) private var knobSize
    @Environment(\.encoderColor) private var encoderColor
    private var size: CGFloat { fixedSize ?? knobSize }

    static let ledCount = 13

    private var fraction: Double { Double(value / maxValue) }
    private var valueText: String { display?(value) ?? "\(Int(value.rounded()))" }

    private var color: Color { encoderColor ?? tint }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                // Value arc over a hairline track (270°, gap at the bottom).
                Circle()
                    .trim(from: 0, to: 0.75)
                    .stroke(Theme.hairline, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(135))
                Circle()
                    .trim(from: 0, to: 0.75 * fraction)
                    .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(135))
                // Flat coloured cap with an ink notch, like an OP-1 encoder.
                Circle()
                    .fill(color)
                    .padding(size * 0.17)
                Capsule()
                    .fill(Theme.ink)
                    .frame(width: max(2.5, size * 0.06), height: size * 0.2)
                    .offset(y: -size * 0.19)
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
                        .background(RoundedRectangle(cornerRadius: Theme.corner).fill(color))
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
            .font(Theme.pixel(10, .regular))
            .foregroundColor(Theme.dimLabel)
            .lineLimit(1)
    }

    private var cells: some View {
        HStack(spacing: 4) {
            ForEach(0..<count, id: \.self) { i in
                let selected = Int(value.rounded()) == i
                Button {
                    if !selected { value = Float(i) }
                } label: {
                    cell(i, selected)
                        .foregroundColor(selected ? Theme.ink : Theme.label)
                        // Cells grow to fill the row (capped, so they stay keys).
                        .frame(minWidth: cellWidth, maxWidth: 76, minHeight: 28)
                        .padding(.horizontal, 2)
                        .background(RoundedRectangle(cornerRadius: Theme.corner)
                            .fill(selected ? Theme.selected : Theme.cell))
                        .overlay(alignment: .bottom) {
                            // Section colour as a thin LED line under the lit key.
                            if selected {
                                Rectangle().fill(tint).frame(height: 2)
                                    .clipShape(RoundedRectangle(cornerRadius: 1))
                                    .padding(.horizontal, 5)
                                    .offset(y: 4)
                            }
                        }
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
            Text(options[i].lowercased()).font(Theme.pixel(11, .bold))
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
            ctx.fill(fill, with: .color(Theme.orange.opacity(0.18)))
            ctx.stroke(path, with: .color(Theme.orange), lineWidth: 1.5)
            for k in 1..<4 {
                let gy = 4 + h * CGFloat(k) / 4
                ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: gy)); $0.addLine(to: CGPoint(x: size.width, y: gy)) },
                           with: .color(Theme.hairline.opacity(0.6)), lineWidth: 0.5)
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.display))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.hairline, lineWidth: 1))
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
            .background(RoundedRectangle(cornerRadius: Theme.corner).fill(active ? Theme.selected : Theme.cell))
            .overlay(RoundedRectangle(cornerRadius: Theme.corner).stroke(active ? .clear : Theme.hairline, lineWidth: 1))
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
                .overlay(RoundedRectangle(cornerRadius: Theme.corner).stroke(Theme.hairline, lineWidth: 1))
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
