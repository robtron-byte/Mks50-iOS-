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
    @Published var keyboardBaseNote: Int = 48
    @Published private(set) var heldNotes: Set<Int> = []
    @Published var statusMessage: String?

    private var parameters: [Int: AUParameter] = [:]
    private var timer: Timer?
    private var statusClear: DispatchWorkItem?

    init(audioUnit: MKS50AudioUnit) {
        self.audioUnit = audioUnit
        values = Array(repeating: 0, count: Param.storageSize)
        audioUnit.parameterTree?.allParameters.forEach { parameters[Int($0.address)] = $0 }
        poll()
        refreshUserPresets()
        setPolling(true)
    }

    /// The panel only polls the engine while it is on screen.
    func setPolling(_ enabled: Bool) {
        timer?.invalidate()
        timer = nil
        guard enabled else { return }
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

    // MARK: Performance

    func noteOn(_ note: Int, velocity: Int) {
        heldNotes.insert(note)
        audioUnit.sendMIDI(0x90, UInt8(note & 0x7F), UInt8(max(1, min(127, velocity))))
    }

    func noteOff(_ note: Int) {
        heldNotes.remove(note)
        audioUnit.sendMIDI(0x80, UInt8(note & 0x7F), 0)
    }

    /// -1...1
    func pitchBend(_ amount: Float) {
        let v = Int((max(-1, min(1, amount)) * 8191).rounded()) + 8192
        audioUnit.sendMIDI(0xE0, UInt8(v & 0x7F), UInt8((v >> 7) & 0x7F))
    }

    /// 0...1
    func modWheel(_ amount: Float) {
        audioUnit.sendMIDI(0xB0, 1, UInt8(max(0, min(127, Int(amount * 127)))))
    }

    /// 0...1 channel aftertouch
    func aftertouch(_ amount: Float) {
        audioUnit.sendMIDI(0xD0, UInt8(max(0, min(127, Int(amount * 127)))), 0)
    }

    func panic() {
        heldNotes.removeAll()
        audioUnit.sendMIDI(0xB0, 123, 0)
        audioUnit.sendMIDI(0xB0, 120, 0)
    }

    func shiftKeyboard(octaves: Int) {
        keyboardBaseNote = max(12, min(96, keyboardBaseNote + octaves * 12))
    }

    // MARK: Chord memory

    func chordDescription(_ slot: Int) -> String {
        ChordMemory.describe(audioUnit.engine.chord(slot))
    }

    /// Stores the currently held on-screen keys as the selected chord.
    func learnChord() {
        guard heldNotes.count >= 1 else {
            flash("Hold keys first, then tap LEARN")
            return
        }
        let chord = ChordMemory.chord(fromHeld: Array(heldNotes))
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
