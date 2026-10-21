import Foundation
import SwiftUI

/// Live control from an Intech Studio Grid EN16 (16 endless encoders with
/// push buttons) on MIDI channel 16. The matching Grid Editor profiles are
/// in Tools/EN16 (one per page, made by Tools/en16_profiles.py).
///
/// Protocol (channel 16): encoders send relative values (binary offset,
/// 64 ± steps), pushes 127 / 0.
/// - Page 1 SOUND: encoder e → CC 32 + e, push → CC 64 + e
/// - Page 2 PERFORM: encoder e → CC 48 + e, push → CC 80 + e
/// - CC 96: the EN16 loaded a page; all LED states are sent again
/// Feedback to the EN16 uses the push CC numbers: 0 off, 64 half
/// (armed / waiting / loaded), 127 on.
///
/// Page 1: the 16 most useful sound parameters; a push resets one to the
/// value of the loaded preset, and its LED shows whether it was changed.
/// Page 2: arp / sequencer, transpose, tempo, stutter, recorder, presets
/// and the four loop pads (encoders: pad levels).
final class GridController: ObservableObject {
    static let enabledKey = "gridEN16Enabled"

    // MARK: Layout (keep in sync with Tools/en16_profiles.py)

    /// Page 1, left to right, top to bottom.
    static let soundPage: [Param] = [
        .vcfCutoff, .vcfResonance, .vcfEnvDepth, .hpfFreq,            // filter
        .lfoRate, .vcfLfoDepth, .dcoLfoDepth, .dcoPwDepth,            // modulation
        .envT1, .envT2, .envL3, .envT4,                               // envelope (attack, decay, sustain, release)
        .delayMix, .delayFeedback, .reverbMix, .distDrive,            // effects
    ]

    private enum Perform: Int {
        case arpRate, arpMode, seqRate, seqGate
        case seqGateVar, transpose, tempo, stutterRate
        case recBars, preset, volume, loopsMaster
        case pad1, pad2, pad3, pad4
    }

    private let synth: SynthViewModel
    private let midi: MIDIManager
    private let recorder: RecorderModel
    private let pads: LoopPadsModel
    private var engine: SynthEngine { synth.audioUnit.engine }

    /// Values of the loaded preset, for "push = back to the preset".
    private var presetValues: [Param: Float] = [:]
    private var presetStamp = ""
    private var sentFeedback: [UInt8: UInt8] = [:]
    private var timer: Timer?
    private var tapTimes: [Date] = []
    /// Discrete parameters move one step per detent; fast turns send bigger
    /// steps, which are limited so a list is never skipped through.
    private var masterLevel: Float = 1

    var enabled: Bool { UserDefaults.standard.object(forKey: GridController.enabledKey) as? Bool ?? true }

