import SwiftUI

/// Pages of the panel. Fewer, larger controls per page instead of one long
/// strip of tiny knobs.
enum PanelPage: String, CaseIterable, Identifiable {
    case osc = "OSC"
    case mod = "MOD"
    case filter = "FILTER"
    case env = "ENV"
    case amp = "AMP"
    case fx = "FX"
    case arp = "ARP"
    case seq = "SEQ"
    case patch = "PATCH"
    case extra = "EXTRA"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .osc: return "waveform"
        case .mod: return "waveform.path.ecg"
        case .filter: return "line.3.horizontal.decrease"
        case .env: return "chart.xyaxis.line"
        case .amp: return "speaker.wave.2.fill"
        case .fx: return "sparkles"
        case .arp: return "arrow.up.arrow.down"
        case .seq: return "square.grid.4x3.fill"
        case .patch: return "pianokeys"
        case .extra: return "plus.square.on.square"
        }
    }
}

// MARK: - Parameter-bound controls (each observes only its own parameter)

struct ParamKnob: View {
    @ObservedObject var param: ParamModel
    let model: SynthViewModel
    var label: String? = nil

    var body: some View {
        let p = param.param
        let display: ((Float) -> String)? = (p.isDiscrete || p == .pulseDetune || p == .tempo || p == .delayTime || p == .delayFeedback || p == .lfoRate || p == .hpfFreq)
            ? { value in p.string(for: value) } : nil
        Knob(label: label ?? p.shortName,
             value: model.binding(p),
             maxValue: Float(p.maxValue),
             defaultValue: Float(p.defaultValue),
             display: display)
            .modifier(CCLearnOverlay(learn: model.learn, model: model, param: p))
    }
}

struct ParamSelector: View {
    @ObservedObject var param: ParamModel
    let model: SynthViewModel
    var label: String? = nil
    var inline = false

    var body: some View {
        let p = param.param
        StepSelector(label: label ?? p.shortName,
                     count: p.maxValue + 1,
                     value: model.binding(p),
                     accessibilityNames: p.valueStrings ?? [],
                     inline: inline) { i, _ in
            SelectorCell(param: p, index: i)
        }
        .modifier(CCLearnOverlay(learn: model.learn, model: model, param: p))
    }
}

/// Envelope graph that redraws only when one of the 7 envelope values changes.
struct LiveEnvelopeGraph: View {
    @ObservedObject var t1: ParamModel
    @ObservedObject var l1: ParamModel
    @ObservedObject var t2: ParamModel
    @ObservedObject var l2: ParamModel
    @ObservedObject var t3: ParamModel
    @ObservedObject var l3: ParamModel
    @ObservedObject var t4: ParamModel

    init(model: SynthViewModel) {
        t1 = model.model(.envT1); l1 = model.model(.envL1)
        t2 = model.model(.envT2); l2 = model.model(.envL2)
        t3 = model.model(.envT3); l3 = model.model(.envL3)
        t4 = model.model(.envT4)
    }

    var body: some View {
        EnvelopeGraph(envelope: EnvelopeSettings(
            t1: SynthEngine.envelopeTime(t1.value), l1: l1.value / 127,
            t2: SynthEngine.envelopeTime(t2.value), l2: l2.value / 127,
            t3: SynthEngine.envelopeTime(t3.value), l3: l3.value / 127,
            t4: SynthEngine.envelopeTime(t4.value)))
    }
}

/// Chord memory readout + learn button.
struct ChordReadout: View {
    @ObservedObject var chordIndex: ParamModel
    @ObservedObject var model: SynthViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.chordDescription(Int(chordIndex.value.rounded())))
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundColor(Theme.displayText)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 4).fill(Theme.display))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.hairline, lineWidth: 1))
            BigButton(title: "LEARN CHORD", icon: "music.note.list") { model.learnChord() }
        }
    }
}

/// LFO rate, or the note value when the LFO is tempo-synced.
struct LFORateControl: View {
    @ObservedObject var sync: ParamModel
    let model: SynthViewModel

    var body: some View {
        if sync.value >= 0.5 {
            ParamKnob(param: model.model(.lfoDivision), model: model)
        } else {
            ParamKnob(param: model.model(.lfoRate), model: model)
        }
    }
}

