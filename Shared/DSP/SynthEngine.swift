import Foundation
import AudioToolbox
import os

/// One synthesizer voice (DCO → HPF → VCF → VCA).
struct Voice {
    /// The key that owns this voice (for note-off matching).
    var key: Int = -1
    /// Sounding note number (key + key shift + chord offset).
    var note: Int = -1
    var velocity: Float = 1
    var gate = false
    var sustained = false
    var active = false
    var age: UInt64 = 0

    var pitch: Float = 60
    var targetPitch: Float = 60
    var lfoFade: Float = 1
    var gateAmp: Float = 0

    /// Unison position -1...1 (0 = centre / not in unison).
    var unisonSpread: Float = 0
    var isUnison = false

    /// "Voice calibration": fixed per-voice deviations (-1...1) and a slow
    /// random wander, like component tolerances on the analog boards.
    var driftPitch: Float
    var driftCutoff: Float
    var driftEnvelope: Float
    var wander: Float = 0
    var rng: XorShift32

    var dco: DCO
    var env = Envelope()
    var filter = LadderFilter()
    var hpf = BiquadState()
    var hpfSweep = BiquadState()

    init(seed: UInt32) {
        dco = DCO(seed: seed)
        var random = XorShift32(seed: seed &* 2_654_435_761)
        driftPitch = random.next()
        driftCutoff = random.next()
        driftEnvelope = random.next()
        rng = random
    }
}

/// Real-time safe MKS-50 style synthesizer engine.
///
/// The engine owns a flat parameter array addressed by `Param.rawValue` that
/// is written from the parameter tree (main thread) and read on the audio
/// thread. All memory is allocated up front; `render` never allocates.
final class SynthEngine {
    static let maxVoices = 6
    private static let controlInterval = 16
    private static let queueCapacity = 512

    let params: UnsafeMutablePointer<Float>
    private let voices: UnsafeMutablePointer<Voice>

    private var sampleRate: Float = 44100
    private var bufferCapacity = 0
    private var mixLeft: UnsafeMutablePointer<Float>
    private var mixRight: UnsafeMutablePointer<Float>
    private let chorus = Chorus()
    private let delay = StereoDelay()
    private let reverb = Reverb()
    private let distortion = AcidDistortion()

    /// Tempo reported by the AU host (BPM), 0 = none (use the TEMPO parameter).
    var hostTempo: Double = 0
    /// Host beat position at the start of the current render cycle, -1 = none.
    /// Lets a tempo-synced LFO lock its phase to the song.
    var hostBeatPosition: Double = -1
    /// Samples rendered since the start of the current render cycle.
    private var cycleSamples = 0
    /// Free-running beat clock (used when there is no host transport, e.g. in
    /// the standalone app): drives tempo-synced LFOs and the loop recorder.
    private var internalBeat: Double = 0
    /// Beat position at the first frame of the current `render` call.
    private var renderStartBeat: Double = 0
    /// Frames rendered so far within the current `render` call.
    private var renderFrameOffset = 0

    /// Bar-accurate loop recorder (fed with the final output).
    let recorder = LoopRecorder()

    /// Last applied chord (slot + notes) in CHORD mode, -1: not in CHORD mode.
    private var lastChordSignature = -1

    /// Tempo-synced arpeggiator; plays through the normal note path.
    private var arp = Arpeggiator()
    /// True while held keys are collected by the arp / sequencer instead of
    /// being played directly.
    private var arpWasOn = false
    private var arpHoldWasOn = false
    /// 16-step sequencer; uses the arp's key collection (last key = root).
    private var seq = StepSequencer()
    private var seqWasOn = false
    /// Next note-on is a tied sequencer step: no envelope retrigger.
    private var legatoNote = false

    /// Arp or sequencer switched on.
    private var collectorOn: Bool { pi(.arpOn) == 1 || pi(.seqOn) == 1 }

    /// Step currently played by the sequencer (-1: stopped), for the UI.
    var sequencerStep: Int { seq.currentStep }

    /// Call once per render cycle, before rendering.
    func beginRenderCycle(tempo: Double, beatPosition: Double) {
        hostTempo = tempo
        hostBeatPosition = beatPosition
        cycleSamples = 0
    }

    var currentSampleRate: Double { Double(sampleRate) }
    /// True while the loop recorder captures its tail (no new notes).
    private var recorderTailGate = false

    @inline(__always) private var beatsPerFrame: Double {
        max(tempoBPM, 20) / 60 / Double(sampleRate)
    }

    // Performance controllers
    private var bend: Float = 0
    private var modWheel: Float = 0
    private var aftertouch: Float = 0
    private var sustainPedal = false

    // Global modulation state
    private var lfoPhase: Float = 0
    private var lfoValue: Float = 0
    private var lfoRandom = XorShift32(seed: 0x51F1_5EED)
    private var lfoHeld: Float = 0          // sample & hold value
    private var lfoFrom: Float = 0          // smooth random: segment start
    private var lfoTo: Float = 0            // smooth random: segment end
    private var pwmPhase: Float = 0
    private var noteCounter: UInt64 = 0
    private var lastPitch: Float = 60
    private var lastKeyMode = -1

    // Per-block derived settings
    private var dcoSettings = DCOSettings()
    private var envSettings = EnvelopeSettings()
    private var cutoffSmoothed: Float = 127
    private var volumeSmoothed: Float = 0.6
    private var hpfCoefficients = BiquadCoefficients.bypass
    private var hpfMode = -1
    /// Continuous high-pass (HPF FREQ knob), in addition to the 4 hardware steps.
    private var hpfSweepCoefficients = BiquadCoefficients.bypass
    private var hpfSweepSmoothed: Float = 0
    private var hpfSweepActive = false
    private var dcXL: Float = 0, dcYL: Float = 0
    private var dcXR: Float = 0, dcYR: Float = 0

    // Mono / chord / unison key stack
    private let keyStack: UnsafeMutablePointer<Int>
    private var keyStackCount = 0
    private static let keyStackCapacity = 32

    // Chord memory
    let chordNotes: UnsafeMutablePointer<Int8>
    let chordSizes: UnsafeMutablePointer<Int8>

    // Thread-safe inbox for MIDI coming from UI / CoreMIDI threads.
    private let queueLock: UnsafeMutablePointer<os_unfair_lock>
    private let queue: UnsafeMutablePointer<UInt32>
    private var queueCount = 0

    /// Set by the audio thread when a program change arrives; consumed on main.
    var pendingProgramChange: Int32 = -1

    /// Keys currently held by any source (1 = down), for chord LEARN.
    /// Written on the audio thread, read on main.
    private let heldKeyFlags: UnsafeMutablePointer<UInt8>
    /// Last note-on, packed as `counter << 8 | key` in one word so the UI
    /// thread always reads a consistent key / counter pair ("MIDI learn").
    private(set) var lastNoteOn: UInt32 = 0
    private var noteOnCounter: UInt32 = 0