    init(synth: SynthViewModel, midi: MIDIManager, recorder: RecorderModel, pads: LoopPadsModel) {
        self.synth = synth
        self.midi = midi
        self.recorder = recorder
        self.pads = pads
        midi.onControllerCC = { [weak self] cc, value in
            // MIDI thread: claim the EN16's CCs, handle them on main.
            guard (32...96).contains(cc),
                  UserDefaults.standard.object(forKey: GridController.enabledKey) as? Bool ?? true else { return false }
            DispatchQueue.main.async { self?.handle(cc: Int(cc), value: Int(value)) }
            return true
        }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    deinit { timer?.invalidate() }

    // MARK: Input (main thread)

    private func handle(cc: Int, value: Int) {
        let delta = value - 64
        switch cc {
        case 32..<48: turnSound(cc - 32, delta)
        case 48..<64: turnPerform(cc - 48, delta)
        case 64..<80: if value > 63 { resetSound(cc - 64) }
        case 80..<96: pushPerform(cc - 80, pressed: value > 63)
        case 96: sentFeedback.removeAll()          // page loaded: resend all LEDs
        default: break
        }
    }

    private func turnSound(_ index: Int, _ delta: Int) {
        guard GridController.soundPage.indices.contains(index) else { return }
        nudge(GridController.soundPage[index], delta)
    }

    /// Relative change of a parameter: 1 per detent for 0...127 ranges,
    /// one step at a time for switches and lists.
    private func nudge(_ p: Param, _ delta: Int) {
        guard delta != 0 else { return }
        let step: Float
        if p.maxValue <= 24 {
            step = delta > 0 ? 1 : -1
        } else {
            step = Float(max(-12, min(12, delta)))
        }
        synth.set(p, synth.value(p) + step)
    }

    private func resetSound(_ index: Int) {
        guard GridController.soundPage.indices.contains(index) else { return }
        let p = GridController.soundPage[index]
        if let v = presetValues[p] { synth.set(p, v) }
    }

    private func turnPerform(_ index: Int, _ delta: Int) {
        guard let control = Perform(rawValue: index), delta != 0 else { return }
        let one = delta > 0 ? 1 : -1
        switch control {
        case .arpRate: nudge(.arpRate, one)
        case .arpMode: nudge(.arpMode, one)
        case .seqRate: nudge(.seqRate, one)
        case .seqGate: nudge(.seqGate, delta)
        case .seqGateVar: nudge(.seqGateVar, delta)
        case .transpose: nudge(.keyShift, one)
        case .tempo:
            if !engine.nudgeFreeTempo(by: one) { nudge(.tempo, one) }
        case .stutterRate: nudge(.stutterRate, one)
        case .recBars:
            guard recorder.phase == .idle else { return }
            recorder.barsIndex = min(max(recorder.barsIndex + one, 0), RecorderModel.barOptions.count - 1)
        case .preset: synth.stepFactoryPreset(one)
        case .volume: nudge(.volume, delta)
        case .loopsMaster:
            masterLevel = min(max(masterLevel + Float(delta) / 64, 0), 1)
            for i in 0..<LoopPadsModel.padCount { pads.applyLevel(i, master: masterLevel) }
        case .pad1, .pad2, .pad3, .pad4:
            let pad = index - Perform.pad1.rawValue
            pads.setLevel(pad, pads.level(pad) + Float(delta) / 64, master: masterLevel)
        }
    }

    private func pushPerform(_ index: Int, pressed: Bool) {
        guard let control = Perform(rawValue: index) else { return }
        // Stutter is momentary: on while held.
        if control == .stutterRate {
            synth.set(.stutterOn, pressed ? 1 : 0)
            return
        }
        guard pressed else { return }
        switch control {
        case .arpRate: synth.set(.arpOn, synth.intValue(.arpOn) == 1 ? 0 : 1)
        case .arpMode: synth.set(.arpHold, synth.intValue(.arpHold) == 1 ? 0 : 1)
        case .seqRate: synth.set(.seqOn, synth.intValue(.seqOn) == 1 ? 0 : 1)
        case .seqGate: synth.generateSequence()
        case .seqGateVar: synth.varySequence()
        case .transpose: synth.set(.keyShift, Float(Param.keyShift.defaultValue))
        case .tempo: tapTempo()
        case .stutterRate: break
        case .recBars: recorder.toggleRecord()
        case .preset: recorder.wrapTails.toggle()
        case .volume: pads.autoPlay.toggle()
        case .loopsMaster: pads.stopAll()
        case .pad1, .pad2, .pad3, .pad4: pads.toggle(index - Perform.pad1.rawValue)
        }
    }

    /// Tap tempo: the average of the last taps (within 2 s of each other).
    private func tapTempo() {
        let now = Date()
        if let last = tapTimes.last, now.timeIntervalSince(last) > 2 { tapTimes.removeAll() }
        tapTimes.append(now)
        tapTimes = Array(tapTimes.suffix(5))
        guard tapTimes.count >= 2, let first = tapTimes.first else { return }
        let beat = now.timeIntervalSince(first) / Double(tapTimes.count - 1)
        let bpm = (60 / beat).rounded()
        guard (40...240).contains(bpm) else { return }
        synth.set(.tempo, Float(bpm - 40))
        synth.flash("Tap tempo \(Int(bpm)) BPM")
    }

    // MARK: Feedback (main thread, 10 per second)

    private func tick() {
        guard enabled else { return }
        snapshotPresetIfChanged()
        var state: [UInt8: UInt8] = [:]
        // Page 1: lit while a parameter differs from the preset.
        for (i, p) in GridController.soundPage.enumerated() {
            let changed = presetValues[p].map { abs($0 - synth.value(p)) > 0.5 } ?? false
            state[UInt8(64 + i)] = changed ? 127 : 0
        }
        // Page 2.
        func set(_ c: Perform, _ v: UInt8) { state[UInt8(80 + c.rawValue)] = v }
        set(.arpRate, synth.intValue(.arpOn) == 1 ? 127 : 0)
        set(.arpMode, synth.intValue(.arpHold) == 1 ? 127 : 0)
        set(.seqRate, synth.intValue(.seqOn) == 1 ? 127 : 0)
        set(.seqGate, 0)
        set(.seqGateVar, 0)
        set(.transpose, synth.intValue(.keyShift) != Param.keyShift.defaultValue ? 127 : 0)
        set(.tempo, 0)
        set(.stutterRate, synth.intValue(.stutterOn) == 1 ? 127 : 0)
        switch recorder.phase {
        case .idle: set(.recBars, 0)
        case .armed: set(.recBars, 64)
        default: set(.recBars, 127)
        }
        set(.preset, recorder.wrapTails ? 127 : 0)
        set(.volume, pads.autoPlay ? 127 : 0)
        let loops = engine.loops
        set(.loopsMaster, loops.soundingMask != 0 ? 127 : 0)
        for pad in 0..<LoopPadsModel.padCount {
            let bit = 1 << pad
            let v: UInt8 = loops.soundingMask & bit != 0 ? 127
                : (loops.pendingMask & bit != 0 || loops.isReserved(pad)) ? 64
                : pads.isEmpty(pad) ? 0 : 20
            set(Perform(rawValue: Perform.pad1.rawValue + pad)!, v)
        }
        let changes = state.filter { sentFeedback[$0.key] != $0.value }
        guard !changes.isEmpty else { return }
        midi.sendControllerFeedback(changes.sorted { $0.key < $1.key }.map { (cc: $0.key, value: $0.value) })
        for (k, v) in changes { sentFeedback[k] = v }
    }

    /// A new preset was loaded: remember its values for the reset pushes.
    private func snapshotPresetIfChanged() {
        let stamp = "\(synth.currentPreset?.number ?? -999)|\(synth.toneName)"
        guard stamp != presetStamp else { return }
        presetStamp = stamp
        for p in GridController.soundPage { presetValues[p] = synth.value(p) }
    }
}
