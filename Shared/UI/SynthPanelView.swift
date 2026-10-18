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
        let display: ((Float) -> String)? = (p.isDiscrete || p == .pulseDetune || p == .tempo || p == .delayTime || p == .lfoRate || p == .hpfFreq)
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

    var body: some View {
        let p = param.param
        StepSelector(label: label ?? p.shortName,
                     count: p.maxValue + 1,
                     value: model.binding(p),
                     accessibilityNames: p.valueStrings ?? []) { i, _ in
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

    private var page: PanelPage { PanelPage(rawValue: pageRaw) ?? .osc }

    var body: some View {
        VStack(spacing: 0) {
            pageTabs
            // No scroll view: it would steal vertical knob drags. Pages are
            // shown at full size and only scaled down on very small screens.
            FitToSpace {
                pageContent
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            }
        }
    }

    private var pageTabs: some View {
        HStack(spacing: 4) {
            ForEach(PanelPage.allCases) { p in
                let selected = p == page
                Button {
                    if !selected { pageRaw = p.rawValue }
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: p.icon).font(.system(size: 13, weight: .semibold))
                        Text(p.rawValue).font(.system(size: 10, weight: .bold, design: .rounded))
                    }
                    .foregroundColor(selected ? Theme.ink : Theme.label)
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .background(RoundedRectangle(cornerRadius: 3)
                        .fill(selected ? Theme.stripes[(PanelPage.allCases.firstIndex(of: p) ?? 0) % Theme.stripes.count] : Theme.cell))
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(Theme.stripes[(PanelPage.allCases.firstIndex(of: p) ?? 0) % Theme.stripes.count])
                            .frame(height: selected ? 0 : 2)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityLabel(p.rawValue)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    @ViewBuilder private var pageContent: some View {
        switch page {
        case .osc: oscPage
        case .mod: modPage
        case .filter: filterPage
        case .env: envPage
        case .amp: ampPage
        case .fx: fxPage
        case .patch: patchPage
        case .extra: extraPage
        }
    }

    // MARK: Helpers

    private func knob(_ p: Param, _ label: String? = nil) -> ParamKnob {
        ParamKnob(param: model.model(p), model: model, label: label)
    }

    private func selector(_ p: Param, _ label: String? = nil) -> ParamSelector {
        ParamSelector(param: model.model(p), model: model, label: label)
    }

    private func group<Content: View>(_ title: String, _ icon: String,
                                      @ViewBuilder _ content: () -> Content) -> some View {
        PanelSection(title: title, icon: icon, content: content)
    }

    /// Sections side by side, top aligned.
    private func row<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) { content() }
    }

    /// One row of knobs with even spacing.
    private func knobs<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 16) { content() }
    }

    /// Knob row on top, switches below – the same order on every page.
    private func stack<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) { content() }
    }

    // MARK: Pages

    private var oscPage: some View {
        row {
            group("WAVE", "waveform") {
                stack {
                    HStack(spacing: 14) {
                        selector(.dcoPulse)
                        selector(.dcoSaw)
                    }
                    HStack(spacing: 14) {
                        selector(.dcoSub)
                        selector(.dcoSubLevel)
                    }
                }
            }
            group("DCO", "dial.medium") {
                stack {
                    knobs {
                        knob(.dcoPwDepth)
                        knob(.dcoPwmRate)
                    }
                    HStack(spacing: 14) {
                        selector(.dcoRange)
                        selector(.dcoNoiseLevel)
                    }
                }
            }
        }
    }

    private var modPage: some View {
        row {
            group("LFO", "wave.3.right") {
                stack {
                    HStack(alignment: .top, spacing: 16) {
                        LFORateControl(sync: model.model(.lfoSync), model: model)
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
                stack {
                    knob(.hpfFreq, "FREQ")
                    selector(.hpfCutoff, "STEP")
                }
            }
        }
    }

    private var envPage: some View {
        group("ENVELOPE", "chart.xyaxis.line") {
            HStack(alignment: .top, spacing: 18) {
                stack {
                    LiveEnvelopeGraph(model: model)
                        .frame(width: 200, height: 110)
                    selector(.envRetrigger)
                }
                stack {
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
            group("DELAY", "repeat") {
                stack {
                    knobs {
                        knob(.delayMix)
                        DelayTimeControl(sync: model.model(.delaySync), model: model)
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
                    Text("Unison: PATCH › KEY › UNISON")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Theme.dimLabel)
                }
            }
        }
    }
}

/// Shows its content at natural size, centred at the top, and scales it down
/// only when the available space is too small.
struct FitToSpace<Content: View>: View {
    @ViewBuilder var content: Content
    @State private var natural: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            content
                .fixedSize()
                .background(GeometryReader { inner in
                    Color.clear.preference(key: NaturalSizeKey.self, value: inner.size)
                })
                .scaleEffect(scale(in: geo.size), anchor: .top)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
        .onPreferenceChange(NaturalSizeKey.self) { natural = $0 }
    }

    private func scale(in space: CGSize) -> CGFloat {
        guard natural.width > 0, natural.height > 0 else { return 1 }
        return min(1, space.width / natural.width, space.height / natural.height)
    }
}

private struct NaturalSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

// MARK: - Play button

/// Large single "play" pad with an assignable MIDI note.
struct PlayBar: View {
    @ObservedObject var model: SynthViewModel
    /// Resets automatically when the touch is cancelled (Control Center,
    /// calls, backgrounding), so the pad can never get stuck.
    @GestureState private var pressing = false

    var body: some View {
        HStack(spacing: 10) {
            BigButton(title: model.isLearningPadNote ? "PLAY A KEY…" : "LEARN",
                      icon: "pianokeys", active: model.isLearningPadNote) { model.toggleLearnPadNote() }

            HStack(spacing: 6) {
                StepButton(symbol: "chevron.left.2", label: "Octave down") { model.transposePad(-12) }
                StepButton(symbol: "chevron.left", label: "Semitone down") { model.transposePad(-1) }
            }

            pad

            HStack(spacing: 6) {
                StepButton(symbol: "chevron.right", label: "Semitone up") { model.transposePad(1) }
                StepButton(symbol: "chevron.right.2", label: "Octave up") { model.transposePad(12) }
            }

            BigButton(title: "HOLD", icon: model.padLatch ? "lock.fill" : "lock.open",
                      active: model.padLatch) { model.padLatch.toggle() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.panel)
    }

    private var pad: some View {
        let lit = model.padSounding || pressing
        return HStack(spacing: 10) {
            Image(systemName: lit ? "speaker.wave.3.fill" : "play.fill")
                .font(.system(size: 18, weight: .bold))
            VStack(alignment: .leading, spacing: 0) {
                Text(model.padNoteName)
                    .font(.system(size: 24, weight: .heavy, design: .rounded))
                Text(model.padLatch ? (model.padSounding ? "TAP TO STOP" : "TAP TO HOLD") : "PLAY")
                    .font(.system(size: 10, weight: .bold))
                    .opacity(0.8)
            }
        }
        .foregroundColor(lit ? Theme.ink : Theme.label)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Grey key with a red lamp stripe, lit red while playing.
        .background(RoundedRectangle(cornerRadius: 4).fill(lit ? Theme.red : Theme.cell))
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.red).frame(height: lit ? 0 : 3).padding(.horizontal, 10)
        }
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(lit ? Theme.white : Theme.panelEdge, lineWidth: 2))
        .shadow(color: lit ? Theme.red.opacity(0.6) : .clear, radius: 8)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($pressing) { _, state, _ in state = true }
        )
        .onChangeCompat(of: pressing) { isDown in
            if isDown { model.padTouchDown() } else { model.padTouchUp() }
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
        .padding(.vertical, 8)
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

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            RetroStripe(height: 3)
            SynthPanelView(model: model)
                .frame(maxHeight: .infinity)
            accessory
            BottomBar(learn: model.learn, model: model)
                .frame(height: 76)
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
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Capsule().fill(Theme.accent))
                .padding(.top, 50)
                .transition(.opacity)
                .allowsHitTesting(false)
        }
    }
}