    /// MIDI CC → parameter address (-1 = not mapped). Written on main
    /// (single aligned Int16 stores), read on the audio thread.
    private let ccTargets: UnsafeMutablePointer<Int16>
    /// Last control change, packed as `counter << 16 | cc << 8 | value`
    /// so the UI can read a consistent snapshot for CC learn.
    private(set) var lastControlChange: UInt32 = 0
    private var ccCounter: UInt32 = 0
    /// Set when a learned CC changed a parameter; the AU mirrors those
    /// values into its parameter tree on main so hosts see them.
    var ccParametersDirty = false

    init() {
        let capacity = 4096
        params = .allocate(capacity: Param.storageSize)
        params.initialize(repeating: 0, count: Param.storageSize)

        voices = .allocate(capacity: SynthEngine.maxVoices)
        for i in 0..<SynthEngine.maxVoices {
            (voices + i).initialize(to: Voice(seed: UInt32(0x1234_5678 &+ i &* 7919)))
        }

        bufferCapacity = capacity
        mixLeft = .allocate(capacity: capacity)
        mixRight = .allocate(capacity: capacity)
        mixLeft.initialize(repeating: 0, count: capacity)
        mixRight.initialize(repeating: 0, count: capacity)

        keyStack = .allocate(capacity: SynthEngine.keyStackCapacity)
        keyStack.initialize(repeating: 0, count: SynthEngine.keyStackCapacity)

        chordNotes = .allocate(capacity: ChordMemory.slots * ChordMemory.maxNotes)
        chordNotes.initialize(repeating: 0, count: ChordMemory.slots * ChordMemory.maxNotes)
        chordSizes = .allocate(capacity: ChordMemory.slots)
        chordSizes.initialize(repeating: 1, count: ChordMemory.slots)

        queueLock = .allocate(capacity: 1)
        queueLock.initialize(to: os_unfair_lock())
        queue = .allocate(capacity: SynthEngine.queueCapacity)
        queue.initialize(repeating: 0, count: SynthEngine.queueCapacity)

        heldKeyFlags = .allocate(capacity: 128)
        heldKeyFlags.initialize(repeating: 0, count: 128)
        ccTargets = .allocate(capacity: 128)
        ccTargets.initialize(repeating: -1, count: 128)

        for p in Param.allCases { params[p.rawValue] = Float(p.defaultValue) }
        for (i, chord) in ChordMemory.defaultChords.enumerated() { setChord(i, chord) }
        prepare(sampleRate: 44100, maximumFrames: capacity)
    }

    deinit {
        params.deallocate()
        voices.deinitialize(count: SynthEngine.maxVoices)
        voices.deallocate()
        mixLeft.deallocate()
        mixRight.deallocate()
        keyStack.deallocate()
        chordNotes.deallocate()
        chordSizes.deallocate()
        queueLock.deallocate()
        queue.deallocate()
        heldKeyFlags.deallocate()
        ccTargets.deallocate()
    }

    // MARK: Setup (not real-time)

    func prepare(sampleRate: Double, maximumFrames: Int) {
        HardwareCurves.warmUp()
        self.sampleRate = Float(sampleRate)
        if maximumFrames > bufferCapacity {
            mixLeft.deallocate()
            mixRight.deallocate()
            bufferCapacity = maximumFrames
            mixLeft = .allocate(capacity: bufferCapacity)
            mixRight = .allocate(capacity: bufferCapacity)
            mixLeft.initialize(repeating: 0, count: bufferCapacity)
            mixRight.initialize(repeating: 0, count: bufferCapacity)
        }
        for i in 0..<SynthEngine.maxVoices {
            voices[i].env.sampleRate = self.sampleRate
        }
        hpfMode = -1
        _ = LFOShape.divisionQuarters.count   // initialise static table off the audio thread
        chorus.prepare(sampleRate: self.sampleRate)
        delay.prepare(sampleRate: self.sampleRate)
        reverb.prepare(sampleRate: self.sampleRate)
        distortion.prepare(sampleRate: self.sampleRate)
        reset()
    }

    func reset() {
        for i in 0..<SynthEngine.maxVoices {
            voices[i].active = false
            voices[i].gate = false
            voices[i].sustained = false
            voices[i].env.reset()
            voices[i].filter.reset()
            voices[i].hpf.reset()
            voices[i].hpfSweep.reset()
            voices[i].gateAmp = 0
        }
        keyStackCount = 0
        arp.reset()
        _ = seq.stop()
        heldKeyFlags.update(repeating: 0, count: 128)
        chorus.reset()
        delay.reset()
        reverb.reset()
        distortion.reset()
        dcXL = 0; dcYL = 0; dcXR = 0; dcYR = 0
    }

    // MARK: Parameters

    @inline(__always) func setParameter(_ address: AUParameterAddress, _ value: AUValue) {
        guard address < AUParameterAddress(Param.storageSize) else { return }
        let maxValue = Param(rawValue: Int(address))?.maxValue ?? 127
        params[Int(address)] = min(max(value, 0), AUValue(maxValue))
    }

    @inline(__always) func parameter(_ address: AUParameterAddress) -> AUValue {
        guard address < AUParameterAddress(Param.storageSize) else { return 0 }
        return params[Int(address)]
    }

    @inline(__always) private func p(_ param: Param) -> Float { params[param.rawValue] }
    @inline(__always) private func pi(_ param: Param) -> Int { Int(params[param.rawValue].rounded()) }

    func setChord(_ slot: Int, _ notes: [Int]) {
        guard (0..<ChordMemory.slots).contains(slot), !notes.isEmpty else { return }
        let count = min(notes.count, ChordMemory.maxNotes)
        for j in 0..<count { chordNotes[slot * ChordMemory.maxNotes + j] = Int8(clamping: notes[j]) }
        chordSizes[slot] = Int8(count)
    }

    /// Assigns a MIDI CC (0...119) to a parameter, or clears it with `nil`.
    func setCCTarget(_ cc: Int, _ param: Param?) {
        guard (0..<120).contains(cc) else { return }
        ccTargets[cc] = Int16(param?.rawValue ?? -1)
    }

    /// Keys currently held (main thread snapshot).
    var heldKeys: [Int] {
        (0..<128).filter { heldKeyFlags[$0] != 0 }
    }

    func chord(_ slot: Int) -> [Int] {
        guard (0..<ChordMemory.slots).contains(slot) else { return [0] }
        return (0..<Int(chordSizes[slot])).map { Int(chordNotes[slot * ChordMemory.maxNotes + $0]) }
    }

    // MARK: MIDI input

