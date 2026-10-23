import Foundation

/// Live control from an Intech Studio Grid PO16 (16 potentiometers, no
/// buttons) on MIDI channel 15, PO16 pages 3-4. The matching Grid Editor
/// profiles are in Tools/PO16 (one per page, made by Tools/po16_profiles.py).
/// The JP6 app on pages 1-2, channel 16, so one PO16 plays both apps: the side button
/// steps through pages 1 → 2 → 3 → 4.
///
/// Protocol (channel 15, absolute 0...127):
/// - Page 3 SOUND: pot p → CC 32 + p
/// - Page 4 PERFORM: pot p → CC 48 + p
/// - CC 96: the PO16 loaded one of these pages
///
/// Pickup: a pot only takes over a parameter once it reaches the current
/// value (after a preset change, a page switch or a change on screen), so
/// nothing jumps. Switches (ARP, SEQ, HOLD) follow the pot crossing the
/// middle; REC starts a take when turned past the middle; a loop pad pot
/// sets the pad's level and stops the pad at zero / starts it from zero.
/// DELAY TIME sets the note value while the delay is tempo-synced (the
/// default), else the free time.
final class GridController {
    static let enabledKey = "gridControllerEnabled"
    /// MIDI channel of this app's PO16 pages (1...16).
    static let channel = 15
    static var ccStatus: UInt8 { UInt8(0xB0 + channel - 1) }

    // MARK: Layout (keep in sync with Tools/po16_profiles.py)

    /// Page 1, left to right, top to bottom.
    static let soundPage: [Param] = [
        .vcfCutoff, .vcfResonance, .vcfEnvDepth, .hpfFreq,            // filter
        .lfoRate, .vcfLfoDepth, .dcoLfoDepth, .dcoPwDepth,            // modulation
        .envT1, .envT2, .envL3, .envT4,                               // envelope (attack, decay, sustain, release)
        .delayMix, .delayFeedback, .delayTime, .reverbMix,            // effects
    ]

    private enum Perform: Int {
        case arp, arpRate, seq, seqRate
        case seqGate, seqGateVar, transpose, stutter
        case tempo, hold, rec, loopsMaster
        case pad1, pad2, pad3, pad4
    }

    private let synth: SynthViewModel
    private let recorder: RecorderModel
    private let pads: LoopPadsModel
    private var engine: SynthEngine { synth.audioUnit.engine }

    /// Last position per CC, and whether it has picked up its parameter
    /// (with the value it last set, to notice changes made elsewhere).
    private var lastPosition: [Int: Int] = [:]
    private var pickedUp: [Int: Float] = [:]
    private var presetStamp = ""
    private var masterLevel: Float = 1
    private var timer: Timer?

