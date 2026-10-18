import SwiftUI

/// SEQ page: sequencer settings, the random pattern generator and the
/// 16-step grid.
struct SequencerPage: View {
    let model: SynthViewModel
    @State private var editMode: Float = 0      // 0 note, 1 accent, 2 tie

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 10) { settings; pattern }
            VStack(alignment: .leading, spacing: 10) { settings; pattern }
        }
    }

    private var settings: some View {
        PanelSection(title: "SEQ") {
            VStack(alignment: .leading, spacing: 10) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 14) { switches; knobs }
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 14) { switches }
                        HStack(alignment: .top, spacing: 14) { knobs }
                    }
                }
                ParamSelector(param: model.model(.seqStyle), model: model, inline: true)
                HStack(spacing: 8) {
                    BigButton(title: "NEW", icon: "dice.fill") { model.generateSequence() }
                    BigButton(title: "VARY", icon: "shuffle") { model.varySequence() }
                }
            }
        }
    }

    @ViewBuilder private var switches: some View {
        ParamSelector(param: model.model(.seqOn), model: model, label: "SEQ")
        ParamSelector(param: model.model(.arpHold), model: model, label: "HOLD")
    }

    @ViewBuilder private var knobs: some View {
        ParamKnob(param: model.model(.seqRate), model: model)
        ParamKnob(param: model.model(.seqGate), model: model)
        ParamKnob(param: model.model(.seqGateVar), model: model)
        ParamKnob(param: model.model(.seqLength), model: model)
    }

    private var pattern: some View {
        PanelSection(title: "PATTERN") {
            VStack(alignment: .leading, spacing: 8) {
                StepSelector(label: "EDIT", options: ["NOTE", "ACC", "TIE"], value: $editMode,
                             cellWidth: 40, inline: true)
                StepGrid(model: model, editMode: Int(editMode))
                Text(hint)
                    .font(Theme.pixel(9, .regular))
                    .foregroundColor(Theme.dimLabel)
            }
        }
    }

    private var hint: String {
        switch Int(editMode) {
        case 1: return "tap: accent on/off"
        case 2: return "tap: tie into the next step"
        default: return "tap: step on/off · drag up/down: note"
        }
    }
}

/// 2 × 8 step buttons with a running playhead.
private struct StepGrid: View {
    let model: SynthViewModel
    let editMode: Int

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 20)) { _ in
            let playing = model.audioUnit.engine.sequencerStep
            VStack(spacing: 4) {
                ForEach(0..<2, id: \.self) { row in
                    HStack(spacing: 4) {
                        ForEach(0..<8, id: \.self) { col in
                            let i = row * 8 + col
                            StepCell(param: model.model(Param.seqStep(i)),
                                     length: model.model(.seqLength),
                                     model: model, index: i,
                                     editMode: editMode,
                                     playing: playing == i)
                        }
                    }
                }
            }
        }
    }
}

private struct StepCell: View {
    @ObservedObject var param: ParamModel
    @ObservedObject var length: ParamModel
    let model: SynthViewModel
    let index: Int
    let editMode: Int
    let playing: Bool

    @State private var dragStartNote: Int?

    var body: some View {
        let step = SeqStep(raw: Int(param.value.rounded()))
        let inRange = index <= Int(length.value.rounded())
        let tint = Theme.blue
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: Theme.corner)
                .fill(step == nil ? Theme.cell : (step!.accent ? Theme.white : tint))
            if step?.accent == true {
                Rectangle().fill(Theme.red).frame(height: 4)
            }
            VStack(spacing: 1) {
                Text(step.map { $0.note == 0 ? "0" : String(format: "%+d", $0.note) } ?? "·")
                    .font(Theme.pixel(12, .bold))
                Text("\(index + 1)")
                    .font(Theme.pixel(8, .regular))
                    .opacity(0.6)
            }
            .foregroundColor(step == nil ? Theme.dimLabel : Theme.ink)
            .frame(maxHeight: .infinity)
        }
        .overlay(alignment: .trailing) {
            if step?.tie == true {
                Rectangle().fill(Theme.red).frame(width: 4).offset(x: 4)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: Theme.corner)
                .stroke(playing ? Theme.label : .clear, lineWidth: 2)
        }
        .frame(width: 38, height: 44)
        .opacity(inRange ? 1 : 0.35)
        .overlay {
            KnobTouchSurface(
                onChanged: { t in
                    guard editMode == 0, let s = SeqStep(raw: Int(param.value.rounded())) else { return }
                    if dragStartNote == nil { dragStartNote = s.note }
                    let note = (dragStartNote ?? 0) + Int((-t.height / 14).rounded())
                    model.transposeStep(index, by: note - s.note)
                },
                onEnded: { dragStartNote = nil },
                onDoubleTap: {},
                onTap: { tap(step) })
        }
        .accessibilityElement()
        .accessibilityLabel("Step \(index + 1)")
        .accessibilityValue(step.map { $0.label } ?? "rest")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { tap(step) }
    }

    private func tap(_ step: SeqStep?) {
        let p = Param.seqStep(index)
        switch editMode {
        case 1:
            guard var s = step else { return }
            s.accent.toggle()
            model.set(p, Float(s.raw))
        case 2:
            guard var s = step else { return }
            s.tie.toggle()
            model.set(p, Float(s.raw))
        default:
            model.toggleStep(index)
        }
    }
}