    /// Thread-safe entry point for MIDI from non-audio threads.
    func enqueueMIDI(_ status: UInt8, _ data1: UInt8, _ data2: UInt8) {
        os_unfair_lock_lock(queueLock)
        if queueCount < SynthEngine.queueCapacity {
            queue[queueCount] = UInt32(status) << 16 | UInt32(data1) << 8 | UInt32(data2)
            queueCount += 1
        }
        os_unfair_lock_unlock(queueLock)
    }

    /// Audio thread: applies queued MIDI without ever blocking.
    func drainMIDIQueue() {
        guard os_unfair_lock_trylock(queueLock) else { return }
        for i in 0..<queueCount {
            let m = queue[i]
            handleMIDI(UInt8((m >> 16) & 0xFF), UInt8((m >> 8) & 0xFF), UInt8(m & 0xFF))
        }
        queueCount = 0
        os_unfair_lock_unlock(queueLock)
    }

    /// Audio thread: handles one MIDI 1.0 channel message.
    func handleMIDI(_ status: UInt8, _ data1: UInt8, _ data2: UInt8) {
        guard status >= 0x80, status < 0xF0 else { return }
        let channel = Int(status & 0x0F)
        let wanted = pi(.midiChannel)
        if wanted > 0 && channel != wanted - 1 { return }

        let d1 = Int(data1 & 0x7F)
        let d2 = Int(data2 & 0x7F)
        switch status & 0xF0 {
        case 0x90 where d2 > 0:
            heldKeyFlags[d1] = 1
            noteOnCounter &+= 1
            lastNoteOn = (noteOnCounter << 8) | UInt32(d1)
            if collectorOn {
                arpKeyDown(d1, velocity: d2)
            } else {
                noteOn(d1, velocity: d2)
            }
        case 0x80, 0x90:
            heldKeyFlags[d1] = 0
            if collectorOn && arpWasOn {
                if pi(.arpHold) == 0 { arp.remove(d1) }
            } else {
                noteOff(d1)
            }
        case 0xB0:
            controlChange(d1, d2)
        case 0xD0:
            aftertouch = Float(d1) / 127
        case 0xE0:
            bend = Float((d2 << 7 | d1) - 8192) / 8192
        case 0xC0:
            pendingProgramChange = Int32(d1)
        default:
            break
        }
    }

    private func controlChange(_ cc: Int, _ value: Int) {
        ccCounter &+= 1
        lastControlChange = (ccCounter << 16) | UInt32(cc) << 8 | UInt32(value)

        // User assignments (MIDI learn) take priority over the fixed CCs;
        // channel mode messages 120...127 can never be reassigned.
        if cc < 120 {
            let target = Int(ccTargets[cc])
            if target >= 0, let p = Param(rawValue: target) {
                let maxValue = Float(p.maxValue)
                var v = Float(value) / 127 * maxValue
                if p.maxValue < 127 { v = v.rounded() }
                params[target] = v
                ccParametersDirty = true
                return
            }
        }

        switch cc {
        case 1:
            modWheel = Float(value) / 127
        case 5:
            params[Param.portaTime.rawValue] = Float(value)
        case 7:
            params[Param.volume.rawValue] = Float(value)
        case 64:
            let down = value >= 64
            if sustainPedal && !down { releaseSustained() }
            sustainPedal = down
        case 65:
            params[Param.portaSwitch.rawValue] = value >= 64 ? 1 : 0
        case 120:
            reset()
        case 121:
            bend = 0; modWheel = 0; aftertouch = 0
            if sustainPedal { sustainPedal = false; releaseSustained() }
        case 123:
            heldKeyFlags.update(repeating: 0, count: 128)
            allNotesOff()
            arp.reset()
            _ = seq.stop()
        default:
            break
        }
    }

    // MARK: Voice allocation

    private var keyShift: Int { pi(.keyShift) - 12 }
    /// PORTA SW: 0 OFF, 1 ON (always glide), 2 AUTO (glide only between
    /// overlapping, legato notes).
    private var portaMode: Int { pi(.portaSwitch) }
    /// Glide decision for the note event being handled right now.
    private var glideThisNote = false
    private var portamentoOn: Bool { glideThisNote }

    /// Chord slot (-1 = none) and unison flag of the current key mode.
    private var group: (slot: Int, unison: Bool) {
        switch pi(.keyMode) {
        case 1:
            // The arp plays the chord tones one after another, monophonic.
            if arpWasOn && !seqWasOn { return (-1, false) }
            return (min(max(pi(.chordIndex), 0), ChordMemory.slots - 1), false)
        case 3: return (-1, true)
        default: return (-1, false)
        }
    }

    /// A key mode switch releases everything (as the hardware does). Called
    /// before every note event and every control block, so a mode change
    /// made while the engine is idle never cuts off the next note.
    private func syncKeyMode() {
        let keyMode = pi(.keyMode)
        if keyMode != lastKeyMode {
            if lastKeyMode >= 0 { allNotesOff() }
            lastKeyMode = keyMode
        }
    }

    /// CHORD mode: turning the CHORD knob (or learning a new chord) retunes
    /// the held chord immediately instead of waiting for the next key.
    private func syncChord() {
        glideThisNote = portaMode != 0
        let (slot, unison) = group
        guard slot >= 0, !unison else {
            lastChordSignature = -1
            return
        }
        let size = groupSize(slot, false)
        var signature = slot &* 131 &+ size
        for j in 0..<size { signature = signature &* 31 &+ groupOffset(slot, j) }
        guard signature != lastChordSignature else { return }
        let first = lastChordSignature == -1
        lastChordSignature = signature
        guard !first, keyStackCount > 0 else { return }

        var velocity: Float = -1
        for j in 0..<SynthEngine.maxVoices where voices[j].gate { velocity = voices[j].velocity }
        guard velocity >= 0 else { return }

        let key = keyStack[keyStackCount - 1]
        let base = Float(key + keyShift)
        for j in 0..<SynthEngine.maxVoices {
            if j < size {
                let note = key + keyShift + groupOffset(slot, j)
                if voices[j].active && voices[j].gate {
                    // Same envelope, new pitch (glides with portamento on).
                    voices[j].note = note
                    voices[j].targetPitch = Float(note)
                    if !portamentoOn { voices[j].pitch = Float(note) }
                } else {
                    startVoice(j, key: key, note: note, velocity: velocity)
                }
            } else if voices[j].gate {
                releaseVoice(j)
            }
        }
        lastPitch = base
    }

    /// Envelope base times / levels from the current parameters. Also called
    /// on every note event: while the engine is idle no control blocks run,
    /// and a note must never start with stale T1 / L1 values.
    private func refreshEnvelopeSettings() {
        envSettings.t1 = SynthEngine.envelopeTime(p(.envT1), segment: 1)
        envSettings.t2 = SynthEngine.envelopeTime(p(.envT2), segment: 2)
        envSettings.t3 = SynthEngine.envelopeTime(p(.envT3), segment: 3)
        envSettings.t4 = SynthEngine.envelopeTime(p(.envT4), segment: 4)
        envSettings.l1 = p(.envL1) / 127
        envSettings.l2 = p(.envL2) / 127
        envSettings.l3 = p(.envL3) / 127
    }