    init(synth: SynthViewModel, midi: MIDIManager, recorder: RecorderModel, pads: LoopPadsModel) {
        self.synth = synth
        self.recorder = recorder
        self.pads = pads
        midi.onControllerCC = { [weak self] status, cc, value in
            // MIDI thread: claim this app's PO16 CCs, handle them on main.
            guard status == GridController.ccStatus, (32...63).contains(cc) || cc == 96,
                  UserDefaults.standard.object(forKey: GridController.enabledKey) as? Bool ?? true else { return false }
            DispatchQueue.main.async { self?.handle(cc: Int(cc), value: Int(value)) }
            return true
        }
        // A new preset: every pot has to pick its parameter up again.
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in self?.watchPreset() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    deinit { timer?.invalidate() }

    // MARK: Input (main thread)

    private func handle(cc: Int, value: Int) {
        switch cc {
        case 32..<48:
            let p = effective(GridController.soundPage[cc - 32])
            if p.maxValue <= 24 { list(cc, p, value) } else { continuous(cc, p, value) }
        case 48..<64:
            perform(cc, Perform(rawValue: cc - 48)!, value)
        case 96:
            pickedUp.removeAll()                    // other page: pick up anew
            lastPosition.removeAll()
        default:
            break
        }
        lastPosition[cc] = value
    }

    /// Soft takeover (positions 0...127): once the pot has reached the
    /// parameter (`current`) it sets it directly. Before that the parameter
    /// follows the pot's movement right away, scaled so that both arrive
    /// together at the end the pot is turning to ("value scaling"). Nothing
    /// jumps, and a pot never seems dead (with plain pickup the cutoff at
    /// 127 only moved once the pot was turned fully right).
    /// `apply` sets a position and returns the parameter value it set.
    private func pickUp(_ cc: Int, _ value: Int, current: Float, apply: (Float) -> Float) {
        if let set = pickedUp[cc], abs(set - currentParameterValue(cc)) > 0.01 {
            pickedUp[cc] = nil                      // changed elsewhere (screen, MIDI learn)
        }
        let v = Float(value)
        let last = lastPosition[cc].map(Float.init)
        let crossed = last.map { ($0 - current) * (v - current) <= 0 } ?? false
        if pickedUp[cc] != nil || abs(v - current) <= 3 || crossed {
            pickedUp[cc] = apply(v)
            return
        }
        // First message after a page / preset change: wait for movement.
        guard let last, last != v else { return }
        let end: Float = v > last ? 127 : 0
        guard abs(end - last) >= 1 else { return }
        let next = current + (end - current) * (v - last) / (end - last)
        _ = apply(min(max(next, 0), 127))
    }

    /// The parameter value a picked-up pot last set, for change detection.
    private func currentParameterValue(_ cc: Int) -> Float {
        switch cc {
        case 32..<48: return synth.value(effective(GridController.soundPage[cc - 32]))
        case 48..<64:
            switch Perform(rawValue: cc - 48)! {
            case .arpRate: return synth.value(.arpRate)
            case .seqRate: return synth.value(.seqRate)
            case .seqGate: return synth.value(.seqGate)
            case .seqGateVar: return synth.value(.seqGateVar)
            case .transpose: return synth.value(.keyShift)
            case .tempo: return synth.value(.tempo)
            default: return 0
            }
        default: return 0
        }
    }

    /// The parameter a pot really moves: DELAY TIME is the note value while
    /// the delay is tempo-synced.
    private func effective(_ p: Param) -> Param {
        p == .delayTime && synth.intValue(.delaySync) == 1 ? .delayDivision : p
    }

    /// List parameter: the pot range split into equal zones.
    private func list(_ cc: Int, _ p: Param, _ value: Int) {
        let count = p.maxValue + 1
        let current = (Float(synth.intValue(p)) + 0.5) / Float(count) * 128
        pickUp(cc, value, current: current) { position in
            synth.set(p, Float(min(Int(position) * count / 128, p.maxValue)))
            return synth.value(p)
        }
    }

    /// 0...127 parameter.
    private func continuous(_ cc: Int, _ p: Param, _ value: Int) {
        pickUp(cc, value, current: synth.value(p) / Float(p.maxValue) * 127) { position in
            synth.set(p, position / 127 * Float(p.maxValue))
            return synth.value(p)
        }
    }

    private func perform(_ cc: Int, _ control: Perform, _ value: Int) {
        let last = lastPosition[cc]
        // Switch: follows the pot crossing the middle (first touch: its side).
        func switched(_ p: Param) {
            let on = value >= 64
            if let last, (last >= 64) == on { return }
            if (synth.intValue(p) == 1) != on { synth.set(p, on ? 1 : 0) }
        }

        switch control {
        case .arp: switched(.arpOn)
        case .arpRate: list(cc, .arpRate, value)
        case .seq: switched(.seqOn)
        case .seqRate: list(cc, .seqRate, value)
        case .seqGate: continuous(cc, .seqGate, value)
        case .seqGateVar: continuous(cc, .seqGateVar, value)
        case .transpose: list(cc, .keyShift, value)
        case .stutter:
            // Left quarter off, then faster to the right: 1/4, 1/8, 1/16, 1/32.
            if value < 32 {
                if synth.intValue(.stutterOn) == 1 { synth.set(.stutterOn, 0) }
            } else {
                let rate = 3 - min((value - 32) * 4 / 96, 3)
                if synth.intValue(.stutterRate) != rate { synth.set(.stutterRate, Float(rate)) }
                if synth.intValue(.stutterOn) == 0 { synth.set(.stutterOn, 1) }
            }
        case .tempo:
            // 60 ... 187 BPM (TEMPO stores BPM - 40).
            pickUp(cc, value, current: synth.value(.tempo) + 40 - 60) { position in
                synth.set(.tempo, (position + 60 - 40).rounded())
                return synth.value(.tempo)
            }
        case .hold: switched(.arpHold)
        case .rec:
            // Turned past the middle: start a take (once per turn).
            if let last, last < 64, value >= 64, recorder.phase == .idle { recorder.toggleRecord() }
        case .loopsMaster:
            masterLevel = Float(value) / 127
            for i in 0..<LoopPadsModel.padCount { pads.applyLevel(i, master: masterLevel) }
        case .pad1, .pad2, .pad3, .pad4:
            let pad = control.rawValue - Perform.pad1.rawValue
            pads.setLevel(pad, Float(value) / 127, master: masterLevel)
            let playing = engine.loops.isPlaying(pad)
            if value == 0, playing {
                pads.toggle(pad)                    // down to zero: stop
            } else if value > 0, last == 0 || last == nil, !playing, !pads.isEmpty(pad) {
                pads.toggle(pad)                    // up from zero: start on the next bar
            }
        }
    }

    private func watchPreset() {
        let stamp = "\(synth.currentPreset?.number ?? -999)|\(synth.toneName)"
        guard stamp != presetStamp else { return }
        presetStamp = stamp
        pickedUp.removeAll()
    }
}
