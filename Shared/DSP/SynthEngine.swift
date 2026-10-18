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

    /// Tempo-synced arpeggiator; plays through the normal note path.
    private var arp = Arpeggiator()
    private var arpWasOn = false
    private var arpHoldWasOn = false

    /// Call once per render cycle, before rendering.
    func beginRenderCycle(tempo: Double, beatPosition: Double) {
        hostTempo = tempo
        hostBeatPosition = beatPosition
        cycleSamples = 0
    }

    var currentSampleRate: Double { Double(sampleRate) }

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
        heldKeyFlags.update(repeating: 0, count: 128)
        chorus.reset()
        delay.reset()
        reverb.reset()
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
            if pi(.arpOn) == 1 {
                arpKeyDown(d1, velocity: d2)
            } else {
                noteOn(d1, velocity: d2)
            }
        case 0x80, 0x90:
            heldKeyFlags[d1] = 0
            if pi(.arpOn) == 1 && arpWasOn {
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
        default:
            break
        }
    }

    // MARK: Voice allocation

    private var keyShift: Int { pi(.keyShift) - 12 }
    private var portamentoOn: Bool { pi(.portaSwitch) == 1 }

    /// Chord slot (-1 = none) and unison flag of the current key mode.
    private var group: (slot: Int, unison: Bool) {
        switch pi(.keyMode) {
        case 1: return (min(max(pi(.chordIndex), 0), ChordMemory.slots - 1), false)
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

    /// Envelope base times / levels from the current parameters. Also called
    /// on every note event: while the engine is idle no control blocks run,
    /// and a note must never start with stale T1 / L1 values.
    private func refreshEnvelopeSettings() {
        envSettings.t1 = SynthEngine.envelopeTime(p(.envT1))
        envSettings.t2 = SynthEngine.envelopeTime(p(.envT2))
        envSettings.t3 = SynthEngine.envelopeTime(p(.envT3))
        envSettings.t4 = SynthEngine.envelopeTime(p(.envT4))
        envSettings.l1 = p(.envL1) / 127
        envSettings.l2 = p(.envL2) / 127
        envSettings.l3 = p(.envL3) / 127
    }

    private func noteOn(_ key: Int, velocity: Int) {
        syncKeyMode()
        refreshEnvelopeSettings()
        recorder.noteTrigger = true
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
            for k in 0..<128 where heldKeyFlags[k] != 0 { arp.add(k, velocity: 100) }
        } else {
            let key = arp.stop()
            arp.removeAll()
            if key >= 0 { noteOff(key) }
        }
    }

    /// Called once per control block with the beat position of its first frame.
    private func arpTick(beat: Double) {
        // Handle a key mode switch before the arp's note events.
        syncKeyMode()
        let on = pi(.arpOn) == 1
        if on != arpWasOn { arpSwitched(on: on) }
        guard on else { return }
        let hold = pi(.arpHold) == 1
        if arpHoldWasOn && !hold {
            // HOLD released: drop the keys that are no longer pressed.
            for k in 0..<128 where heldKeyFlags[k] == 0 { arp.remove(k) }
        }
        arpHoldWasOn = hold
        let events = arp.process(beat: beat,
                                 rateIndex: pi(.arpRate),
                                 octaves: pi(.arpOctaves),
                                 mode: pi(.arpMode),
                                 gate: Arpeggiator.gateFraction(p(.arpGate)))
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
        let retrigger = pi(.envRetrigger) == 0

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

    /// 0...127 → 1 ms ... 12 s, exponential.
    @inline(__always) static func envelopeTime(_ raw: Float) -> Float {
        0.001 * powf(12000, raw / 127)
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
    }

    private var block = BlockParams()

    private func updateGlobalControl(frames n: Int) {
        let sr = sampleRate
        let fn = Float(n)

        syncKeyMode()

        updateLFO(frames: n)

        // PW / PWM: PWM rate 0 = manual pulse width set by the depth control.
        let pwDepth = p(.dcoPwDepth) / 127
        let pwmRate = p(.dcoPwmRate)
        let pw: Float
        if pwmRate < 0.5 {
            pw = 0.5 - 0.46 * pwDepth
        } else {
            let pwmHz = 0.1 * powf(200, pwmRate / 127)
            pwmPhase += pwmHz * fn / sr
            if pwmPhase >= 1 { pwmPhase -= floorf(pwmPhase) }
            let tri01 = 1 - abs(2 * pwmPhase - 1)
            pw = 0.5 - 0.46 * pwDepth * tri01
        }
        dcoSettings.configure(pulse: pi(.dcoPulse), saw: pi(.dcoSaw), sub: pi(.dcoSub), pw: pw)
        dcoSettings.subLevel = Float(pi(.dcoSubLevel)) / 3 * 0.9
        dcoSettings.noiseLevel = Float(pi(.dcoNoiseLevel)) / 3 * 0.6

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
            case 0: hpfCoefficients = .lowShelf(freq: 120, gainDB: 6, sampleRate: sr)
            case 2: hpfCoefficients = .highPass(freq: 240, q: 0.6, sampleRate: sr)
            case 3: hpfCoefficients = .highPass(freq: 720, q: 0.6, sampleRate: sr)
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

        let lfoVibrato: Float = powf(p(.dcoLfoDepth) / 127, 2) * 12
        let wheelVibrato: Float = modWheel * powf(p(.modSensitivity) / 127, 2) * 3
        let afterVibrato: Float = aftertouch * powf(p(.dcoAfterDepth) / 127, 2) * 3
        b.vibratoSemis = lfoVibrato + wheelVibrato + afterVibrato
        b.dcoEnvSemis = powf(p(.dcoEnvDepth) / 127, 2) * 24
        b.pitchOffset = Float((pi(.dcoRange) - 1) * 12) + bend * p(.benderRange)

        b.portaOn = portamentoOn
        let portaSeconds = powf(p(.portaTime) / 127, 2) * 3
        b.portaCoef = portaSeconds < 0.001 ? 1 : 1 - expf(-fn / (portaSeconds * sr))

        let delay = powf(p(.lfoDelay) / 127, 2) * 5
        b.lfoFadeIncrement = delay < 0.001 ? 1 : fn / (delay * sr)

        b.drift = p(.voiceDrift) / 127
        b.unisonSemis = powf(p(.unisonDetune) / 127, 1.5) * 0.5
        b.pulseDetuneSemis = (p(.pulseDetune) - 64) / 64 * 12
        b.pulseEnvSemis = p(.pulseEnvMod) / 127 * 36
        b.pulseSync = pi(.pulseSync) == 1

        b.cutoffOct = cutoffSmoothed / 127 * 10
        b.keyFollow = p(.vcfKeyFollow) / 127 * 1.1 / 12
        b.vcfEnvOct = p(.vcfEnvDepth) / 127 * 9
        b.vcfLfoOct = powf(p(.vcfLfoDepth) / 127, 2) * 4
        b.vcfAfterOct = aftertouch * p(.vcfAfterDepth) / 127 * 4
        b.resonance = p(.vcfResonance) / 127

        b.amp = p(.vcaLevel) / 127 * (1 + aftertouch * p(.vcaAfterDepth) / 127)
        b.gateCoef = 1 - expf(-1 / (0.002 * sr))
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
            let lfoHz = 0.1 * powf(300, p(.lfoRate) / 127)
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
        let gateCoef = b.gateCoef

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
        if !anyActive && idleFrames >= tailFrames && arp.isEmpty && (pi(.arpOn) == 1) == arpWasOn {
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

        let chorusHz = 0.15 * powf(60, p(.chorusRate) / 127)
        chorus.process(inputLeft: mixL, inputRight: mixR, left: left, right: right, frames: frames,
                       enabled: pi(.chorus) == 1, rate: chorusHz)

        // FX section: delay, then reverb (as in TAL-Pha).
        delay.process(left: left, right: right, frames: frames,
                      mix: powf(p(.delayMix) / 127, 1.5),
                      seconds: currentDelaySeconds(),
                      feedback: p(.delayFeedback) / 127 * 0.95,
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
