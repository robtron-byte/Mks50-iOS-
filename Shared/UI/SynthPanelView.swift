import SwiftUI

/// Pages of the panel. Fewer, larger controls per page instead of one long
/// strip of tiny knobs.
enum PanelPage: String, CaseIterable, Identifiable {
    case osc = "OSC"
    case mod = "MOD"
    case filter = "FILTER"
    case env = "ENV"
    case ampFx = "AMP · FX"
    case patch = "PATCH"
    case extra = "EXTRA"

    var id: String { rawValue }
}

/// All MKS-50 tone and patch parameters, one page at a time.
struct SynthPanelView: View {
    @ObservedObject var model: SynthViewModel
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
                    pageRaw = p.rawValue
                } label: {
                    Text(p.rawValue)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundColor(selected ? .black : Theme.label)
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .background(RoundedRectangle(cornerRadius: 7)
                            .fill(selected ? Theme.accent : Theme.knobBody))
                }
                .buttonStyle(.plain)
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
        case .ampFx: ampFxPage
        case .patch: patchPage
        case .extra: extraPage
        }
    }

    // MARK: Helpers

    private func knob(_ p: Param, _ label: String? = nil) -> some View {
        let display: ((Float) -> String)? = (p.isDiscrete || p == .pulseDetune) ? { value in p.string(for: value) } : nil
        return Knob(label: label ?? p.shortName,
                    value: model.binding(p),
                    maxValue: Float(p.maxValue),
                    defaultValue: Float(p.defaultValue),
                    display: display)
            .modifier(CCLearnOverlay(model: model, param: p))
    }

    private func selector(_ p: Param, _ label: String? = nil) -> some View {
        StepSelector(label: label ?? p.shortName,
                     options: p.valueStrings ?? [],
                     value: model.binding(p))
            .modifier(CCLearnOverlay(model: model, param: p))
    }

    private func group<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        PanelSection(title: title, content: content)
    }

    // MARK: Pages

    private var oscPage: some View {
        let wave = group("WAVE") {
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
        }
        let dco = group("DCO") {
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
        }
        // Side by side when there is room, stacked on narrow phones.
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 14) { wave; dco }
            VStack(spacing: 14) { wave; dco }
        }
    }

    private var modPage: some View {
        HStack(alignment: .top, spacing: 14) {
            group("LFO") {
                HStack(spacing: 18) {
                    knob(.lfoRate)
                    knob(.lfoDelay)
                }
            }
            group("DCO MOD") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 18) {
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
        VStack(spacing: 14) {
            group("VCF") {
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
    }

    private var envPage: some View {
        group("ENVELOPE") {
            HStack(alignment: .center, spacing: 18) {
                EnvelopeGraph(envelope: model.envelope)
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

    private var ampFxPage: some View {
        HStack(alignment: .top, spacing: 14) {
            group("VCA") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 18) {
                        knob(.vcaLevel)
                        knob(.vcaAfterDepth)
                    }
                    selector(.vcaEnvMode)
                }
            }
            group("CHORUS") {
                VStack(alignment: .leading, spacing: 10) {
                    selector(.chorus, "CHORUS")
                    knob(.chorusRate)
                }
            }
            group("OUTPUT") {
                knob(.volume)
            }
        }
    }

    private var patchPage: some View {
        HStack(alignment: .top, spacing: 14) {
            group("KEY") {
                VStack(alignment: .leading, spacing: 10) {
                    selector(.keyMode)
                    HStack(alignment: .center, spacing: 14) {
                        knob(.chordIndex, "CHORD")
                        VStack(alignment: .leading, spacing: 8) {
                            Text(model.chordDescription(model.intValue(.chordIndex)))
                                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                .foregroundColor(Theme.displayText)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(RoundedRectangle(cornerRadius: 4).fill(Theme.display))
                            BigButton(title: "LEARN CHORD") { model.learnChord() }
                        }
                    }
                }
            }
            group("PERFORM") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 18) {
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
        HStack(alignment: .top, spacing: 14) {
            group("PULSE") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 18) {
                        knob(.pulseDetune)
                        knob(.pulseEnvMod)
                    }
                    selector(.pulseSync, "PULSE SYNC")
                }
            }
            group("VOICES") {
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

/// Large single "play" pad with an assignable MIDI note.
struct PlayBar: View {
    @ObservedObject var model: SynthViewModel
    /// Resets automatically when the touch is cancelled (Control Center,
    /// calls, backgrounding), so the pad can never get stuck.
    @GestureState private var pressing = false

    var body: some View {
        HStack(spacing: 10) {
            BigButton(title: model.isLearningPadNote ? "PLAY A KEY…" : "MIDI LEARN",
                      active: model.isLearningPadNote) { model.toggleLearnPadNote() }

            HStack(spacing: 6) {
                StepButton(symbol: "chevron.left.2", label: "Octave down") { model.transposePad(-12) }
                StepButton(symbol: "chevron.left", label: "Semitone down") { model.transposePad(-1) }
            }

            pad

            HStack(spacing: 6) {
                StepButton(symbol: "chevron.right", label: "Semitone up") { model.transposePad(1) }
                StepButton(symbol: "chevron.right.2", label: "Octave up") { model.transposePad(12) }
            }

            BigButton(title: "HOLD", active: model.padLatch) { model.padLatch.toggle() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.panel)
    }

    private var pad: some View {
        let lit = model.padSounding
        return VStack(spacing: 2) {
            Text(model.padNoteName)
                .font(.system(size: 24, weight: .heavy, design: .rounded))
            Text(model.padLatch ? (lit ? "TAP TO STOP" : "TAP TO HOLD") : "PLAY")
                .font(.system(size: 10, weight: .bold))
                .opacity(0.8)
        }
        .foregroundColor(lit ? .black : Theme.label)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 12)
            .fill(lit ? Theme.accent : Theme.knobBody))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .stroke(lit ? Theme.accent : Theme.panelEdge, lineWidth: 2))
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

/// In CC-learn mode: covers a control, shows its CC and arms it on tap.
struct CCLearnOverlay: ViewModifier {
    @ObservedObject var model: SynthViewModel
    let param: Param

    func body(content: Content) -> some View {
        content.overlay {
            if model.ccLearnActive {
                let armed = model.ccLearnTarget == param
                let cc = model.ccNumber(for: param)
                let badge: String = cc.map { "CC \($0)" } ?? "–"
                let spoken: String = param.displayName + ", " + (cc.map { "MIDI CC \($0)" } ?? "no MIDI CC")
                ZStack(alignment: .topTrailing) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(armed ? Theme.accent.opacity(0.3) : Color.black.opacity(0.35))
                        .overlay(RoundedRectangle(cornerRadius: 8)
                            .stroke(armed ? Theme.accent : (cc != nil ? Theme.displayText : Theme.panelEdge),
                                    lineWidth: armed ? 2.5 : 1))
                    Text(verbatim: badge)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.black)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(cc != nil ? Theme.displayText : Theme.dimLabel))
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
    @ObservedObject var model: SynthViewModel

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
            if let target = model.ccLearnTarget, model.ccNumber(for: target) != nil {
                BigButton(title: "REMOVE CC") { model.removeCC(for: target) }
            }
            BigButton(title: "DONE", active: true) { model.toggleCCLearn() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Theme.panel)
    }

    private var instruction: String {
        if let target = model.ccLearnTarget {
            return "\(target.displayName): move a knob or fader on your controller…"
        }
        return "Tap a control, then move a knob or fader on your MIDI controller."
    }
}

/// Panel + play bar. Shared by the app and the AUv3 UI.
struct SynthMainView<Toolbar: View>: View {
    @ObservedObject var model: SynthViewModel
    @ViewBuilder var toolbar: Toolbar

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            SynthPanelView(model: model)
                .frame(maxHeight: .infinity)
            if model.ccLearnActive {
                CCLearnBar(model: model)
                    .frame(height: 76)
            } else {
                PlayBar(model: model)
                    .frame(height: 76)
            }
        }
        .overlay(alignment: .top) { statusBanner }
        .background(Theme.background.ignoresSafeArea())
        .onAppear { model.setPolling(true) }
        .onDisappear { model.setPolling(false) }
    }

    @ViewBuilder private var statusBanner: some View {
        if let message = model.statusMessage {
            Text(message)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.black)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Capsule().fill(Theme.accent))
                .padding(.top, 50)
                .transition(.opacity)
        }
    }
}