    private func noteOn(_ key: Int, velocity: Int) {
        // Loop recorder tail: only the decay of the loop may ring on.
        guard !recorderTailGate else { return }
        syncKeyMode()
        refreshEnvelopeSettings()
        recorder.noteTrigger = true
        var legato = false
        for i in 0..<SynthEngine.maxVoices where voices[i].gate { legato = true }
        glideThisNote = portaMode == 1 || (portaMode == 2 && legato)
        if pi(.lfoKeySync) == 1 {
            var anyGate = false
            for i in 0..<SynthEngine.maxVoices where voices[i].gate { anyGate = true }
            if !anyGate {
                lfoPhase = 0
                lfoHeld = lfoRandom.next()
                lfoFrom = lfoTo
            }
        }
        let vel = Float(velocity) / 127
        if pi(.keyMode) == 0 {
            polyNoteOn(key, vel)
        } else {
            groupNoteOn(key, vel)
        }
    }

    private func noteOff(_ key: Int) {
        syncKeyMode()
        refreshEnvelopeSettings()
        // Falling back to a still-held key is legato: AUTO glides too.
        glideThisNote = portaMode != 0
        if pi(.keyMode) == 0 {
            for i in 0..<SynthEngine.maxVoices where voices[i].active && voices[i].gate && voices[i].key == key {
                if sustainPedal { voices[i].sustained = true } else { releaseVoice(i) }
            }
        } else {
            groupNoteOff(key)
        }
    }

    private func polyNoteOn(_ key: Int, _ vel: Float) {
        var index = -1
        for i in 0..<SynthEngine.maxVoices where voices[i].active && voices[i].key == key {
            index = i
            break
        }
        if index < 0 { index = findVoice() }
        voices[index].unisonSpread = 0
        voices[index].isUnison = false
        startVoice(index, key: key, note: key + keyShift, velocity: vel)
    }

    /// Free voice first, then the oldest released voice, then the oldest voice.
    private func findVoice() -> Int {
        for i in 0..<SynthEngine.maxVoices where !voices[i].active { return i }
        var best = -1
        var bestAge = UInt64.max
        for i in 0..<SynthEngine.maxVoices where !voices[i].gate && voices[i].age < bestAge {
            best = i
            bestAge = voices[i].age
        }
        if best >= 0 { return best }
        for i in 0..<SynthEngine.maxVoices where voices[i].age < bestAge {
            best = i
            bestAge = voices[i].age
        }
        return max(best, 0)
    }

    private func startVoice(_ i: Int, key: Int, note: Int, velocity: Float) {
        let wasActive = voices[i].active
        noteCounter &+= 1
        voices[i].key = key
        voices[i].note = note
        voices[i].velocity = velocity
        voices[i].gate = true
        voices[i].sustained = false
        voices[i].age = noteCounter
        voices[i].targetPitch = Float(note)
        voices[i].pitch = portamentoOn ? lastPitch : Float(note)
        voices[i].lfoFade = p(.lfoDelay) > 0 ? 0 : 1
        if !wasActive {
            voices[i].filter.reset()
            voices[i].hpf.reset()
            voices[i].hpfSweep.reset()
            voices[i].env.reset()
            voices[i].gateAmp = 0
        }
        voices[i].active = true
        voices[i].env.gateOn(envelopeSettings(forPitch: Float(note), voice: i))
        lastPitch = Float(note)
    }

    private func releaseVoice(_ i: Int) {
        voices[i].gate = false
        voices[i].sustained = false
        voices[i].env.gateOff(envelopeSettings(forPitch: voices[i].pitch, voice: i))
    }

    private func releaseSustained() {
        for i in 0..<SynthEngine.maxVoices where voices[i].sustained {
            releaseVoice(i)
        }
    }

    private func allNotesOff() {
        for i in 0..<SynthEngine.maxVoices where voices[i].gate {
            releaseVoice(i)
        }
        keyStackCount = 0
        // Voices are gone; the held / latched arp keys stay (key mode switch).
        arp.silence()
        seq.silence()
    }

    // MARK: Arpeggiator

    private func arpKeyDown(_ key: Int, velocity: Int) {
        if !arpWasOn { arpSwitched(on: true) }
        if pi(.arpHold) == 1 {
            // HOLD: a new chord (played after all keys were released)
            // replaces the latched one.
            var othersHeld = false
            for k in 0..<128 where k != key && heldKeyFlags[k] != 0 { othersHeld = true }
            if !othersHeld { arp.removeAll() }
        }
        arp.add(key, velocity: velocity)
    }

    /// Switching the arpeggiator on takes over the keys already held;
    /// switching it off stops the pattern.
    private func arpSwitched(on: Bool) {
        arpWasOn = on
        if on {
            for i in 0..<SynthEngine.maxVoices where voices[i].gate { releaseVoice(i) }
            keyStackCount = 0
            arp.reset()
            _ = seq.stop()
            seqWasOn = pi(.seqOn) == 1
            for k in 0..<128 where heldKeyFlags[k] != 0 { arp.add(k, velocity: 100) }
        } else {
            let key = arp.stop()
            let seqKey = seq.stop()
            arp.removeAll()
            if key >= 0 { noteOff(key) }
            if seqKey >= 0 { noteOff(seqKey) }
        }
    }