/// Free delay time, or the note value when the delay is tempo-synced.
struct DelayTimeControl: View {
    @ObservedObject var sync: ParamModel
    let model: SynthViewModel

    var body: some View {
        if sync.value >= 0.5 {
            ParamKnob(param: model.model(.delayDivision), model: model)
        } else {
            ParamKnob(param: model.model(.delayTime), model: model)
        }
    }
}

// MARK: - Panel

/// All MKS-50 tone and patch parameters, one page at a time. Does not observe
/// the view model itself, so pad presses and status messages never redraw it.
struct SynthPanelView: View {
    let model: SynthViewModel
    @AppStorage("panelPage") private var pageRaw = PanelPage.osc.rawValue

    @State private var width: CGFloat = 390
    private let encoders = EncoderCounter()

    private var page: PanelPage { PanelPage(rawValue: pageRaw) ?? .osc }

    /// Knobs grow with the screen: 40 pt on small phones, ~50 pt on Pro Max
    /// widths, capped on iPad / landscape.
    private var knobSize: CGFloat { min(max((width - 28) / 8, 40), 54).rounded() }
    private var knobSpacing: CGFloat { (knobSize * 0.36).rounded() }

    var body: some View {
        VStack(spacing: 0) {
            pageTabs
            // Scrolls only when a page does not fit. Knobs claim their touch
            // on touch-down (UIKit), so vertical knob drags never scroll.
            ViewThatFits(in: .vertical) {
                paddedPage
                ScrollView(.vertical, showsIndicators: false) { paddedPage }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .environment(\.knobSize, knobSize)
        .background(GeometryReader { geo in
            Color.clear
                .onAppear { width = geo.size.width }
                .onChangeCompat(of: geo.size.width) { width = $0 }
        })
    }

    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(\.verticalSizeClass) private var vSize

    @ViewBuilder private var pageTabs: some View {
        if PortraitReader.isPortrait(hSize, vSize) {
            // Two rows of five on an upright iPhone.
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 5), spacing: 4) {
                tabButtons
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
        } else {
            HStack(spacing: 4) { tabButtons }
                .padding(.horizontal, 14)
                .padding(.top, 6)
        }
    }

    private var tabButtons: some View {
            ForEach(PanelPage.allCases) { p in
                let selected = p == page
                Button {
                    if !selected { pageRaw = p.rawValue }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: p.icon).font(.system(size: 11, weight: .semibold))
                        Text(p.rawValue.lowercased())
                            .font(Theme.pixel(11, .bold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundColor(selected ? Theme.ink : Theme.dimLabel)
                    .frame(maxWidth: .infinity, minHeight: 30)
                    .background(RoundedRectangle(cornerRadius: Theme.corner).fill(selected ? Theme.selected : Theme.panel))
                    .overlay(RoundedRectangle(cornerRadius: Theme.corner).stroke(selected ? .clear : Theme.hairline, lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityLabel(p.rawValue)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
    }

    private var paddedPage: some View {
        pageContent
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
    }

    @ViewBuilder private var pageContent: some View {
        switch page {
        case .osc: oscPage
        case .mod: modPage
        case .filter: filterPage
        case .env: envPage
        case .amp: ampPage
        case .fx: fxPage
        case .arp: arpPage
        case .seq: SequencerPage(model: model)
        case .patch: patchPage
        case .extra: extraPage
        }
    }

    // MARK: Helpers

    /// A knob; inside a knob row it takes its OP-1 colour and an equal
    /// share of the row width (no gap at the right edge).
    private func knob(_ p: Param, _ label: String? = nil) -> some View {
        encoderSlot(ParamKnob(param: model.model(p), model: model, label: label))
    }

    private func encoderSlot<V: View>(_ view: V) -> some View {
        let color = encoders.next()
        return view
            .environment(\.encoderColor, color)
            .frame(maxWidth: color != nil ? .infinity : nil)
    }

    private func selector(_ p: Param, _ label: String? = nil, inline: Bool = false) -> ParamSelector {
        ParamSelector(param: model.model(p), model: model, label: label, inline: inline)
    }

    private func group<Content: View>(_ title: String, _ icon: String,
                                      @ViewBuilder _ content: () -> Content) -> some View {
        PanelSection(title: title, icon: icon, content: content)
    }

    /// Sections flow into lines: as many side by side as fit the width,
    /// each line stretched to the full width (never cut off at the edge).
    private func row<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        SectionFlow(spacing: 10) { content() }
    }

    /// One row of knobs with even spacing, coloured like OP-1 encoders.
    /// The content is built right here, in order, so `knob()` can count.
    private func knobs<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        encoders.beginRow()
        let c = content()
        encoders.endRow()
        return HStack(alignment: .top, spacing: knobSpacing) { c }
    }

    /// Knob row on top, switches below – the same order on every page.
    private func stack<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) { content() }
    }

    // MARK: Pages

    private var oscPage: some View {
        row {
            group("WAVE", "waveform") {
                VStack(alignment: .leading, spacing: 6) {
                    selector(.dcoPulse, inline: true)
                    selector(.dcoSaw, inline: true)
                    selector(.dcoSub, inline: true)
                    selector(.dcoSubLevel, inline: true)
                }
            }
            group("DCO", "dial.medium") {
                stack {
                    knobs {
                        knob(.dcoPwDepth)
                        knob(.dcoPwmRate)
                    }
                    selector(.dcoRange, inline: true)
                    selector(.dcoNoiseLevel, inline: true)
                }
            }
        }
    }

    private var modPage: some View {
        row {
            group("LFO", "wave.3.right") {
                stack {
                    knobs {
                        encoderSlot(LFORateControl(sync: model.model(.lfoSync), model: model))
                        knob(.lfoDelay)
                        selector(.lfoSync, "SYNC")
                        selector(.lfoKeySync)
                    }
                    selector(.lfoWave)
                }
            }
            group("DCO MOD", "waveform.path.ecg") {
                stack {
                    knobs {
                        knob(.dcoLfoDepth)
                        knob(.dcoEnvDepth)
                        knob(.dcoAfterDepth)
                    }
                    selector(.dcoEnvMode)
                }
            }
        }
    }

    private var filterPage: some View {
        row {
            group("VCF", "line.3.horizontal.decrease") {
                stack {
                    knobs {
                        knob(.vcfCutoff)
                        knob(.vcfResonance)
                        knob(.vcfEnvDepth)
                        knob(.vcfKeyFollow)
                    }
                    HStack(alignment: .bottom, spacing: 16) {
                        selector(.vcfEnvMode)
                        knob(.vcfLfoDepth)
                        knob(.vcfAfterDepth)
                    }
                }
            }
            group("HPF", "line.3.horizontal.decrease.circle") {
                HStack(alignment: .bottom, spacing: 16) {
                    knob(.hpfFreq, "FREQ")
                    selector(.hpfCutoff, "STEP")
                }
            }
        }
    }

    private var envPage: some View {
        group("ENVELOPE", "chart.xyaxis.line") {
            let graph = stack {
                LiveEnvelopeGraph(model: model)
                    .frame(minWidth: 200, maxWidth: .infinity, minHeight: 110, maxHeight: 110)
                selector(.envRetrigger)
            }
            let controls = stack {
                knobs {
                    knob(.envT1)
                    knob(.envT2)
                    knob(.envT3)
                    knob(.envT4)
                }
                knobs {
                    knob(.envL1)
                    knob(.envL2)
                    knob(.envL3)
                    knob(.envKeyFollow)
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 18) { graph; controls }
                VStack(alignment: .leading, spacing: 12) { graph; controls }
            }
        }
    }

    private var ampPage: some View {
        group("VCA", "speaker.wave.2.fill") {
            stack {
                knobs {
                    knob(.vcaLevel)
                    knob(.vcaAfterDepth)
                    knob(.volume)
                }
                selector(.vcaEnvMode)
            }
        }
    }

    private var fxPage: some View {
        row {
            group("DIST", "bolt.fill") {
                stack {
                    knobs {
                        knob(.distDrive)
                        knob(.distTone)
                        knob(.distLevel)
                        knob(.distMix)
                    }
                    selector(.distMode, inline: true)
                }
            }
            group("DELAY", "repeat") {
                stack {
                    knobs {
                        knob(.delayMix)
                        encoderSlot(DelayTimeControl(sync: model.model(.delaySync), model: model))
                        knob(.delayFeedback)
                        knob(.delayTone)
                    }
                    HStack(alignment: .bottom, spacing: 14) {
                        selector(.delaySync, "SYNC")
                        selector(.delayPingPong)
                        knob(.tempo)
                    }
                }
            }
            group("REVERB", "building.columns") {
                stack {
                    knobs {
                        knob(.reverbMix)
                        knob(.reverbSize)
                    }
                    knob(.reverbDamp)
                }
            }
            group("CHORUS", "circle.hexagongrid") {
                stack {
                    knob(.chorusRate)
                    selector(.chorus, "ON")
                }
            }
        }
    }

    private var arpPage: some View {
        group("ARP", "arrow.up.arrow.down") {
            stack {
                knobs {
                    selector(.arpOn, "ARP")
                    knob(.arpRate)
                    knob(.arpGate)
                    selector(.arpHold)
                }
                selector(.arpMode, inline: true)
                selector(.arpOctaves, inline: true)
            }
        }
    }

    private var patchPage: some View {
        row {
            group("KEY", "pianokeys") {
                stack {
                    selector(.keyMode)
                    HStack(alignment: .top, spacing: 14) {
                        knob(.chordIndex, "CHORD")
                        ChordReadout(chordIndex: model.model(.chordIndex), model: model)
                    }
                }
            }
            group("PERFORM", "hand.point.up.left.fill") {
                stack {
                    knobs {
                        knob(.portaTime)
                        knob(.benderRange)
                        knob(.modSensitivity)
                        knob(.keyShift)
                    }
                    selector(.portaSwitch, "PORTAMENTO")
                }
            }
        }
    }

    private var extraPage: some View {
        row {
            group("PULSE", "square.split.diagonal") {
                stack {
                    knobs {
                        knob(.pulseDetune)
                        knob(.pulseEnvMod)
                    }
                    selector(.pulseSync, "PULSE SYNC")
                }
            }
            group("VOICES", "person.3.fill") {
                stack {
                    knobs {
                        knob(.voiceDrift)
                        knob(.unisonDetune)
                    }
                    Text("unison: patch › key › unison")
                        .font(Theme.pixel(10, .regular))
                        .foregroundColor(Theme.dimLabel)
                }
            }
        }
    }
}

// MARK: - Play button

/// Large single "play" pad with an assignable MIDI note.
struct PlayBar: View {
    @ObservedObject var model: SynthViewModel
    /// Finger on the pad (a cancelled touch – Control Center, calls – also
    /// ends it, so the pad can never get stuck).
    @State private var pressing = false
    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(\.verticalSizeClass) private var vSize

    var body: some View {
        Group {
            if PortraitReader.isPortrait(hSize, vSize) {
                portraitBody
            } else {
                landscapeBody
            }
        }
        // The pad sits at the bottom edge: without this, iOS holds touches
        // there back until it has ruled out the home swipe.
        .defersSystemGestures(on: .bottom)
    }

    /// Upright iPhone: note selection on the left (left hand), the play
    /// pad on the right (right hand), switches below.
    private var portraitBody: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                noteSelector(stacked: true)
                pad.frame(minHeight: 86)
            }
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                BigButton(title: model.isLearningPadNote ? "KEY…" : "LEARN",
                          icon: "pianokeys", active: model.isLearningPadNote) { model.toggleLearnPadNote() }
                BigButton(title: "HOLD", icon: model.padLatch ? "lock.fill" : "lock.open",
                          active: model.padLatch) { model.padLatch.toggle() }
                ParamToggle(param: model.model(.arpOn), model: model, title: "ARP", icon: "arrow.up.arrow.down")
                ParamToggle(param: model.model(.seqOn), model: model, title: "SEQ", icon: "square.grid.4x3.fill")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Theme.background)
    }

    /// Landscape: switches and note selection on the left, pad on the right.
    private var landscapeBody: some View {
        HStack(spacing: 10) {
            BigButton(title: model.isLearningPadNote ? "PLAY A KEY…" : "LEARN",
                      icon: "pianokeys", active: model.isLearningPadNote) { model.toggleLearnPadNote() }
            BigButton(title: "HOLD", icon: model.padLatch ? "lock.fill" : "lock.open",
                      active: model.padLatch) { model.padLatch.toggle() }
            ParamToggle(param: model.model(.arpOn), model: model, title: "ARP", icon: "arrow.up.arrow.down")
            ParamToggle(param: model.model(.seqOn), model: model, title: "SEQ", icon: "square.grid.4x3.fill")
            noteSelector(stacked: false)
            pad
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Theme.background)
    }

    /// Note readout (black screen) with octave / semitone steppers: stacked
    /// above them in portrait, beside them in landscape.
    @ViewBuilder private func noteSelector(stacked: Bool) -> some View {
        let readout = Text(model.padNoteName.lowercased())
            .font(Theme.pixel(18, .bold))
            .foregroundColor(Theme.displayText)
            .frame(minWidth: 64, maxWidth: .infinity, minHeight: 36)
            .background(RoundedRectangle(cornerRadius: Theme.corner).fill(Theme.display))
            .overlay(RoundedRectangle(cornerRadius: Theme.corner).stroke(Theme.hairline, lineWidth: 1))
            .accessibilityLabel("Pad note \(model.padNoteName)")
        let steppers = HStack(spacing: 6) {
            StepButton(symbol: "chevron.left.2", label: "Octave down") { model.transposePad(-12) }
            StepButton(symbol: "chevron.left", label: "Semitone down") { model.transposePad(-1) }
            StepButton(symbol: "chevron.right", label: "Semitone up") { model.transposePad(1) }
            StepButton(symbol: "chevron.right.2", label: "Octave up") { model.transposePad(12) }
        }
        if stacked {
            VStack(spacing: 6) { readout; steppers }
                .fixedSize(horizontal: true, vertical: false)
        } else {
            HStack(spacing: 6) { readout.fixedSize(); steppers }
        }
    }

    private var pad: some View {
        let lit = model.padSounding || pressing
        return HStack(spacing: 8) {
            Rectangle()
                .fill(lit ? Theme.ink : Theme.orange)
                .frame(width: 8, height: 8)
            Text(model.padLatch ? (model.padSounding ? "tap to stop" : "tap to hold") : "play")
                .font(Theme.pixel(14, .bold))
        }
        .foregroundColor(lit ? Theme.ink : Theme.label)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Flat key, lit MKS-50 blue while playing.
        .background(RoundedRectangle(cornerRadius: Theme.corner + 1).fill(lit ? Theme.selected : Theme.cell))
        .overlay(RoundedRectangle(cornerRadius: Theme.corner + 1).stroke(lit ? .clear : Theme.hairline, lineWidth: 1))
        .overlay {
            PressSurface(onDown: {
                pressing = true
                model.padTouchDown()
            }, onUp: {
                pressing = false
                model.padTouchUp()
            })
        }
        .onDisappear { model.padTouchUp() }
        .accessibilityElement()
        .accessibilityLabel("Play \(model.padNoteName)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            model.padTouchDown()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { model.padTouchUp() }
        }
    }
}