/// Green LCD-style tone name display.
struct ToneDisplay: View {
    let number: String
    let name: String

    var body: some View {
        HStack(spacing: 8) {
            Text(number)
                .foregroundColor(Theme.displayText.opacity(0.7))
            Text(name.isEmpty ? "----------" : name.uppercased())
                .foregroundColor(Theme.displayText)
                .lineLimit(1)
        }
        .font(.system(size: 14, weight: .semibold, design: .monospaced))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(minWidth: 170, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 4).fill(Theme.display))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.panelEdge, lineWidth: 1))
    }
}

/// Toolbar used inside the AUv3 plug-in view (hosts manage user presets).
struct PluginToolbar: View {
    @ObservedObject var model: SynthViewModel

    var body: some View {
        HStack(spacing: 10) {
            Text("MKS-50")
                .font(.system(size: 15, weight: .black, design: .rounded))
                .foregroundColor(Theme.accent)
            Button { model.stepFactoryPreset(-1) } label: { Image(systemName: "chevron.left") }
            Menu {
                ForEach(model.factoryPresets, id: \.number) { preset in
                    Button(preset.name) { model.select(preset) }
                }
            } label: {
                ToneDisplay(number: presetNumber, name: model.toneName)
            }
            Button { model.stepFactoryPreset(1) } label: { Image(systemName: "chevron.right") }
            Spacer()
            Button { model.toggleCCLearn() } label: {
                Image(systemName: "slider.horizontal.3")
                    .foregroundColor(model.ccLearnActive ? Theme.accent : Theme.label)
            }
            .accessibilityLabel("MIDI CC learn")
            Button { model.panic() } label: { Image(systemName: "exclamationmark.octagon") }
        }
        .foregroundColor(Theme.label)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Theme.panel)
    }

    private var presetNumber: String {
        guard let n = model.currentPreset?.number else { return "--" }
        return n >= 0 ? String(format: "%02d", n + 1) : "U"
    }
}