    /// Called once per control block with the beat position of its first frame.
    private func arpTick(beat: Double) {
        // Handle a key mode switch before the arp's note events.
        syncKeyMode()
        let on = collectorOn
        if on != arpWasOn { arpSwitched(on: on) }
        guard on else { return }
        let seqOn = pi(.seqOn) == 1
        if seqOn != seqWasOn {
            // Hand over between arp and sequencer.
            let a = arp.stop()
            let q = seq.stop()
            if a >= 0 { noteOff(a) }
            if q >= 0 { noteOff(q) }
            seqWasOn = seqOn
        }
        let hold = pi(.arpHold) == 1
        if arpHoldWasOn && !hold {
            // HOLD released: drop the keys that are no longer pressed.
            for k in 0..<128 where heldKeyFlags[k] == 0 { arp.remove(k) }
        }
        arpHoldWasOn = hold

        if seqOn {
            let root = arp.count > 0 ? arp.keys[arp.count - 1] : -1
            let ev = seq.process(beat: beat, root: root,
                                 rateIndex: pi(.seqRate),
                                 length: pi(.seqLength) + 1,
                                 gate: Arpeggiator.gateFraction(p(.seqGate)),
                                 gateVariation: Double(p(.seqGateVar)) / 127,
                                 steps: UnsafePointer(params + Param.seqStep0.rawValue))
            if ev.legato {
                if ev.on >= 0 {
                    legatoNote = true
                    noteOn(ev.on, velocity: ev.velocity)
                    legatoNote = false
                }
                if ev.off >= 0 { noteOff(ev.off) }
            } else {
                if ev.off >= 0 { noteOff(ev.off) }
                if ev.on >= 0 { noteOn(ev.on, velocity: ev.velocity) }
            }
            return
        }

        // CHORD mode: the arp walks through the chord tones of every held key.
        var chord: UnsafePointer<Int8>? = nil
        var chordSize = 0
        if pi(.keyMode) == 1 {
            let slot = min(max(pi(.chordIndex), 0), ChordMemory.slots - 1)
            chord = UnsafePointer(chordNotes + slot * ChordMemory.maxNotes)
            chordSize = max(1, min(Int(chordSizes[slot]), ChordMemory.maxNotes))
        }
        let events = arp.process(beat: beat,
                                 rateIndex: pi(.arpRate),
                                 octaves: pi(.arpOctaves),
                                 mode: pi(.arpMode),
                                 gate: Arpeggiator.gateFraction(p(.arpGate)),
                                 chord: chord, chordSize: chordSize)
        if events.off >= 0 { noteOff(events.off) }
        if events.on >= 0 {
            noteOn(events.on, velocity: events.velocity)
            arp.started(events.on)
        }
    }

    // Mono, chord and unison modes share one "voice group" driven by a key
    // stack (last-note priority, legato without envelope retrigger).

    private func pushKey(_ key: Int) {
        removeKey(key)
        if keyStackCount == SynthEngine.keyStackCapacity {
            for j in 1..<keyStackCount { keyStack[j - 1] = keyStack[j] }
            keyStackCount -= 1
        }
        keyStack[keyStackCount] = key
        keyStackCount += 1
    }

    private func removeKey(_ key: Int) {
        var w = 0
        for r in 0..<keyStackCount where keyStack[r] != key {
            keyStack[w] = keyStack[r]
            w += 1
        }
        keyStackCount = w
    }

    @inline(__always) private func groupSize(_ slot: Int, _ unison: Bool) -> Int {
        if unison { return SynthEngine.maxVoices }
        return slot < 0 ? 1 : max(1, min(Int(chordSizes[slot]), SynthEngine.maxVoices))
    }

    @inline(__always) private func groupOffset(_ slot: Int, _ j: Int) -> Int {
        slot < 0 ? 0 : Int(chordNotes[slot * ChordMemory.maxNotes + j])
    }

    private func groupNoteOn(_ key: Int, _ vel: Float) {
        pushKey(key)
        let (slot, unison) = group
        let count = groupSize(slot, unison)
        var legato = false
        for j in 0..<count where voices[j].active && voices[j].gate { legato = true }
        let retrigger = pi(.envRetrigger) == 0 && !legatoNote

        for j in 0..<SynthEngine.maxVoices {
            if j < count {
                let note = key + keyShift + groupOffset(slot, j)
                voices[j].isUnison = unison
                voices[j].unisonSpread = unison ? (Float(j) - Float(count - 1) / 2) / (Float(count - 1) / 2) : 0
                if legato && voices[j].active && voices[j].gate {
                    if retrigger {
                        // New attack on every note (overlapping sequencer
                        // notes), but keep gliding from the current pitch.
                        let pitch = voices[j].pitch
                        let fade = voices[j].lfoFade
                        startVoice(j, key: key, note: note, velocity: vel)
                        if portamentoOn { voices[j].pitch = pitch }
                        voices[j].lfoFade = fade
                    } else {
                        voices[j].key = key
                        voices[j].note = note
                        voices[j].targetPitch = Float(note)
                        voices[j].sustained = false
                        if !portamentoOn { voices[j].pitch = Float(note) }
                    }
                } else {
                    let glideFrom = lastPitch
                    startVoice(j, key: key, note: note, velocity: vel)
                    if portamentoOn { voices[j].pitch = glideFrom + Float(groupOffset(slot, j)) }
                    lastPitch = glideFrom
                }
            } else if voices[j].gate {
                releaseVoice(j)
            }
        }
        lastPitch = Float(key + keyShift)
    }

    private func groupNoteOff(_ key: Int) {
        let wasTop = keyStackCount > 0 && keyStack[keyStackCount - 1] == key
        removeKey(key)
        guard wasTop else { return }

        let (slot, unison) = group
        if keyStackCount > 0 {
            // Return to the previously held key, legato.
            let prev = keyStack[keyStackCount - 1]
            for j in 0..<groupSize(slot, unison) where voices[j].active {
                let note = prev + keyShift + groupOffset(slot, j)
                voices[j].key = prev
                voices[j].note = note
                voices[j].targetPitch = Float(note)
                if !portamentoOn { voices[j].pitch = Float(note) }
            }
            lastPitch = Float(prev + keyShift)
        } else {
            for j in 0..<SynthEngine.maxVoices where voices[j].gate {
                if sustainPedal { voices[j].sustained = true } else { releaseVoice(j) }
            }
        }
    }

    // MARK: Parameter mapping

    /// Envelope state of the most recently started sounding voice, for the
    /// envelope display (plain values, read by the UI without locking).
    private(set) var monitorStage = 0
    private(set) var monitorProgress: Float = 0

    private func updateEnvelopeMonitor() {
        var newest = -1
        var newestAge: UInt64 = 0
        for i in 0..<SynthEngine.maxVoices where voices[i].active && voices[i].age >= newestAge {
            newest = i
            newestAge = voices[i].age
        }
        if newest >= 0 {
            let m = voices[newest].env.monitor
            monitorStage = m.stage
            monitorProgress = m.progress
        } else {
            monitorStage = 0
            monitorProgress = 0
        }
    }

    /// 0...127 → 1 ms ... 12 s, exponential.
    /// Envelope segment time in seconds (segment 1...4 = T1...T4), after the
    /// Juno-2 measurements in `HardwareCurves`.
    @inline(__always) static func envelopeTime(_ raw: Float, segment: Int) -> Float {
        HardwareCurves.envelopeSeconds(raw, segment: segment)
    }

    private func envelopeSettings(forPitch pitch: Float, voice i: Int) -> EnvelopeSettings {
        var s = envSettings
        let follow = p(.envKeyFollow) / 127
        var scale = 1 + p(.voiceDrift) / 127 * voices[i].driftEnvelope * 0.08
        if follow > 0 {
            scale *= exp2f(-follow * (pitch - 60) / 24)
        }
        s.t1 *= scale; s.t2 *= scale; s.t3 *= scale; s.t4 *= scale
        return s
    }