/// Quick on/off switch (ARP, SEQ) next to the play pad.
struct ParamToggle: View {
    @ObservedObject var param: ParamModel
    let model: SynthViewModel
    let title: String
    let icon: String

    var body: some View {
        let on = param.value >= 0.5
        BigButton(title: title, icon: icon, active: on) {
            model.set(param.param, on ? 0 : 1)
        }
        .accessibilityValue(on ? "On" : "Off")
    }
}

// MARK: - CC learn

/// In CC-learn mode: covers a control, shows its CC and arms it on tap.
struct CCLearnOverlay: ViewModifier {
    @ObservedObject var learn: CCLearnState
    let model: SynthViewModel
    let param: Param

    func body(content: Content) -> some View {
        content.overlay {
            if learn.active {
                let armed = learn.target == param
                let cc = learn.map[param.rawValue]
                let badge: String = cc.map { "CC \($0)" } ?? "–"
                let spoken: String = param.displayName + ", " + (cc.map { "MIDI CC \($0)" } ?? "no MIDI CC")
                ZStack(alignment: .topTrailing) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(armed ? Theme.accent.opacity(0.3) : Color.black.opacity(0.35))
                        .overlay(RoundedRectangle(cornerRadius: 8)
                            .stroke(armed ? Theme.accent : (cc != nil ? Theme.display : Theme.panelEdge),
                                    lineWidth: armed ? 2.5 : 1))
                    Text(verbatim: badge)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(Theme.displayText)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(cc != nil ? Theme.display : Theme.dimLabel))
                        .offset(x: 4, y: -7)
                }
                .padding(-2)
                .contentShape(Rectangle())
                .onTapGesture { model.armCCLearn(param) }
                .accessibilityElement()
                .accessibilityLabel(Text(verbatim: spoken))
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Arms this control for MIDI learn")
            }
        }
    }
}

