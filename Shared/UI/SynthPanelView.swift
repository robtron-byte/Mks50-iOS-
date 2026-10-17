import SwiftUI

/// All MKS-50 tone and patch parameters laid out as a hardware-style panel.
struct SynthPanelView: View {
    @ObservedObject var model: SynthViewModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 8) {
                dcoSection
                dcoModSection
                vcfSection
                envSection
                vcaSection
                lfoSection
                hpfChorusSection
                controlSection
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    // MARK: Helpers

    private func knob(_ p: Param, _ label: String? = nil, size: CGFloat = 40) -> some View {
        let display: ((Float) -> String)? = p.isDiscrete ? { value in p.string(for: value) } : nil
        return Knob(label: label ?? p.shortName,
                    value: model.binding(p),
                    maxValue: Float(p.maxValue),
                    defaultValue: Float(p.defaultValue),
                    size: size,
                    display: display)
    }

    private func selector(_ p: Param, _ label: String? = nil, width: CGFloat = 20) -> some View {
        StepSelector(label: label ?? p.shortName,
                     options: p.valueStrings ?? [],
                     value: model.binding(p),
                     cellWidth: width)
    }

    // MARK: Sections

    private var dcoSection: some View {
        PanelSection(title: "DCO") {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    selector(.dcoRange, width: 24)
                    selector(.dcoPulse)
                    selector(.dcoSubLevel)
                }
                VStack(alignment: .leading, spacing: 6) {
                    selector(.dcoSaw)
                    selector(.dcoSub)
                    selector(.dcoNoiseLevel)
                }
            }
        }
    }

    private var dcoModSection: some View {
        PanelSection(title: "DCO MOD") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    knob(.dcoLfoDepth)
                    knob(.dcoEnvDepth)
                    knob(.dcoAfterDepth)
                }
                HStack(spacing: 6) {
                    knob(.dcoPwDepth)
                    knob(.dcoPwmRate)
                }
                selector(.dcoEnvMode, width: 30)
            }
        }
    }

    private var vcfSection: some View {
        PanelSection(title: "VCF") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    knob(.vcfCutoff, size: 46)
                    knob(.vcfResonance, size: 46)
                    knob(.vcfEnvDepth, size: 46)
                }
                HStack(spacing: 6) {
                    knob(.vcfLfoDepth, size: 34)
                    knob(.vcfKeyFollow, size: 34)
                    knob(.vcfAfterDepth, size: 34)
                }
                selector(.vcfEnvMode, width: 30)
            }
        }
    }

    private var envSection: some View {
        PanelSection(title: "ENV") {
            VStack(alignment: .leading, spacing: 6) {
                EnvelopeGraph(envelope: model.envelope)
                    .frame(width: 190, height: 44)
                HStack(spacing: 4) {
                    knob(.envT1, size: 34)
                    knob(.envL1, size: 34)
                    knob(.envT2, size: 34)
                    knob(.envL2, size: 34)
                }
                HStack(spacing: 4) {
                    knob(.envT3, size: 34)
                    knob(.envL3, size: 34)
                    knob(.envT4, size: 34)
                    knob(.envKeyFollow, size: 34)
                }
            }
        }
    }

    private var vcaSection: some View {
        PanelSection(title: "VCA") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    knob(.vcaLevel)
                    knob(.vcaAfterDepth)
                }
                selector(.vcaEnvMode, width: 30)
            }
        }
    }

    private var lfoSection: some View {
        PanelSection(title: "LFO") {
            VStack(spacing: 6) {
                knob(.lfoRate)
                knob(.lfoDelay)
            }
        }
    }

    private var hpfChorusSection: some View {
        PanelSection(title: "HPF / CHORUS") {
            VStack(alignment: .leading, spacing: 8) {
                selector(.hpfCutoff, "HPF CUTOFF")
                selector(.chorus, width: 30)
                knob(.chorusRate, "CHORUS RATE")
            }
        }
    }

    private var controlSection: some View {
        PanelSection(title: "PATCH") {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    selector(.keyMode, width: 36)
                    HStack(alignment: .bottom, spacing: 6) {
                        knob(.chordIndex, "CHORD", size: 34)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.chordDescription(model.intValue(.chordIndex)))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(Theme.displayText)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(RoundedRectangle(cornerRadius: 3).fill(Theme.display))
                            Button("LEARN") { model.learnChord() }
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.black)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(RoundedRectangle(cornerRadius: 3).fill(Theme.accent))
                                .buttonStyle(.plain)
                        }
                    }
                    selector(.portaSwitch, "PORTAMENTO", width: 30)
                }
                VStack(spacing: 6) {
                    HStack(spacing: 6) {
                        knob(.portaTime, size: 34)
                        knob(.benderRange, size: 34)
                    }
                    HStack(spacing: 6) {
                        knob(.modSensitivity, size: 34)
                        knob(.keyShift, size: 34)
                    }
                    knob(.volume, size: 34)
                }
            }
        }
    }
}

/// Panel + performance controls + keyboard. Shared by the app and the AUv3 UI.
struct SynthMainView<Toolbar: View>: View {
    @ObservedObject var model: SynthViewModel
    @ViewBuilder var toolbar: Toolbar

    var body: some View {
        GeometryReader { geo in
            let keyboardHeight = min(150, max(90, geo.size.height * 0.3))
            VStack(spacing: 0) {
                toolbar
                SynthPanelView(model: model)
                    .frame(maxHeight: .infinity)
                performanceBar
                    .frame(height: keyboardHeight)
            }
            .overlay(alignment: .top) { statusBanner }
        }
        .background(Theme.background.ignoresSafeArea())
    }

    private var performanceBar: some View {
        HStack(spacing: 6) {
            VStack(spacing: 6) {
                octaveButton("chevron.up", 1)
                Text(octaveLabel)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.dimLabel)
                octaveButton("chevron.down", -1)
            }
            .frame(width: 34)
            ControlStrip(label: "BEND", bipolar: true) { model.pitchBend($0) }
            ControlStrip(label: "MOD") { model.modWheel($0) }
            ControlStrip(label: "AFTER") { model.aftertouch($0) }
            KeyboardView(baseNote: model.keyboardBaseNote,
                         onNoteOn: { note, velocity in model.noteOn(note, velocity: velocity) },
                         onNoteOff: { note in model.noteOff(note) })
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Theme.panel)
    }

    private var octaveLabel: String { "C\(model.keyboardBaseNote / 12 - 1)" }

    private func octaveButton(_ symbol: String, _ delta: Int) -> some View {
        Button { model.shiftKeyboard(octaves: delta) } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(Theme.label)
                .frame(width: 32, height: 28)
                .background(RoundedRectangle(cornerRadius: 4).fill(Theme.knobBody))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var statusBanner: some View {
        if let message = model.statusMessage {
            Text(message)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.black)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
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
