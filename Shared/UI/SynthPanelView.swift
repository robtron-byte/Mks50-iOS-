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
        let display: ((Float) -> String)? = (p.isDiscrete || p == .pulseDetune || p == .tempo || p == .delayTime || p == .lfoRate)
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
            // Scroll only on screens where a page does not fit, so knob
            // drags never fight with a scroll view on normal devices.
            ViewThatFits(in: .vertical) {
                paddedPage
                ScrollView(.vertical, showsIndicators: false) { paddedPage }
            }
            .frame(maxHeight: .infinity, alignment: .top)
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
                    .foregroundColor(selected ? .white : Theme.label)
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .background(RoundedRectangle(cornerRadius: 7)
                        .fill(selected ? Theme.accent : Theme.cell))
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

    private var paddedPage: some View {
        pageContent
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
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

    /// Side by side when there is room, stacked on narrow phones.
    private func adaptive<A: View, B: View>(_ a: A, _ b: B) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 14) { a; b }
            VStack(spacing: 14) { a; b }
        }
    }

    // MARK: Pages

    private var oscPage: some View {
        adaptive(
            group("WAVE", "waveform") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 14) {
                        selector(.dcoPulse)
                        selector(.dcoSaw)
                    }
                    HStack(spacing: 14) {
                        selector(.dcoSub)
                        selector(.dcoSubLevel)
                    }
                }
            },
            group("DCO", "dial.medium") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 14) {
                        selector(.dcoRange)
                        selector(.dcoNoiseLevel)
                    }
                    HStack(spacing: 18) {
                        knob(.dcoPwDepth)
                        knob(.dcoPwmRate)
                    }
                }
            })
    }

    private var modPage: some View {
        adaptive(
            group("LFO", "wave.3.right") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 18) {
                        LFORateControl(sync: model.model(.lfoSync), model: model)
                        knob(.lfoDelay)
                        VStack(alignment: .leading, spacing: 8) {
                            selector(.lfoSync)
                            selector(.lfoKeySync)
                        }
                    }
                    selector(.lfoWave)
                }
            },
            group("DCO MOD", "waveform.path.ecg") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 18) {
                        knob(.dcoLfoDepth)
                        knob(.dcoEnvDepth)
                        knob(.dcoAfterDepth)
                    }
                    selector(.dcoEnvMode)
                }
            })
    }

    private var filterPage: some View {
        group("VCF", "line.3.horizontal.decrease") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 18) {
                    knob(.vcfCutoff)
                    knob(.vcfResonance)
                    knob(.vcfEnvDepth)
                    knob(.vcfKeyFollow)
                    knob(.vcfLfoDepth)
                    knob(.vcfAfterDepth)
                }
                HStack(spacing: 24) {
                    selector(.vcfEnvMode)
                    selector(.hpfCutoff, "HPF")
                }
            }
        }
    }

    private var envPage: some View {
        group("ENVELOPE", "chart.xyaxis.line") {
            HStack(alignment: .center, spacing: 18) {
                LiveEnvelopeGraph(model: model)
                    .frame(width: 220, height: 120)
                VStack(spacing: 10) {
                    HStack(spacing: 14) {
                        knob(.envT1)
                        knob(.envT2)
                        knob(.envT3)
                        knob(.envT4)
                    }
                    HStack(spacing: 14) {
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
        HStack(alignment: .top, spacing: 14) {
            group("VCA", "speaker.wave.2.fill") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 18) {
                        knob(.vcaLevel)
                        knob(.vcaAfterDepth)
                    }
                    selector(.vcaEnvMode)
                }
            }
            group("OUTPUT", "hifispeaker.fill") {
                knob(.volume)
            }
        }
    }

    private var fxPage: some View {
        adaptive(
            group("DELAY", "repeat") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 16) {
                        knob(.delayMix)
                        DelayTimeControl(sync: model.model(.delaySync), model: model)
                        knob(.delayFeedback)
                        knob(.delayTone)
                    }
                    HStack(spacing: 14) {
                        selector(.delaySync, "TEMPO SYNC")
                        selector(.delayPingPong)
                    }
                }
            },
            HStack(alignment: .top, spacing: 14) {
                group("REVERB", "building.columns") {
                    HStack(spacing: 16) {
                        knob(.reverbMix)
                        knob(.reverbSize)
                        knob(.reverbDamp)
                    }
                }
                group("CHORUS", "circle.hexagongrid") {
                    VStack(alignment: .leading, spacing: 10) {
                        selector(.chorus, "CHORUS")
                        HStack(spacing: 14) {
                            knob(.chorusRate)
                            knob(.tempo)
                        }
                    }
                }
            })
    }

    private var patchPage: some View {
        adaptive(
            group("KEY", "pianokeys") {
                VStack(alignment: .leading, spacing: 10) {
                    selector(.keyMode)
                    HStack(alignment: .center, spacing: 14) {
                        knob(.chordIndex, "CHORD")
                        ChordReadout(chordIndex: model.model(.chordIndex), model: model)
                    }
                }
            },
            group("PERFORM", "hand.point.up.left.fill") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 18) {
                        knob(.portaTime)
                        knob(.benderRange)
                        knob(.modSensitivity)
                        knob(.keyShift)
                    }
                    selector(.portaSwitch, "PORTAMENTO")
                }
            })
    }

    private var extraPage: some View {
        HStack(alignment: .top, spacing: 14) {
            group("PULSE", "square.split.diagonal") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 18) {
                        knob(.pulseDetune)
                        knob(.pulseEnvMod)
                    }
                    selector(.pulseSync, "PULSE SYNC")
                }
            }
            group("VOICES", "person.3.fill") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 18) {
                        knob(.voiceDrift)
                        knob(.unisonDetune)
                    }
                    Text("Unison: PATCH → KEY MODE → UNISON")
                        .font(.system(size: 11))
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
        .foregroundColor(lit ? .white : Theme.label)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).fill(lit ? Theme.accent : Theme.cell))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(lit ? Theme.accent : Theme.panelEdge, lineWidth: 2))
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
struct SynthMainView<Toolbar: View>: View {
    let model: SynthViewModel
    @ViewBuilder var toolbar: Toolbar

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            SynthPanelView(model: model)
                .frame(maxHeight: .infinity)
            BottomBar(learn: model.learn, model: model)
                .frame(height: 76)
        }
        .overlay(alignment: .top) { StatusBanner(model: model) }
        .background(Theme.background.ignoresSafeArea())
        .onAppear { model.setPolling(true) }
        .onDisappear { model.setPolling(false) }
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
            }
            Text(number)
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