/// Replaces the play bar while CC learn is active.
struct CCLearnBar: View {
    @ObservedObject var learn: CCLearnState
    let model: SynthViewModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("MIDI CC LEARN")
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .foregroundColor(Theme.accent)
                Text(instruction)
                    .font(.system(size: 13))
                    .foregroundColor(Theme.label)
                    .lineLimit(2)
            }
            Spacer()
            if let target = learn.target, learn.map[target.rawValue] != nil {
                BigButton(title: "REMOVE CC", icon: "trash") { model.removeCC(for: target) }
            }
            BigButton(title: "DONE", icon: "checkmark", active: true) { model.toggleCCLearn() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Theme.panel)
    }

    private var instruction: String {
        if let target = learn.target {
            return "\(target.displayName): move a knob or fader on your controller…"
        }
        return "Tap a control, then move a knob or fader on your MIDI controller."
    }
}

/// Toolbar button that toggles CC learn and lights up while active.
struct CCLearnToggle: View {
    @ObservedObject var learn: CCLearnState
    let model: SynthViewModel

    var body: some View {
        Button { model.toggleCCLearn() } label: {
            Image(systemName: "slider.horizontal.3")
                .foregroundColor(learn.active ? Theme.accent : Theme.label)
                .frame(minWidth: 36, minHeight: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel("MIDI CC learn")
    }
}

// MARK: - Main view

/// Panel + play bar. Shared by the app and the AUv3 UI.
struct SynthMainView<Toolbar: View, Accessory: View>: View {
    let model: SynthViewModel
    @ViewBuilder var toolbar: Toolbar
    /// Optional strip between the panel and the play bar (app: loop recorder).
    @ViewBuilder var accessory: Accessory
    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(\.verticalSizeClass) private var vSize

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            SynthPanelView(model: model)
                .frame(maxHeight: .infinity)
            accessory
            BottomBar(learn: model.learn, model: model)
                .frame(height: PortraitReader.isPortrait(hSize, vSize) ? 146 : 54)
        }
        .overlay(alignment: .top) { StatusBanner(model: model) }
        .background(Theme.background.ignoresSafeArea())
        .onAppear { model.setPolling(true) }
        .onDisappear { model.setPolling(false) }
    }
}

