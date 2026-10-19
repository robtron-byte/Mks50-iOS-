import AudioToolbox
import Combine
import SwiftUI

/// One observable value per parameter. A control observes only its own
/// parameter, so turning a knob or tapping a button re-renders that control
/// alone instead of the whole panel.
final class ParamModel: ObservableObject {
    let param: Param
    @Published fileprivate(set) var value: Float

    init(_ param: Param, value: Float) {
        self.param = param
        self.value = value
    }
}

/// MIDI CC learn state, separate so only the learn overlays observe it.
final class CCLearnState: ObservableObject {
    @Published fileprivate(set) var active = false
    @Published fileprivate(set) var target: Param?
    @Published fileprivate(set) var map: [Int: Int] = [:]
}

/// UI state for the synth panel. Values are polled from the engine so changes
/// from any source (host automation, MIDI, SysEx, presets) show up.
final class SynthViewModel: ObservableObject {
    let audioUnit: MKS50AudioUnit

    /// Per-parameter observables, indexed by `Param.rawValue`.
    private let paramModels: [ParamModel?]
    let learn = CCLearnState()
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
    var ccLearnActive: Bool { learn.active }
    var ccLearnTarget: Param? { learn.target }
    private var ccLearnStamp: UInt32 = 0
    private static let padNoteKey = "padNote"

    private var parameters: [Int: AUParameter] = [:]
    private var timer: Timer?
    private var statusClear: DispatchWorkItem?

