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
    var dt: Float = 0

    var dco: DCO
    var env = Envelope()
    var filter = LadderFilter()
    var hpf = BiquadState()

    init(seed: UInt32) {
        dco = DCO(seed: seed)
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
    private var monoBuffer: UnsafeMutablePointer<Float>
    private var scratchBuffer: UnsafeMutablePointer<Float>
    private let chorus = Chorus()

    // Performance controllers
    private var bend: Float = 0
    private var modWheel: Float = 0
    private var aftertouch: Float = 0
    private var sustainPedal = false

    // Global modulation state
    private var lfoPhase: Float = 0
    private var lfoValue: Float = 0
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
    private var dcX: Float = 0
    private var dcY: Float = 0

    // Mono / chord key stack
    private let keyStack: UnsafeMutablePointer<Int>
    private var keyStackCount = 0
    private static let keyStackCapacity = 32
    private var stackVelocity: Float = 1

    // Chord memory
    let chordNotes: UnsafeMutablePointer<Int8>
    let chordSizes: UnsafeMutablePointer<Int8>

    // Thread-safe inbox for MIDI coming from UI / CoreMIDI threads.
    private let queueLock: UnsafeMutablePointer<os_unfair_lock>
    private let queue: UnsafeMutablePointer<UInt32>
    private var queueCount = 0

    /// Set by the audio thread when a program change arrives; consumed on main.
    var pendingProgramChange: Int32 = -1

    init() {
        params = .allocate(capacity: Param.storageSize)
        params.initialize(repeating: 0, count: Param.storageSize)
        for p in Param.allCases { params[p.rawValue] = Float(p.defaultValue) }

        voices = .allocate(capacity: SynthEngine.maxVoices)
        for i in 0..<SynthEngine.maxVoices {
            (voices + i).initialize(to: Voice(seed: UInt32(0x1234_5678 &+ i &* 7919)))
        }

        bufferCapacity = 4096
        monoBuffer = .allocate(capacity: bufferCapacity)
        scratchBuffer = .allocate(capacity: bufferCapacity)
        monoBuffer.initialize(repeating: 0, count: bufferCapacity)
        scratchBuffer.initialize(repeating: 0, count: bufferCapacity)

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

        for (i, chord) in ChordMemory.defaultChords.enumerated() { setChord(i, chord) }
        prepare(sampleRate: 44100, maximumFrames: 4096)
    }

    deinit {
        params.deallocate()
        voices.deinitialize(count: SynthEngine.maxVoices)
        voices.deallocate()
        monoBuffer.deallocate()
        scratchBuffer.deallocate()
        keyStack.deallocate()
        chordNotes.deallocate()
        chordSizes.deallocate()
        queueLock.deallocate()
        queue.deallocate()
    }

    // MARK: Setup (not real-time)

    func prepare(sampleRate: Double, maximumFrames: Int) {
        self.sampleRate = Float(sampleRate)
        if maximumFrames > bufferCapacity {
            monoBuffer.deallocate()
            scratchBuffer.deallocate()
            bufferCapacity = maximumFrames
            monoBuffer = .allocate(capacity: bufferCapacity)
            scratchBuffer = .allocate(capacity: bufferCapacity)
            monoBuffer.initialize(repeating: 0, count: bufferCapacity)
            scratchBuffer.initialize(repeating: 0, count: bufferCapacity)
        }
        for i in 0..<SynthEngine.maxVoices {
            voices[i].env.sampleRate = self.sampleRate
        }
        hpfMode = -1
        chorus.prepare(sampleRate: self.sampleRate)
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
            voices[i].gateAmp = 0
        }
        keyStackCount = 0
        chorus.reset()
        dcX = 0
        dcY = 0
    }

    // MARK: Parameters

    @inline(__always) func setParameter(_ address: AUParameterAddress, _ value: AUValue) {
        guard address < AUParameterAddress(Param.storageSize) else { return }
        params[Int(address)] = value
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
        case 0x90:
            if d2 > 0 { noteOn(d1, velocity: d2) } else { noteOff(d1) }
        case 0x80:
            noteOff(d1)
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
            allNotesOff()
        default:
            break
        }
    }

    // MARK: Voice allocation

    private var keyShift: Int { pi(.keyShift) - 12 }
    private var portamentoOn: Bool { pi(.portaSwitch) == 1 }

    private func noteOn(_ key: Int, velocity: Int) {
        let vel = Float(velocity) / 127
        switch pi(.keyMode) {
        case 1: groupNoteOn(key, vel, chordSlot: pi(.chordIndex))
        case 2: groupNoteOn(key, vel, chordSlot: -1)
        default: polyNoteOn(key, vel)
        }
    }

    private func noteOff(_ key: Int) {
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
            voices[i].env.reset()
            voices[i].gateAmp = 0
        }
        voices[i].active = true
        voices[i].env.gateOn(envelopeSettings(forPitch: Float(note)))
        lastPitch = Float(note)
    }

    private func releaseVoice(_ i: Int) {
        voices[i].gate = false
        voices[i].sustained = false
        voices[i].env.gateOff(envelopeSettings(forPitch: voices[i].pitch))
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
    }

    // Mono and chord modes share one "voice group" driven by a key stack
    // (last-note priority, legato without envelope retrigger).

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

    @inline(__always) private func groupSize(_ chordSlot: Int) -> Int {
        chordSlot < 0 ? 1 : max(1, min(Int(chordSizes[chordSlot]), SynthEngine.maxVoices))
    }

    @inline(__always) private func groupOffset(_ chordSlot: Int, _ j: Int) -> Int {
        chordSlot < 0 ? 0 : Int(chordNotes[chordSlot * ChordMemory.maxNotes + j])
    }

    private func groupNoteOn(_ key: Int, _ vel: Float, chordSlot: Int) {
        pushKey(key)
        stackVelocity = vel
        let count = groupSize(chordSlot)
        var legato = false
        for j in 0..<count where voices[j].active && voices[j].gate { legato = true }

        for j in 0..<SynthEngine.maxVoices {
            if j < count {
                let note = key + keyShift + groupOffset(chordSlot, j)
                if legato && voices[j].active && voices[j].gate {
                    voices[j].key = key
                    voices[j].note = note
                    voices[j].targetPitch = Float(note)
                    voices[j].sustained = false
                    if !portamentoOn { voices[j].pitch = Float(note) }
                } else {
                    let glideFrom = lastPitch
                    startVoice(j, key: key, note: note, velocity: vel)
                    if portamentoOn { voices[j].pitch = glideFrom + Float(groupOffset(chordSlot, j)) }
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

        let chordSlot = pi(.keyMode) == 1 ? pi(.chordIndex) : -1
        if keyStackCount > 0 {
            // Return to the previously held key, legato.
            let prev = keyStack[keyStackCount - 1]
            for j in 0..<groupSize(chordSlot) where voices[j].active {
                let note = prev + keyShift + groupOffset(chordSlot, j)
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

    private func envelopeSettings(forPitch pitch: Float) -> EnvelopeSettings {
        var s = envSettings
        let follow = p(.envKeyFollow) / 127
        if follow > 0 {
            let scale = exp2f(-follow * (pitch - 60) / 24)
            s.t1 *= scale; s.t2 *= scale; s.t3 *= scale; s.t4 *= scale
        }
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

    private func updateGlobalControl(frames n: Int) {
        let sr = sampleRate
        let fn = Float(n)

        // Key mode switch releases everything (as the hardware does).
        let keyMode = pi(.keyMode)
        if keyMode != lastKeyMode {
            if lastKeyMode >= 0 { allNotesOff() }
            lastKeyMode = keyMode
        }

        // LFO (triangle)
        let lfoHz = 0.1 * powf(300, p(.lfoRate) / 127)
        lfoPhase += lfoHz * fn / sr
        if lfoPhase >= 1 { lfoPhase -= floorf(lfoPhase) }
        lfoValue = 4 * abs(lfoPhase - 0.5) - 1

        // DCO waveform settings and PW / PWM
        dcoSettings.pulse = pi(.dcoPulse)
        dcoSettings.saw = pi(.dcoSaw)
        dcoSettings.sub = pi(.dcoSub)
        dcoSettings.subLevel = Float(pi(.dcoSubLevel)) / 3 * 0.9
        dcoSettings.noiseLevel = Float(pi(.dcoNoiseLevel)) / 3 * 0.6
        let pwDepth = p(.dcoPwDepth) / 127
        let pwmRate = p(.dcoPwmRate)
        if pwmRate < 0.5 {
            dcoSettings.pw = 0.5 - 0.46 * pwDepth
        } else {
            let pwmHz = 0.1 * powf(200, pwmRate / 127)
            pwmPhase += pwmHz * fn / sr
            if pwmPhase >= 1 { pwmPhase -= floorf(pwmPhase) }
            let tri01 = 1 - abs(2 * pwmPhase - 1)
            dcoSettings.pw = 0.5 - 0.46 * pwDepth * tri01
        }

        // Envelope base times / levels
        envSettings.t1 = SynthEngine.envelopeTime(p(.envT1))
        envSettings.t2 = SynthEngine.envelopeTime(p(.envT2))
        envSettings.t3 = SynthEngine.envelopeTime(p(.envT3))
        envSettings.t4 = SynthEngine.envelopeTime(p(.envT4))
        envSettings.l1 = p(.envL1) / 127
        envSettings.l2 = p(.envL2) / 127
        envSettings.l3 = p(.envL3) / 127

        // Smoothed controls
        cutoffSmoothed += (p(.vcfCutoff) - cutoffSmoothed) * min(1, fn / (0.01 * sr))
        let volumeTarget = powf(p(.volume) / 127, 2)
        volumeSmoothed += (volumeTarget - volumeSmoothed) * min(1, fn / (0.02 * sr))

        // HPF (bass boost / flat / two high-pass settings)
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
    }

    private func renderVoice(_ i: Int, into out: UnsafeMutablePointer<Float>, frames n: Int) {
        let sr = sampleRate
        let fn = Float(n)

        // Portamento
        if portamentoOn {
            let t = powf(p(.portaTime) / 127, 2) * 3
            let coef = t < 0.001 ? 1 : 1 - expf(-fn / (t * sr))
            voices[i].pitch += (voices[i].targetPitch - voices[i].pitch) * coef
        } else {
            voices[i].pitch = voices[i].targetPitch
        }
        let pitch = voices[i].pitch

        // LFO delay: fade-in after key on
        let delay = powf(p(.lfoDelay) / 127, 2) * 5
        if voices[i].lfoFade < 1 {
            voices[i].lfoFade = delay < 0.001 ? 1 : min(1, voices[i].lfoFade + fn / (delay * sr))
        }
        let lfo = lfoValue * voices[i].lfoFade

        let velocity = voices[i].velocity
        let env = voices[i].env.value
        let dcoEnv = envAmount(env, mode: pi(.dcoEnvMode), velocity: velocity)
        let vcfEnv = envAmount(env, mode: pi(.vcfEnvMode), velocity: velocity)

        // DCO pitch
        let vibratoSemis = powf(p(.dcoLfoDepth) / 127, 2) * 12
            + modWheel * powf(p(.modSensitivity) / 127, 2) * 3
            + aftertouch * powf(p(.dcoAfterDepth) / 127, 2) * 3
        let semis = pitch
            + Float((pi(.dcoRange) - 1) * 12)
            + bend * p(.benderRange)
            + lfo * vibratoSemis
            + dcoEnv * powf(p(.dcoEnvDepth) / 127, 2) * 24
        voices[i].dt = noteToHz(semis) / sr

        // VCF cutoff in octaves above 20 Hz
        let octaves = cutoffSmoothed / 127 * 10
            + p(.vcfKeyFollow) / 127 * 1.1 * (pitch - 60) / 12
            + vcfEnv * p(.vcfEnvDepth) / 127 * 9
            + lfo * powf(p(.vcfLfoDepth) / 127, 2) * 4
            + aftertouch * p(.vcfAfterDepth) / 127 * 4
        let cutoff = 20 * exp2f(clampf(octaves, -2, 11))
        voices[i].filter.setCoefficients(cutoff: cutoff, resonance: p(.vcfResonance) / 127, sampleRate: sr)

        // VCA
        let vcaMode = pi(.vcaEnvMode)
        let gateMode = vcaMode == 1 || vcaMode == 3
        let dynamics = vcaMode >= 2 ? (0.2 + 0.8 * velocity) : 1
        let amp = p(.vcaLevel) / 127 * (1 + aftertouch * p(.vcaAfterDepth) / 127) * dynamics
        let gateTarget: Float = voices[i].gate ? 1 : 0
        let gateCoef = 1 - expf(-1 / (0.002 * sr))

        let es = envelopeSettings(forPitch: pitch)
        let dt = voices[i].dt
        let settings = dcoSettings
        let hpfC = hpfCoefficients

        for k in 0..<n {
            let e = voices[i].env.next(es)
            voices[i].gateAmp += (gateTarget - voices[i].gateAmp) * gateCoef
            var s = voices[i].dco.tick(dt: dt, settings) * 0.5
            s = voices[i].hpf.process(s, hpfC)
            s = voices[i].filter.process(s)
            out[k] += s * (gateMode ? voices[i].gateAmp : e) * amp
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

    /// Renders `frames` stereo samples, overwriting the destination buffers.
    func render(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        var offset = 0
        while offset < frames {
            let n = min(frames - offset, bufferCapacity)
            renderChunk(frames: n, left: left + offset, right: right + offset)
            offset += n
        }
    }

    private func renderChunk(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        let mono = monoBuffer
        mono.update(repeating: 0, count: frames)

        var pos = 0
        while pos < frames {
            let n = min(SynthEngine.controlInterval, frames - pos)
            updateGlobalControl(frames: n)
            for i in 0..<SynthEngine.maxVoices where voices[i].active {
                renderVoice(i, into: mono + pos, frames: n)
            }
            pos += n
        }

        // DC blocker + master gain
        let gain = volumeSmoothed * 0.5
        for n in 0..<frames {
            let x = mono[n]
            let y = x - dcX + 0.9995 * dcY
            dcX = x
            dcY = y
            mono[n] = y * gain
        }

        let chorusHz = 0.15 * powf(60, p(.chorusRate) / 127)
        chorus.process(input: mono, left: left, right: right, frames: frames,
                       enabled: pi(.chorus) == 1, rate: chorusHz)

        for n in 0..<frames {
            left[n] = SynthEngine.limit(left[n])
            right[n] = SynthEngine.limit(right[n])
        }
    }

    /// Scratch buffer for hosts that only provide a single output channel.
    var scratch: UnsafeMutablePointer<Float> { scratchBuffer }
    var maximumFrames: Int { bufferCapacity }
}