extension SynthMainView where Accessory == EmptyView {
    init(model: SynthViewModel, @ViewBuilder toolbar: () -> Toolbar) {
        self.init(model: model, toolbar: toolbar, accessory: { EmptyView() })
    }
}

private struct BottomBar: View {
    @ObservedObject var learn: CCLearnState
    let model: SynthViewModel

    var body: some View {
        if learn.active {
            CCLearnBar(learn: learn, model: model)
        } else {
            PlayBar(model: model)
        }
    }
}

private struct StatusBanner: View {
    @ObservedObject var model: SynthViewModel

    var body: some View {
        if let message = model.statusMessage {
            Text(message)
                .font(Theme.pixel(12, .medium))
                .foregroundColor(Theme.ink)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: Theme.corner).fill(Theme.selected))
                .padding(.top, 50)
                .transition(.opacity)
                .allowsHitTesting(false)
        }
    }
}

/// Preset display: a small black OLED screen as on the OP-1 – category tag
/// in orange, program number in blue, name in white.
struct ToneDisplay: View {
    let number: String
    let name: String
    var category: String = ""

    var body: some View {
        HStack(spacing: 8) {
            if !category.isEmpty {
                Text(category.lowercased())
                    .font(Theme.pixel(10, .bold))
                    .foregroundColor(Theme.orange)
                    .lineLimit(1)
                    .fixedSize()
            }
            Text(number)
                .lineLimit(1)
                .foregroundColor(Theme.blue)
            Text(name.isEmpty ? "----------" : name.lowercased())
                .foregroundColor(Theme.displayText)
                .lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(Theme.dimLabel)
        }
        .font(Theme.pixel(14, .medium))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minWidth: 190, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.display))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.hairline, lineWidth: 1))
    }
}