    init(audioUnit: MKS50AudioUnit) {
        self.audioUnit = audioUnit
        var models = [ParamModel?](repeating: nil, count: Param.storageSize)
        for p in Param.allCases {
            models[p.rawValue] = ParamModel(p, value: audioUnit.engine.parameter(p.address))
        }
        paramModels = models
        let stored = UserDefaults.standard.object(forKey: SynthViewModel.padNoteKey) as? Int
        padNote = min(max(stored ?? 60, 0), 127)
        audioUnit.parameterTree?.allParameters.forEach { parameters[Int($0.address)] = $0 }
        learn.map = audioUnit.ccMap
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
            learn.target = nil
            return
        }
        ccLearnStamp = audioUnit.engine.lastControlChange
        learnStartStamp = audioUnit.engine.lastNoteOn
        learn.map = audioUnit.ccMap
        poll()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.poll() }
        timer.tolerance = 0.01
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    deinit { timer?.invalidate() }

    private func poll() {
        // Only parameters whose value actually changed publish (and redraw).
        for case let model? in paramModels {
            let v = audioUnit.engine.parameter(model.param.address)
            if model.value != v { model.value = v }
        }
        if toneName != audioUnit.toneName { toneName = audioUnit.toneName }

        // CC learn: the next incoming control change is assigned to the armed control.
        let ccStamp = audioUnit.engine.lastControlChange
        if learn.active, let target = learn.target, ccStamp != ccLearnStamp {
            ccLearnStamp = ccStamp
            let cc = Int((ccStamp >> 8) & 0x7F)
            if cc < 120 {
                audioUnit.assignCC(cc, to: target)
                learn.map = audioUnit.ccMap
                learn.target = nil
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

    func model(_ p: Param) -> ParamModel {
        paramModels[p.rawValue]!   // created for every Param case in init
    }

    func value(_ p: Param) -> Float { model(p).value }
    func intValue(_ p: Param) -> Int { Int(model(p).value.rounded()) }

    func set(_ p: Param, _ value: Float) {
        let v = min(max(value, 0), Float(p.maxValue))
        // Switching on an empty sequencer: start with a fresh pattern.
        if p == .seqOn && v >= 0.5 && intValue(.seqOn) == 0 && sequencerSteps().allSatisfy({ $0 == 0 }) {
            generateSequence()
        }
        let m = model(p)
        if m.value != v { m.value = v }
        parameters[p.rawValue]?.value = v
    }

    func binding(_ p: Param) -> Binding<Float> {
        let m = model(p)
        return Binding(get: { m.value },
                       set: { [unowned self] in self.set(p, $0) })
    }

    var envelope: EnvelopeSettings {
        EnvelopeSettings(t1: SynthEngine.envelopeTime(value(.envT1), segment: 1), l1: value(.envL1) / 127,
                         t2: SynthEngine.envelopeTime(value(.envT2), segment: 2), l2: value(.envL2) / 127,
                         t3: SynthEngine.envelopeTime(value(.envT3), segment: 3), l3: value(.envL3) / 127,
                         t4: SynthEngine.envelopeTime(value(.envT4), segment: 4))
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
        let oldNote = padNote
        // A held (finger on the pad) or latched note moves to the new pitch.
        let keepSounding = padSounding && (padLatch || padTouching)
        padNote = clamped
        UserDefaults.standard.set(clamped, forKey: SynthViewModel.padNoteKey)
        guard padSounding else { return }
        if keepSounding {
            // New note first, then release the old one: played legato, so
            // mono modes bind the notes (and portamento AUTO glides).
            audioUnit.sendMIDI(status(0x90), UInt8(padNote), 100)
            audioUnit.sendMIDI(status(0x80), UInt8(oldNote), 0)
        } else {
            audioUnit.sendMIDI(status(0x80), UInt8(oldNote), 0)
            padSounding = false
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
        learn.active.toggle()
        learn.target = nil
        objectWillChange.send()   // toolbar icon + learn bar
        if learn.active { flash("Tap a control, then move a knob on your MIDI controller") }
    }

    func armCCLearn(_ p: Param) {
        guard p != .midiChannel else { return }
        learn.target = (learn.target == p) ? nil : p
        objectWillChange.send()   // learn bar text
        ccLearnStamp = audioUnit.engine.lastControlChange
    }

    func ccNumber(for p: Param) -> Int? { learn.map[p.rawValue] }

    func removeCC(for p: Param) {
        audioUnit.removeCC(for: p)
        learn.map = audioUnit.ccMap
        objectWillChange.send()   // settings list
        flash("\(p.displayName): CC removed")
    }

    func removeAllCCs() {
        audioUnit.removeAllCCs()
        learn.map = audioUnit.ccMap
        objectWillChange.send()   // settings list
        flash("All CC assignments removed")
    }

    // MARK: Chord memory

    func chordDescription(_ slot: Int) -> String {
        ChordMemory.describe(audioUnit.engine.chord(slot))
    }

    // MARK: Step sequencer

    func sequencerSteps() -> [Int] {
        (0..<StepSequencer.maxSteps).map { intValue(Param.seqStep($0)) }
    }

    private func setSequencerSteps(_ raw: [Int]) {
        for (i, v) in raw.prefix(StepSequencer.maxSteps).enumerated() { set(Param.seqStep(i), Float(v)) }
    }

    /// New random pattern in the selected style.
    func generateSequence() {
        let style = intValue(.seqStyle)
        setSequencerSteps(SequenceGenerator.generate(style: style))
        set(.seqLength, Float(StepSequencer.maxSteps - 1))
        flash("New \(SequenceGenerator.styleNames[min(style, SequenceGenerator.styleNames.count - 1)]) sequence")
    }

    /// Small variation of the current pattern.
    func varySequence() {
        setSequencerSteps(SequenceGenerator.vary(sequencerSteps(), style: intValue(.seqStyle)))
    }

    /// Tap on a step: rest ↔ note (root).
    func toggleStep(_ i: Int) {
        let p = Param.seqStep(i)
        set(p, SeqStep(raw: intValue(p)) == nil ? Float(SeqStep(note: 0).raw) : 0)
    }

    /// Step up/down in semitones.
    func transposeStep(_ i: Int, by delta: Int) {
        let p = Param.seqStep(i)
        guard let s = SeqStep(raw: intValue(p)) else { return }
        set(p, Float(SeqStep(note: s.note + delta, accent: s.accent, tie: s.tie).raw))
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

    struct PresetGroup: Identifiable {
        let category: PresetCategory
        let presets: [AUAudioUnitPreset]
        var id: PresetCategory { category }
    }

    /// Factory presets grouped by category, in browsing order.
    var factoryPresetGroups: [PresetGroup] {
        let presets = factoryPresets
        return PresetCategory.allCases.compactMap { category in
            let members = presets.filter { self.category(of: $0) == category }
            return members.isEmpty ? nil : PresetGroup(category: category, presets: members)
        }
    }

    func category(of preset: AUAudioUnitPreset?) -> PresetCategory? {
        guard let n = preset?.number, n >= 0, n < FactoryPresets.all.count else { return nil }
        return FactoryPresets.all[n].category
    }

    /// Short category label for the LCD ("USER" for user presets).
    var currentCategoryLabel: String {
        if let category = category(of: currentPreset) { return category.short }
        return (currentPreset?.number ?? 0) < 0 ? "USER" : ""
    }
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

    /// One-tap save under a generated name: the sound's name plus the next
    /// free number ("SEQ KRA 01"), never overwriting an existing preset.
    func quickSaveUserPreset() {
        var base = toneName.trimmingCharacters(in: .whitespaces).uppercased()
        if let range = base.range(of: #" \d{2}$"#, options: .regularExpression) {
            base.removeSubrange(range)      // re-saving "BASS 01" gives "BASS 02"
        }
        if base.isEmpty { base = "MY SOUND" }
        base = String(base.prefix(7)).trimmingCharacters(in: .whitespaces)
        let taken = Set(audioUnit.userPresets.map(\.name))
        guard let name = (1...99).lazy.map({ String(format: "%@ %02d", base, $0) })
            .first(where: { !taken.contains($0) }) else {
            flash("No free name for \"\(base)\"")
            return
        }
        saveUserPreset(named: name)
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
