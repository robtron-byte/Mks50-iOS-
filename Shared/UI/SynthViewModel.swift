import AudioToolbox
import Combine
import SwiftUI

/// UI state for the synth panel. Values are polled from the engine so changes
/// from any source (host automation, MIDI, SysEx, presets) show up.
final class SynthViewModel: ObservableObject {
    let audioUnit: MKS50AudioUnit

    @Published private(set) var values: [Float]
    @Published private(set) var toneName: String = ""
    @Published private(set) var userPresets: [AUAudioUnitPreset] = []
    @Published var statusMessage: String?

    // Play button ("pad"): one assignable MIDI note instead of a keyboard.
    @Published private(set) var padNote: Int
    @Published private(set) var padSounding = false
    @Published var padLatch = false {
        didSet { if !padLatch && padSounding && !padTouching { padStop() } }
    }
    @Published private(set) var isLearningPadNote = false
    private var padTouching = false
    private var learnStartStamp: UInt32 = 0

    // MIDI CC learn: tap a control, then move a knob on the controller.
    @Published private(set) var ccLearnActive = false
    @Published private(set) var ccLearnTarget: Param?
    @Published private(set) var ccMap: [Int: Int] = [:]
    private var ccLearnStamp: UInt32 = 0
    private static let padNoteKey = "padNote"

    private var parameters: [Int: AUParameter] = [:]
    private var timer: Timer?
    private var statusClear: DispatchWorkItem?

    init(audioUnit: MKS50AudioUnit) {
        self.audioUnit = audioUnit
        values = Array(repeating: 0, count: Param.storageSize)
        let stored = UserDefaults.standard.object(forKey: SynthViewModel.padNoteKey) as? Int
        padNote = min(max(stored ?? 60, 0), 127)
        audioUnit.parameterTree?.allParameters.forEach { parameters[Int($0.address)] = $0 }
        ccMap = audioUnit.ccMap
        poll()
        refreshUserPresets()
        setPolling(true)
    }

    /// The panel only polls the engine while it is on screen.
    func setPolling(_ enabled: Bool) {
        timer?.invalidate()
        timer = nil
        guard enabled else {
            // CCs that arrive while hidden must not be learned on return.
            ccLearnTarget = nil
            return
        }
        ccLearnStamp = audioUnit.engine.lastControlChange
        learnStartStamp = audioUnit.engine.lastNoteOn
        ccMap = audioUnit.ccMap
        poll()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.poll() }
        timer.tolerance = 0.01
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    deinit { timer?.invalidate() }

    private func poll() {
        var changed = false
        var next = values
        for p in Param.allCases {
            let v = audioUnit.engine.parameter(p.address)
            if next[p.rawValue] != v {
                next[p.rawValue] = v
                changed = true
            }
        }
        if changed { values = next }
        if toneName != audioUnit.toneName { toneName = audioUnit.toneName }

        // CC learn: the next incoming control change is assigned to the armed control.
        let ccStamp = audioUnit.engine.lastControlChange
        if ccLearnActive, let target = ccLearnTarget, ccStamp != ccLearnStamp {
            ccLearnStamp = ccStamp
            let cc = Int((ccStamp >> 8) & 0x7F)
            if cc < 120 {
                audioUnit.assignCC(cc, to: target)
                ccMap = audioUnit.ccMap
                ccLearnTarget = nil
                flash("CC \(cc) → \(target.displayName)")
            }
        }

        // MIDI-learn: the next incoming note-on (from any source) becomes the pad note.
        let stamp = audioUnit.engine.lastNoteOn
        if isLearningPadNote, stamp != learnStartStamp {
            let key = Int(stamp & 0x7F)
            isLearningPadNote = false
            if (0...127).contains(key) {
                setPadNote(key)
                flash("Play button: \(SynthViewModel.noteName(key))")
            }
        }
    }

    // MARK: Parameters

    func value(_ p: Param) -> Float { values[p.rawValue] }
    func intValue(_ p: Param) -> Int { Int(values[p.rawValue].rounded()) }