/// Wordmark: lowercase monospaced, an orange dot as the only colour.
struct BrandMark: View {
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(Theme.orange).frame(width: 7, height: 7)
            Text("mks-50")
                .font(Theme.pixel(15, .bold))
                .foregroundColor(Theme.label)
        }
        .lineLimit(1)
        .fixedSize()
        .accessibilityLabel("MKS-50")
    }
}

/// One submenu per category (with icon) listing its factory presets, plus
/// "My Presets" with the user's saved sounds.
struct PresetCategoryMenus: View {
    let model: SynthViewModel

    var body: some View {
        if !model.userPresets.isEmpty {
            Menu {
                ForEach(model.userPresets, id: \.number) { preset in
                    Button(preset.name) { model.select(preset) }
                }
            } label: {
                Label("My Presets (\(model.userPresets.count))", systemImage: "star.fill")
            }
        }
        ForEach(model.factoryPresetGroups) { group in
            Menu {
                ForEach(group.presets, id: \.number) { preset in
                    Button(preset.name) { model.select(preset) }
                }
            } label: {
                Label("\(group.category.rawValue) (\(group.presets.count))", systemImage: group.category.icon)
            }
        }
    }
}

/// Toolbar used inside the AUv3 plug-in view (hosts manage user presets).
struct PluginToolbar: View {
    @ObservedObject var model: SynthViewModel