    @inline(__always) private func envAmount(_ env: Float, mode: Int, velocity: Float) -> Float {
        switch mode {
        case 1: return -env
        case 2: return env * (0.25 + 0.75 * velocity)
        case 3: return -env * (0.25 + 0.75 * velocity)
        default: return env
        }
    }

    // MARK: Rendering

    /// Parameter curves evaluated once per control block and shared by all
    /// voices (keeps powf / expf out of the per-voice path).
    private struct BlockParams {
        var dcoEnvMode = 0
        var vcfEnvMode = 0
        var vcaGateMode = false
        var vcaDynamics = false
        var vibratoSemis: Float = 0
        var dcoEnvSemis: Float = 0
        var pitchOffset: Float = 0        // range + bend
        var portaOn = false
        var portaCoef: Float = 1
        var lfoFadeIncrement: Float = 1
        var drift: Float = 0
        var unisonSemis: Float = 0
        var pulseDetuneSemis: Float = 0
        var pulseEnvSemis: Float = 0
        var pulseSync = false
        var cutoffOct: Float = 10
        var keyFollow: Float = 0
        var vcfEnvOct: Float = 0
        var vcfLfoOct: Float = 0
        var vcfAfterOct: Float = 0
        var resonance: Float = 0
        var amp: Float = 1
        var gateCoef: Float = 0.01
        var gateReleaseCoef: Float = 0.01
    }

    private var block = BlockParams()

    private func updateGlobalControl(frames n: Int) {
        let sr = sampleRate
        let fn = Float(n)

        syncKeyMode()
        syncChord()

        updateLFO(frames: n)

        // PW / PWM: the PWM gate compares the low 7 counter bits with PW
        // (0...127), one-sided. PWM RATE 0 = manual width set by the depth
        // control; otherwise a triangle PW LFO sweeps 0 ... depth.
        let pwDepth = p(.dcoPwDepth) / 128
        let pwmRate = p(.dcoPwmRate)
        let pw: Float
        if pwmRate < 0.5 {
            pw = pwDepth
        } else {
            pwmPhase += HardwareCurves.pwmHz(pwmRate) * fn / sr
            if pwmPhase >= 1 { pwmPhase -= floorf(pwmPhase) }
            let tri01 = 1 - abs(2 * pwmPhase - 1)
            pw = pwDepth * tri01
        }
        dcoSettings.configure(pulse: pi(.dcoPulse), saw: pi(.dcoSaw), sub: pi(.dcoSub), pw: pw)
        // 2-bit sub level, 6 dB per step like the june-21 measurements.
        let subStep = pi(.dcoSubLevel)
        dcoSettings.subLevel = subStep == 0 ? 0 : exp2f(Float(subStep) - 3)
        dcoSettings.noiseLevel = Float(pi(.dcoNoiseLevel)) / 3 * 0.5

        refreshEnvelopeSettings()

        // Smoothed controls
        cutoffSmoothed += (p(.vcfCutoff) - cutoffSmoothed) * min(1, fn / (0.01 * sr))
        let volumeTarget = powf(p(.volume) / 127, 2)
        volumeSmoothed += (volumeTarget - volumeSmoothed) * min(1, fn / (0.02 * sr))

        // HPF (bass boost / flat / two high-pass settings)
        // Continuous HPF: 0 = off, 1...127 → 20 Hz ... 4 kHz (12 dB/oct), smoothed.
        let sweepTarget = p(.hpfFreq)
        if sweepTarget < 0.5 && hpfSweepSmoothed < 0.5 {
            hpfSweepActive = false
            hpfSweepSmoothed = 0
        } else {
            hpfSweepSmoothed += (sweepTarget - hpfSweepSmoothed) * min(1, fn / (0.02 * sr))
            hpfSweepActive = true
            hpfSweepCoefficients = .highPass(freq: SynthEngine.hpfSweepHz(hpfSweepSmoothed), q: 0.707, sampleRate: sr)
        }

        let hpf = pi(.hpfCutoff)
        if hpf != hpfMode {
            hpfMode = hpf
            switch hpf {
            // Juno-106 style 4-step HPF: bass boost (about +3 dB at 70 Hz),
            // flat, then 1-pole (6 dB/oct) high-passes at about 225 / 700 Hz.
            case 0: hpfCoefficients = .lowShelf(freq: 70, gainDB: 6, sampleRate: sr)
            case 2: hpfCoefficients = .onePoleHighPass(freq: 225, sampleRate: sr)
            case 3: hpfCoefficients = .onePoleHighPass(freq: 700, sampleRate: sr)
            default: hpfCoefficients = .bypass
            }
        }

        // Shared per-voice modulation amounts
        var b = block
        b.dcoEnvMode = pi(.dcoEnvMode)
        b.vcfEnvMode = pi(.vcfEnvMode)
        let vcaMode = pi(.vcaEnvMode)
        b.vcaGateMode = vcaMode == 1 || vcaMode == 3
        b.vcaDynamics = vcaMode >= 2

        let lfoVibrato: Float = HardwareCurves.vibratoSemitones(p(.dcoLfoDepth))
        let wheelVibrato: Float = modWheel * powf(p(.modSensitivity) / 127, 2) * 3
        let afterVibrato: Float = aftertouch * powf(p(.dcoAfterDepth) / 127, 2) * 3
        b.vibratoSemis = lfoVibrato + wheelVibrato + afterVibrato
        b.dcoEnvSemis = powf(p(.dcoEnvDepth) / 127, 2) * 24
        // RANGE 0 = 4', 1 = 8', 2 = 16', 3 = 32' (MKS-50 SysEx order).
        b.pitchOffset = Float((1 - pi(.dcoRange)) * 12) + bend * p(.benderRange)

        b.portaOn = portaMode != 0
        let portaSeconds = powf(p(.portaTime) / 127, 2) * 3
        b.portaCoef = portaSeconds < 0.001 ? 1 : 1 - expf(-fn / (portaSeconds * sr))

        let delay = HardwareCurves.lfoDelaySeconds(p(.lfoDelay))
        b.lfoFadeIncrement = delay < 0.001 ? 1 : fn / (delay * sr)

        b.drift = p(.voiceDrift) / 127
        b.unisonSemis = powf(p(.unisonDetune) / 127, 1.5) * 0.5
        b.pulseDetuneSemis = (p(.pulseDetune) - 64) / 64 * 12
        b.pulseEnvSemis = p(.pulseEnvMod) / 127 * 36
        b.pulseSync = pi(.pulseSync) == 1

        // Cutoff 100 Hz · 2^(v / 12 − 3.2) (june-21): about 11 Hz ... 16 kHz,
        // one octave per 12 steps; env, LFO and key follow on the same scale.
        b.cutoffOct = cutoffSmoothed / 12 - 0.878
        b.keyFollow = p(.vcfKeyFollow) / 127 / 12
        b.vcfEnvOct = p(.vcfEnvDepth) / 12
        b.vcfLfoOct = p(.vcfLfoDepth) / 48
        b.vcfAfterOct = aftertouch * p(.vcfAfterDepth) / 127 * 4
        b.resonance = p(.vcfResonance) / 127

        b.amp = p(.vcaLevel) / 127 * (1 + aftertouch * p(.vcaAfterDepth) / 127)
        // GATE mode: near-instant on, short declick release.
        b.gateCoef = 1 - expf(-1 / (0.0003 * sr))
        b.gateReleaseCoef = 1 - expf(-1 / (0.012 * sr))
        block = b
    }