    func set(_ p: Param, _ value: Float) {
        let v = min(max(value, 0), Float(p.maxValue))
        values[p.rawValue] = v
        parameters[p.rawValue]?.value = v
    }

    func binding(_ p: Param) -> Binding<Float> {
        Binding(get: { [unowned self] in self.values[p.rawValue] },
                set: { [unowned self] in self.set(p, $0) })
    }

    var envelope: EnvelopeSettings {
        EnvelopeSettings(t1: SynthEngine.envelopeTime(value(.envT1)), l1: value(.envL1) / 127,
                         t2: SynthEngine.envelopeTime(value(.envT2)), l2: value(.envL2) / 127,
                         t3: SynthEngine.envelopeTime(value(.envT3)), l3: value(.envL3) / 127,
                         t4: SynthEngine.envelopeTime(value(.envT4)))
    }

    // MARK: Play button

    static func noteName(_ note: Int) -> String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        return names[((note % 12) + 12) % 12] + "\(note / 12 - 1)"   // C4 = MIDI 60
    }

    var padNoteName: String { SynthViewModel.noteName(padNote) }

    /// UI MIDI goes out on the receive channel so it is not filtered away.
    private func status(_ base: UInt8) -> UInt8 {
        base | UInt8(max(0, min(15, intValue(.midiChannel) - 1)))
    }

    func padTouchDown() {
        padTouching = true
        if padLatch && padSounding {
            padStop()                     // second tap releases a latched note
        } else if !padSounding {
            audioUnit.sendMIDI(status(0x90), UInt8(padNote), 100)
            padSounding = true
        }
    }

    func padTouchUp() {
        padTouching = false
        if !padLatch { padStop() }
    }

    private func padStop() {
        guard padSounding else { return }
        audioUnit.sendMIDI(status(0x80), UInt8(padNote), 0)
        padSounding = false
    }

    func setPadNote(_ note: Int) {
        let clamped = min(max(note, 0), 127)
        guard clamped != padNote else { return }
        let wasSounding = padSounding
        padStop()
        padNote = clamped
        UserDefaults.standard.set(clamped, forKey: SynthViewModel.padNoteKey)
        if wasSounding && padLatch {
            audioUnit.sendMIDI(status(0x90), UInt8(padNote), 100)
            padSounding = true
        }
    }

    func transposePad(_ semitones: Int) { setPadNote(padNote + semitones) }

    func toggleLearnPadNote() {
        isLearningPadNote.toggle()
        learnStartStamp = audioUnit.engine.lastNoteOn
        if isLearningPadNote { flash("Play a note on your MIDI keyboard") }
    }

    func panic() {
        padStop()
        padTouching = false
        audioUnit.sendMIDI(status(0xB0), 123, 0)
        audioUnit.sendMIDI(status(0xB0), 120, 0)
    }

    // MARK: MIDI CC learn

    func toggleCCLearn() {
        ccLearnActive.toggle()
        ccLearnTarget = nil
        if ccLearnActive { flash("Tap a control, then move a knob on your MIDI controller") }
    }

    func armCCLearn(_ p: Param) {
        guard p != .midiChannel else { return }
        ccLearnTarget = (ccLearnTarget == p) ? nil : p
        ccLearnStamp = audioUnit.engine.lastControlChange
    }

    func ccNumber(for p: Param) -> Int? { ccMap[p.rawValue] }

    func removeCC(for p: Param) {
        audioUnit.removeCC(for: p)
        ccMap = audioUnit.ccMap
        flash("\(p.displayName): CC removed")
    }

    func removeAllCCs() {
        audioUnit.removeAllCCs()
        ccMap = audioUnit.ccMap
        flash("All CC assignments removed")
    }

    // MARK: Chord memory

    func chordDescription(_ slot: Int) -> String {
        ChordMemory.describe(audioUnit.engine.chord(slot))
    }

    /// Stores the keys currently held on a connected MIDI keyboard as the
    /// selected chord.
    func learnChord() {
        // A latched play-button note must not end up in the learned chord.
        let held = audioUnit.engine.heldKeys.filter { !(padSounding && $0 == padNote) }
        guard !held.isEmpty else {
            flash("Hold a chord on your MIDI keyboard, then tap LEARN")
            return
        }
        let chord = ChordMemory.chord(fromHeld: held)
        audioUnit.engine.setChord(intValue(.chordIndex), chord)
        flash("Chord \(intValue(.chordIndex) + 1): \(ChordMemory.describe(chord))")
        objectWillChange.send()
    }

    // MARK: Presets

    var factoryPresets: [AUAudioUnitPreset] { audioUnit.factoryPresets ?? [] }
    var currentPreset: AUAudioUnitPreset? { audioUnit.currentPreset }

    func select(_ preset: AUAudioUnitPreset) {
        audioUnit.currentPreset = preset
        poll()
        objectWillChange.send()
    }

    func stepFactoryPreset(_ delta: Int) {
        let list = factoryPresets
        guard !list.isEmpty else { return }
        let current = audioUnit.currentPreset?.number ?? 0
        let base = current >= 0 ? current : 0
        let next = ((base + delta) % list.count + list.count) % list.count
        select(list[next])
    }

    func rename(_ name: String) {
        audioUnit.toneName = String(name.prefix(10))
        poll()
    }

    func refreshUserPresets() {
        userPresets = audioUnit.userPresets
    }

    func saveUserPreset(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        audioUnit.toneName = String(trimmed.prefix(10)).uppercased()
        let existing = audioUnit.userPresets.first { $0.name == trimmed }
        let preset = AUAudioUnitPreset()
        preset.name = trimmed
        preset.number = existing?.number ?? -(audioUnit.userPresets.map { -$0.number }.max() ?? 0) - 1
        do {
            try audioUnit.saveUserPreset(preset)
            audioUnit.currentPreset = preset
            flash("Saved \"\(trimmed)\"")
        } catch {
            flash("Save failed: \(error.localizedDescription)")
        }
        refreshUserPresets()
    }

    func deleteUserPreset(_ preset: AUAudioUnitPreset) {
        try? audioUnit.deleteUserPreset(preset)
        refreshUserPresets()
    }

    // MARK: SysEx

    /// Handles MKS-50 tone SysEx (APR) and parameter changes (IPR).
    @discardableResult
    func handleSysEx(_ message: [UInt8]) -> Bool {
        guard let parsed = MKS50SysEx.parse(message) else { return false }
        switch parsed {
        case .parameter(let p, let v):
            set(p, Float(v))
        case .tone(let tone):
            audioUnit.apply(tone, includePatch: false)
            flash("Received tone \"\(tone.name)\"")
        }
        poll()
        return true
    }

    /// Imports a .syx file. A single tone is loaded, several tones are stored
    /// as user presets.
    func importSysEx(_ data: Data) {
        let tones = MKS50SysEx.split([UInt8](data)).compactMap { msg -> ToneData? in
            if case .tone(let t)? = MKS50SysEx.parse(msg) { return t }
            return nil
        }
        guard !tones.isEmpty else {
            flash("No MKS-50 tone (APR) data found")
            return
        }
        if tones.count == 1 {
            audioUnit.apply(tones[0], includePatch: false)
            flash("Loaded \"\(tones[0].name)\"")
        } else {
            for tone in tones {
                audioUnit.apply(tone, includePatch: false)
                saveUserPreset(named: tone.name)
            }
            flash("Imported \(tones.count) tones as user presets")
        }
        poll()
    }

    func exportSysEx(channel: Int = 0) -> Data {
        Data(MKS50SysEx.toneAPR(audioUnit.currentToneData, channel: channel))
    }

    func flash(_ message: String) {
        statusMessage = message
        statusClear?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.statusMessage = nil }
        statusClear = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }
}