    var body: some View {
        HStack(spacing: 10) {
            BrandMark()
            StepButton(symbol: "chevron.left", label: "Previous preset") { model.stepFactoryPreset(-1) }
            Menu {
                PresetCategoryMenus(model: model)
            } label: {
                ToneDisplay(number: presetNumber, name: model.toneName, category: model.currentCategoryLabel)
            }
            StepButton(symbol: "chevron.right", label: "Next preset") { model.stepFactoryPreset(1) }
            Spacer()
            CCLearnToggle(learn: model.learn, model: model)
            Button { model.panic() } label: {
                Image(systemName: "exclamationmark.octagon")
                    .frame(minWidth: 36, minHeight: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel("All notes off")
        }
        .foregroundColor(Theme.label)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Theme.panel)
    }

    private var presetNumber: String {
        guard let n = model.currentPreset?.number else { return "--" }
        return n >= 0 ? String(format: "%02d", n + 1) : "U"
    }
}

// MARK: - Section flow layout

/// Lays sections out in lines: each line takes as many sections (at their
/// ideal width) as fit, then shares the leftover width among them, so a
/// line always spans the full width. Wider screens get more per line.
struct SectionFlow: Layout {
    var spacing: CGFloat = 10

    private struct Line {
        var indices: [Int] = []
        var widths: [CGFloat] = []
        var height: CGFloat = 0
    }

    private func lines(width: CGFloat, subviews: Subviews) -> [Line] {
        let ideals = subviews.map { min($0.sizeThatFits(.unspecified).width, width) }
        var result: [Line] = []
        var current = Line()
        var used: CGFloat = 0
        for (i, w) in ideals.enumerated() {
            let needed = current.indices.isEmpty ? w : used + spacing + w
            if !current.indices.isEmpty && needed > width {
                result.append(current)
                current = Line()
                used = 0
            }
            used = current.indices.isEmpty ? w : used + spacing + w
            current.indices.append(i)
            current.widths.append(w)
        }
        if !current.indices.isEmpty { result.append(current) }

        // Stretch every line to the full width.
        for k in result.indices {
            let line = result[k]
            let total = line.widths.reduce(0, +) + spacing * CGFloat(line.widths.count - 1)
            let extra = max(0, width - total) / CGFloat(line.widths.count)
            result[k].widths = line.widths.map { $0 + extra }
            result[k].height = zip(line.indices, result[k].widths).map { i, w in
                subviews[i].sizeThatFits(ProposedViewSize(width: w, height: nil)).height
            }.max() ?? 0
        }
        return result
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? subviews.map { $0.sizeThatFits(.unspecified).width }
            .reduce(0) { $0 + $1 + spacing } - spacing
        let ls = lines(width: max(width, 0), subviews: subviews)
        let height = ls.map(\.height).reduce(0, +) + spacing * CGFloat(max(ls.count - 1, 0))
        return CGSize(width: max(width, 0), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in lines(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for (i, w) in zip(line.indices, line.widths) {
                subviews[i].place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                                  proposal: ProposedViewSize(width: w, height: line.height))
                x += w + spacing
            }
            y += line.height + spacing
        }
    }
}