    /// LFO: free-running rate, or tempo-synced to a note value. Inside a DAW
    /// with transport the synced phase is locked to the song position.
    private func updateLFO(frames n: Int) {
        let sr = sampleRate
        let fn = Float(n)
        var wrapped = false

        if pi(.lfoSync) == 1 {
            let index = min(max(pi(.lfoDivision), 0), LFOShape.divisionQuarters.count - 1)
            let quarters = LFOShape.divisionQuarters[index]
            let tempo = max(tempoBPM, 20)
            if pi(.lfoKeySync) == 0 {
                // Locked to the beat clock (host song position or the internal
                // clock), so synced LFOs line up with bars and loop recordings.
                let beat = renderStartBeat + Double(renderFrameOffset) * beatsPerFrame
                let cycles = beat / quarters
                let newPhase = Float(cycles - floor(cycles))
                wrapped = newPhase < lfoPhase
                lfoPhase = newPhase
            } else {
                lfoPhase += Float(tempo / 60 / quarters) * fn / sr
            }
        } else {
            let lfoHz = HardwareCurves.lfoHz(p(.lfoRate))
            lfoPhase += lfoHz * fn / sr
        }
        if lfoPhase >= 1 {
            lfoPhase -= floorf(lfoPhase)
            wrapped = true
        }
        renderFrameOffset += n

        let shape = pi(.lfoWave)
        switch shape {
        case 5:     // sample & hold: new random value every cycle
            if wrapped { lfoHeld = lfoRandom.next() }
            lfoValue = lfoHeld
        case 6:     // smooth random: cosine glide to a new random target each cycle
            if wrapped {
                lfoFrom = lfoTo
                lfoTo = lfoRandom.next()
            }
            let t = 0.5 - 0.5 * cosf(Float.pi * lfoPhase)
            lfoValue = lfoFrom + (lfoTo - lfoFrom) * t
        default:
            lfoValue = LFOShape.value(shape, phase: lfoPhase)
        }
    }

    private func renderVoice(_ i: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames n: Int) {
        let b = block
        let sr = sampleRate

        // Portamento
        if b.portaOn {
            voices[i].pitch += (voices[i].targetPitch - voices[i].pitch) * b.portaCoef
        } else {
            voices[i].pitch = voices[i].targetPitch
        }
        let pitch = voices[i].pitch

        // Voice calibration: static offsets plus slow random wander.
        var driftSemis: Float = 0
        var driftOct: Float = 0
        if b.drift > 0 {
            let fn = Float(n)
            voices[i].wander += voices[i].rng.next() * 0.02 * fn / 16 - voices[i].wander * 0.0005 * fn
            voices[i].wander = clampf(voices[i].wander, -1, 1)
            driftSemis = b.drift * (voices[i].driftPitch * 0.08 + voices[i].wander * 0.04)
            driftOct = b.drift * voices[i].driftCutoff * 0.15
        }

        // LFO delay: fade-in after key on
        if voices[i].lfoFade < 1 {
            voices[i].lfoFade = min(1, voices[i].lfoFade + b.lfoFadeIncrement)
        }
        let lfo = lfoValue * voices[i].lfoFade

        let velocity = voices[i].velocity
        let env = voices[i].env.value
        let dcoEnv = envAmount(env, mode: b.dcoEnvMode, velocity: velocity)
        let vcfEnv = envAmount(env, mode: b.vcfEnvMode, velocity: velocity)

        // DCO pitch
        var semis: Float = pitch + b.pitchOffset + lfo * b.vibratoSemis
        semis += dcoEnv * b.dcoEnvSemis + driftSemis + voices[i].unisonSpread * b.unisonSemis
        let dt = noteToHz(semis) / sr

        // Pulse detune / envelope sweep (for hard-sync leads)
        let pulseSemis = b.pulseDetuneSemis + dcoEnv * b.pulseEnvSemis
        let ratio: Float = pulseSemis == 0 ? 1 : exp2f(pulseSemis / 12)

        // VCF cutoff in octaves above 20 Hz
        var octaves: Float = b.cutoffOct + b.keyFollow * (pitch - 60) + vcfEnv * b.vcfEnvOct
        octaves += lfo * b.vcfLfoOct + b.vcfAfterOct + driftOct
        let cutoff = 20 * exp2f(clampf(octaves, -2, 11))
        voices[i].filter.setCoefficients(cutoff: cutoff, resonance: b.resonance, sampleRate: sr)

        // VCA
        let dynamics: Float = b.vcaDynamics ? (0.2 + 0.8 * velocity) : 1
        let unisonGain: Float = voices[i].isUnison ? 0.45 : 1
        let amp = b.amp * dynamics * unisonGain
        let gateMode = b.vcaGateMode
        let gateTarget: Float = voices[i].gate ? 1 : 0
        let gateCoef = voices[i].gate ? b.gateCoef : b.gateReleaseCoef

        // Panning for unison voices
        let pan = voices[i].isUnison ? voices[i].unisonSpread * 0.85 : 0
        let gainL = amp * min(1, 1 - pan)
        let gainR = amp * min(1, 1 + pan)

        let es = envelopeSettings(forPitch: pitch, voice: i)
        let sync = b.pulseSync
        let settings = dcoSettings
        let hpfC = hpfCoefficients
        let hpfActive = hpfMode != 1
        let sweepActive = hpfSweepActive
        let sweepC = hpfSweepCoefficients

        for k in 0..<n {
            let e = voices[i].env.next(es)
            voices[i].gateAmp += (gateTarget - voices[i].gateAmp) * gateCoef
            var s = voices[i].dco.tick(dt: dt, pulseRatio: ratio, sync: sync, settings) * 0.5
            if hpfActive { s = voices[i].hpf.process(s, hpfC) }
            if sweepActive { s = voices[i].hpfSweep.process(s, sweepC) }
            s = voices[i].filter.process(s)
            s *= gateMode ? voices[i].gateAmp : e
            left[k] += s * gainL
            right[k] += s * gainR
        }

        // Voice finished?
        if gateMode {
            if !voices[i].gate && voices[i].gateAmp < 0.0001 { voices[i].active = false }
        } else if voices[i].env.isIdle {
            voices[i].active = false
        }
    }