/// Backlit LCD tone name display (Alpha Juno-2 style).
struct ToneDisplay: View {
    let number: String
    let name: String
    var category: String = ""

    var body: some View {
        HStack(spacing: 8) {
            if !category.isEmpty {
                Text(category)
                    .font(.system(size: 10, weight: .heavy, design: .rounded))
                    .foregroundColor(Theme.display)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Theme.displayText.opacity(0.85)))
                    .lineLimit(1)
                    .fixedSize()
            }
            Text(number)
                .lineLimit(1)
                .foregroundColor(Theme.displayText.opacity(0.65))
            Text(name.isEmpty ? "----------" : name.uppercased())
                .foregroundColor(Theme.displayText)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(Theme.displayText.opacity(0.6))
        }
        .font(.system(size: 15, weight: .bold, design: .monospaced))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(minWidth: 190, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.display))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.black.opacity(0.5), lineWidth: 2))
    }
}

/// Small "αJUNO"-style wordmark used in the toolbars.
struct BrandMark: View {
    var body: some View {
        HStack(spacing: 1) {
            Text("α")
                .font(.system(size: 20, weight: .black, design: .serif))
                .foregroundColor(Theme.accent)
            Text("MKS-50")
                .font(.system(size: 15, weight: .black, design: .rounded))
                .foregroundColor(Theme.label)
        }
        .lineLimit(1)
        .fixedSize()
        .accessibilityLabel("MKS-50")
    }
}

/// One submenu per category (with icon) listing its factory presets.
struct PresetCategoryMenus: View {
    let model: SynthViewModel

    var body: some View {
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