    @inline(__always) private static func limit(_ x: Float) -> Float {
        let a = abs(x)
        if a < 0.8 { return x }
        let y = 0.8 + 0.2 * softClip((a - 0.8) / 0.2)
        return x < 0 ? -y : y
    }

    /// Frames rendered since the last voice went idle.
    private var idleFrames = 0

    /// Renders `frames` stereo samples, overwriting the destination buffers.
    ///
    /// - Returns: `true` if the output is pure silence. When no voice is
    ///   sounding and the chorus / DC-blocker tails have died away, nothing
    ///   is computed at all, so an idle instance costs almost no CPU.
    @discardableResult
    func render(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) -> Bool {
        // Beat clock: host song position inside a DAW, else the internal clock.
        let bpf = beatsPerFrame
        if hostBeatPosition >= 0 && hostTempo > 0 {
            renderStartBeat = hostBeatPosition + Double(cycleSamples) * bpf
        } else {
            renderStartBeat = internalBeat
        }
        renderFrameOffset = 0
        let tail = recorder.inTail
        if tail && !recorderTailGate {
            // Loop part done: release everything so the tail only rings out.
            allNotesOff()
        }
        recorderTailGate = tail
        internalBeat = renderStartBeat + Double(frames) * bpf
        if internalBeat > 1_000_000 { internalBeat -= 1_000_000 }   // keep precision (multiple of 4 beats)
        cycleSamples += frames
        defer {
            recorder.process(left: left, right: right, frames: frames,
                             beatStart: renderStartBeat, beatsPerFrame: bpf)
        }

        var anyActive = false
        for i in 0..<SynthEngine.maxVoices where voices[i].active { anyActive = true }

        // Idle once no voice sounds and the output (incl. delay / reverb
        // tails) has stayed below -100 dBFS for 100 ms.
        let tailFrames = Int(sampleRate * 0.1)
        if !anyActive && idleFrames >= tailFrames && arp.isEmpty && collectorOn == arpWasOn {
            left.update(repeating: 0, count: frames)
            right.update(repeating: 0, count: frames)
            return true
        }

        var offset = 0
        while offset < frames {
            let n = min(frames - offset, bufferCapacity)
            renderChunk(frames: n, left: left + offset, right: right + offset)
            offset += n
        }

        anyActive = false
        for i in 0..<SynthEngine.maxVoices where voices[i].active { anyActive = true }
        updateEnvelopeMonitor()
        var peak: Float = 0
        for n in 0..<frames { peak = max(peak, abs(left[n]), abs(right[n])) }
        if anyActive || peak > 0.00001 {
            idleFrames = 0
        } else {
            idleFrames += frames
            if idleFrames >= tailFrames {
                // Settle all state exactly so the next note starts clean.
                dcXL = 0; dcYL = 0; dcXR = 0; dcYR = 0
                chorus.reset()
                delay.reset()
                reverb.reset()
            }
        }
        return false
    }

    private func renderChunk(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        let mixL = mixLeft
        let mixR = mixRight
        mixL.update(repeating: 0, count: frames)
        mixR.update(repeating: 0, count: frames)

        var pos = 0
        while pos < frames {
            let n = min(SynthEngine.controlInterval, frames - pos)
            arpTick(beat: renderStartBeat + Double(renderFrameOffset) * beatsPerFrame)
            updateGlobalControl(frames: n)
            for i in 0..<SynthEngine.maxVoices where voices[i].active {
                renderVoice(i, left: mixL + pos, right: mixR + pos, frames: n)
            }
            pos += n
        }

        // DC blocker + master gain
        let gain = volumeSmoothed * 0.5
        for n in 0..<frames {
            let xl = mixL[n]
            let yl = xl - dcXL + 0.9995 * dcYL
            dcXL = xl; dcYL = yl
            mixL[n] = yl * gain

            let xr = mixR[n]
            let yr = xr - dcXR + 0.9995 * dcYR
            dcXR = xr; dcYR = yr
            mixR[n] = yr * gain
        }

        // Distortion on the dry synth, before chorus / delay / reverb, so
        // the effect tails stay clean.
        distortion.process(left: mixL, right: mixR, frames: frames,
                           mode: pi(.distMode),
                           drive: p(.distDrive) / 127,
                           tone: p(.distTone) / 127,
                           level: p(.distLevel) / 127,
                           mix: p(.distMix) / 127)

        let chorusHz = HardwareCurves.chorusHz(p(.chorusRate))
        chorus.process(inputLeft: mixL, inputRight: mixR, left: left, right: right, frames: frames,
                       enabled: pi(.chorus) == 1, rate: chorusHz)

        // FX section: delay, then reverb (as in TAL-Pha).
        delay.process(left: left, right: right, frames: frames,
                      mix: powf(p(.delayMix) / 127, 1.5),
                      seconds: currentDelaySeconds(),
                      feedback: SynthEngine.delayFeedback(p(.delayFeedback)),
                      tone: p(.delayTone) / 127,
                      pingPong: pi(.delayPingPong) == 1)
        reverb.process(left: left, right: right, frames: frames,
                       mix: powf(p(.reverbMix) / 127, 1.5),
                       size: p(.reverbSize) / 127,
                       damp: p(.reverbDamp) / 127)

        for n in 0..<frames {
            left[n] = SynthEngine.limit(left[n])
            right[n] = SynthEngine.limit(right[n])
        }
    }

    var maximumFrames: Int { bufferCapacity }

    /// HPF FREQ knob: 1...127 → 20 Hz ... 4 kHz.
    static func hpfSweepHz(_ raw: Float) -> Float {
        20 * powf(200, raw / 127)
    }

    /// FEEDBACK knob: 0...127 → 0 ... 115 %. The lower half is unchanged
    /// (0 ... 47 %, as before, so sounds keep their echoes); the upper half
    /// spans 47 ... 115 % for dub build-ups and self-oscillation above 100 %.
    static func delayFeedback(_ raw: Float) -> Float {
        let x = max(0, min(raw, 127)) / 127
        return x <= 0.5 ? x * 0.95 : 0.475 + (x - 0.5) * 2 * 0.675
    }

    /// Free delay time: 0...127 → 10 ms ... 1.5 s.
    static func delaySeconds(_ raw: Float) -> Float {
        0.01 * powf(150, raw / 127)
    }

    /// Effective tempo: host tempo inside a DAW, else the TEMPO parameter.
    var tempoBPM: Double {
        hostTempo > 0 ? hostTempo : Double(params[Param.tempo.rawValue]) + 40
    }

    private func currentDelaySeconds() -> Float {
        guard pi(.delaySync) == 1 else { return SynthEngine.delaySeconds(p(.delayTime)) }
        let index = min(max(pi(.delayDivision), 0), DelayDivision.quarters.count - 1)
        return DelayDivision.quarters[index] * Float(60 / max(tempoBPM, 20))
    }
}
