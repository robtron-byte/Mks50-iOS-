import Foundation
import AudioToolbox

/// All synth parameters.
///
/// Addresses 0...35 follow the MKS-50 / Alpha Juno tone parameter numbering
/// exactly (as used by IPR / APR SysEx messages), so a parameter's raw value
/// is also its address on the real hardware. Patch-level parameters start at 64.
enum Param: Int, CaseIterable, Identifiable {
    // MARK: Tone parameters (MKS-50 #0 ... #35)
    case dcoEnvMode = 0
    case vcfEnvMode
    case vcaEnvMode
    case dcoPulse
    case dcoSaw
    case dcoSub
    case dcoRange
    case dcoSubLevel
    case dcoNoiseLevel
    case hpfCutoff
    case chorus
    case dcoLfoDepth
    case dcoEnvDepth
    case dcoAfterDepth
    case dcoPwDepth
    case dcoPwmRate
    case vcfCutoff
    case vcfResonance
    case vcfLfoDepth
    case vcfEnvDepth
    case vcfKeyFollow
    case vcfAfterDepth
    case vcaLevel
    case vcaAfterDepth
    case lfoRate
    case lfoDelay
    case envT1
    case envL1
    case envT2
    case envL2
    case envT3
    case envL3
    case envT4
    case envKeyFollow
    case chorusRate
    case benderRange

    // MARK: Patch parameters
    case keyMode = 64
    case portaTime
    case portaSwitch
    case modSensitivity
    case volume
    case chordIndex
    case midiChannel
    case keyShift

    // MARK: Extensions in the style of TAL-Pha (not on the hardware)
    case pulseDetune
    case pulseSync
    case pulseEnvMod
    case voiceDrift
    case unisonDetune

    // MARK: Effects (delay / reverb, as in TAL-Pha's FX section)
    case delayMix
    case delayTime
    case delayFeedback
    case delaySync
    case delayDivision
    case delayTone
    case delayPingPong
    case reverbMix
    case reverbSize
    case reverbDamp
    case tempo

    // MARK: LFO extensions (the hardware LFO is triangle-only and free-running)
    case lfoWave
    case lfoSync
    case lfoDivision
    case lfoKeySync

    // MARK: Continuous high-pass (addition to the 4-step hardware HPF)
    case hpfFreq

    // MARK: Envelope trigger in MONO / UNISON / CHORD
    /// MULTI restarts the envelope on every new note (sequences), LEGATO only
    /// when no key was held (bound notes glide without a new attack).
    case envRetrigger

    // MARK: Arpeggiator (tempo-synced, plays through the current key mode)
    case arpOn
    case arpMode
    case arpRate
    case arpOctaves
    case arpGate
    case arpHold

    // MARK: Step sequencer (16 steps, transposed by the held key)
    case seqOn
    case seqStyle
    case seqRate
    case seqLength
    case seqGate
    case seqStep0
    case seqStep1
    case seqStep2
    case seqStep3
    case seqStep4
    case seqStep5
    case seqStep6
    case seqStep7
    case seqStep8
    case seqStep9
    case seqStep10
    case seqStep11
    case seqStep12
    case seqStep13
    case seqStep14
    case seqStep15
    /// Per-step gate variation (appended so the step addresses stay put).
    case seqGateVar

    // MARK: Distortion (acid style, before chorus / delay / reverb)
    case distMode
    case distDrive
    case distTone
    case distLevel
    case distMix

    static let toneParameterCount = 36
    static let storageSize = 128

    static var toneParams: [Param] { allCases.filter { $0.isTone } }
    static var patchParams: [Param] { allCases.filter { !$0.isTone } }

    var id: Int { rawValue }
    var address: AUParameterAddress { AUParameterAddress(rawValue) }
    var isTone: Bool { rawValue < Param.toneParameterCount }

    /// 0...15 for the sequencer step parameters, else nil.
    var seqStepIndex: Int? {
        let i = rawValue - Param.seqStep0.rawValue
        return (0..<StepSequencer.maxSteps).contains(i) ? i : nil
    }

    static func seqStep(_ index: Int) -> Param {
        Param(rawValue: Param.seqStep0.rawValue + index)!
    }

    /// Arpeggiator / sequencer settings. While one of them runs, loading a
    /// sound keeps them, so the pattern plays on with the new sound.
    var isPerformance: Bool {
        (Param.arpOn.rawValue...Param.arpHold.rawValue).contains(rawValue)
            || (Param.seqOn.rawValue...Param.seqGateVar.rawValue).contains(rawValue)
    }

    /// Device settings are not stored in sounds / presets.
    var isDeviceSetting: Bool { self == .midiChannel || self == .tempo }

    var maxValue: Int {
        switch self {
        case .dcoEnvMode, .vcfEnvMode, .vcaEnvMode, .dcoPulse, .dcoRange,
             .dcoSubLevel, .dcoNoiseLevel, .hpfCutoff:
            return 3
        case .dcoSaw, .dcoSub:
            return 5
        case .chorus, .pulseSync, .delaySync, .delayPingPong, .lfoSync, .lfoKeySync,
             .envRetrigger, .arpOn, .arpHold, .seqOn:
            return 1
        case .seqStyle:
            return SequenceGenerator.styleNames.count - 1
        case .distMode:
            return AcidDistortion.modeNames.count - 1
        case .seqRate:
            return LFOShape.divisionNames.count - 1
        case .seqLength:
            return StepSequencer.maxSteps - 1
        case .arpMode:
            return Arpeggiator.modeNames.count - 1
        case .arpRate:
            return LFOShape.divisionNames.count - 1
        case .arpOctaves:
            return 3
        case .lfoWave:
            return LFOShape.names.count - 1
        case .lfoDivision:
            return LFOShape.divisionNames.count - 1
        case .delayDivision:
            return DelayDivision.names.count - 1
        case .tempo:
            return 200
        case .benderRange:
            return 12
        case .keyMode:
            return 3
        case .portaSwitch:
            return 2
        case .chordIndex:
            return 15
        case .midiChannel:
            return 16
        case .keyShift:
            return 24
        default:
            return 127
        }
    }

    var isDiscrete: Bool { valueStrings != nil }

    var valueStrings: [String]? {
        switch self {
        case .dcoEnvMode, .vcfEnvMode:
            return ["ENV", "INV", "ENV-D", "INV-D"]
        case .vcaEnvMode:
            return ["ENV", "GATE", "ENV-D", "GATE-D"]
        case .dcoRange:
            return ["16'", "8'", "4'", "2'"]
        case .dcoPulse, .dcoSubLevel, .dcoNoiseLevel, .hpfCutoff:
            return ["0", "1", "2", "3"]
        case .dcoSaw, .dcoSub:
            return ["0", "1", "2", "3", "4", "5"]
        case .chorus, .pulseSync, .delaySync, .delayPingPong, .lfoSync, .lfoKeySync:
            return ["OFF", "ON"]
        case .lfoWave:
            return LFOShape.names
        case .lfoDivision:
            return LFOShape.divisionNames
        case .delayDivision:
            return DelayDivision.names
        case .keyMode:
            return ["POLY", "CHORD", "MONO", "UNISON"]
        case .portaSwitch:
            return ["OFF", "ON", "AUTO"]
        case .envRetrigger:
            return ["MULTI", "LEGATO"]
        case .arpOn, .arpHold, .seqOn:
            return ["OFF", "ON"]
        case .seqStyle:
            return SequenceGenerator.styleNames
        case .distMode:
            return AcidDistortion.modeNames
        case .seqRate:
            return LFOShape.divisionNames
        case .seqLength:
            return (1...StepSequencer.maxSteps).map { "\($0)" }
        case .arpMode:
            return Arpeggiator.modeNames
        case .arpRate:
            return LFOShape.divisionNames
        case .arpOctaves:
            return ["1", "2", "3", "4"]
        case .chordIndex:
            return ChordMemory.defaultNames
        case .midiChannel:
            return ["OMNI"] + (1...16).map { "\($0)" }
        case .keyShift:
            return (-12...12).map { $0 > 0 ? "+\($0)" : "\($0)" }
        default:
            return nil
        }
    }

    var defaultValue: Int {
        switch self {
        case .dcoRange: return 1
        case .dcoSaw: return 1
        case .hpfCutoff: return 1
        case .vcfCutoff: return 127
        case .vcaLevel: return 110
        case .lfoRate: return 64
        case .envL1, .envL2, .envL3: return 127
        case .envT4: return 20
        case .chorusRate: return 60
        case .benderRange: return 2
        case .portaTime: return 30
        case .modSensitivity: return 64
        case .volume: return 100
        case .keyShift: return 12
        case .pulseDetune: return 64
        case .voiceDrift: return 8
        case .unisonDetune: return 40
        case .delayTime: return 64
        case .delayFeedback: return 50
        case .delaySync: return 1
        case .delayDivision: return 6
        case .delayTone: return 80
        case .delayPingPong: return 1
        case .reverbSize: return 60
        case .reverbDamp: return 50
        case .tempo: return 80
        case .lfoDivision: return 8      // 1/4
        case .arpRate: return 2          // 1/16
        case .arpGate: return 80
        case .seqRate: return 2          // 1/16
        case .seqLength: return 15       // 16 steps
        case .seqGate: return 70
        case .distDrive: return 64
        case .distTone: return 80
        case .distLevel: return 64
        case .distMix: return 127
        default: return 0
        }
    }

    /// AU parameter identifiers may not contain "." (key paths), " " or "/".
    var identifier: String {
        "p\(rawValue)_" + shortName.filter { $0 != " " && $0 != "/" && $0 != "." }
    }

    /// Name as printed in the MKS-50 owner's manual.
    var displayName: String {
        switch self {
        case .dcoEnvMode: return "DCO Env Mode"
        case .vcfEnvMode: return "VCF Env Mode"
        case .vcaEnvMode: return "VCA Env Mode"
        case .dcoPulse: return "DCO Pulse Wave"
        case .dcoSaw: return "DCO Sawtooth Wave"
        case .dcoSub: return "DCO Sub Wave"
        case .dcoRange: return "DCO Range"
        case .dcoSubLevel: return "DCO Sub Level"
        case .dcoNoiseLevel: return "DCO Noise Level"
        case .hpfCutoff: return "HPF Cutoff"
        case .chorus: return "Chorus"
        case .dcoLfoDepth: return "DCO LFO Depth"
        case .dcoEnvDepth: return "DCO Env Depth"
        case .dcoAfterDepth: return "DCO After Depth"
        case .dcoPwDepth: return "DCO PW/PWM Depth"
        case .dcoPwmRate: return "DCO PWM Rate"
        case .vcfCutoff: return "VCF Cutoff"
        case .vcfResonance: return "VCF Resonance"
        case .vcfLfoDepth: return "VCF LFO Depth"
        case .vcfEnvDepth: return "VCF Env Depth"
        case .vcfKeyFollow: return "VCF Key Follow"
        case .vcfAfterDepth: return "VCF After Depth"
        case .vcaLevel: return "VCA Level"
        case .vcaAfterDepth: return "VCA After Depth"
        case .lfoRate: return "LFO Rate"
        case .lfoDelay: return "LFO Delay"
        case .envT1: return "Env T1"
        case .envL1: return "Env L1"
        case .envT2: return "Env T2"
        case .envL2: return "Env L2"
        case .envT3: return "Env T3"
        case .envL3: return "Env L3"
        case .envT4: return "Env T4"
        case .envKeyFollow: return "Env Key Follow"
        case .chorusRate: return "Chorus Rate"
        case .benderRange: return "Bender Range"
        case .keyMode: return "Key Mode"
        case .portaTime: return "Portamento Time"
        case .portaSwitch: return "Portamento"
        case .modSensitivity: return "Mod Sensitivity"
        case .volume: return "Volume"
        case .chordIndex: return "Chord Memory"
        case .midiChannel: return "MIDI Channel"
        case .keyShift: return "Key Shift"
        case .pulseDetune: return "Pulse Detune"
        case .pulseSync: return "Pulse Sync"
        case .pulseEnvMod: return "Pulse Env Mod"
        case .voiceDrift: return "Voice Drift"
        case .unisonDetune: return "Unison Detune"
        case .delayMix: return "Delay Mix"
        case .delayTime: return "Delay Time"
        case .delayFeedback: return "Delay Feedback"
        case .delaySync: return "Delay Sync"
        case .delayDivision: return "Delay Division"
        case .delayTone: return "Delay Tone"
        case .delayPingPong: return "Delay Ping-Pong"
        case .reverbMix: return "Reverb Mix"
        case .reverbSize: return "Reverb Size"
        case .reverbDamp: return "Reverb Damping"
        case .tempo: return "Tempo"
        case .lfoWave: return "LFO Waveform"
        case .lfoSync: return "LFO Tempo Sync"
        case .lfoDivision: return "LFO Sync Rate"
        case .lfoKeySync: return "LFO Key Sync"
        case .hpfFreq: return "HPF Frequency"
        case .envRetrigger: return "Envelope Trigger"
        case .arpOn: return "Arpeggiator"
        case .arpMode: return "Arp Mode"
        case .arpRate: return "Arp Rate"
        case .arpOctaves: return "Arp Octaves"
        case .arpGate: return "Arp Gate"
        case .arpHold: return "Arp Hold"
        case .seqOn: return "Sequencer"
        case .seqStyle: return "Sequence Style"
        case .seqRate: return "Sequencer Rate"
        case .seqLength: return "Sequencer Steps"
        case .seqGate: return "Sequencer Gate"
        case .seqGateVar: return "Sequencer Gate Variation"
        case .distMode: return "Distortion"
        case .distDrive: return "Distortion Drive"
        case .distTone: return "Distortion Tone"
        case .distLevel: return "Distortion Level"
        case .distMix: return "Distortion Mix"
        case .seqStep0, .seqStep1, .seqStep2, .seqStep3, .seqStep4, .seqStep5, .seqStep6, .seqStep7,
             .seqStep8, .seqStep9, .seqStep10, .seqStep11, .seqStep12, .seqStep13, .seqStep14, .seqStep15:
            return "Step \(rawValue - Param.seqStep0.rawValue + 1)"
        }
    }

    /// Short panel label.
    var shortName: String {
        switch self {
        case .dcoEnvMode, .vcfEnvMode: return "ENV MODE"
        case .vcaEnvMode: return "MODE"
        case .dcoPulse: return "PULSE"
        case .dcoSaw: return "SAW"
        case .dcoSub: return "SUB"
        case .dcoRange: return "RANGE"
        case .dcoSubLevel: return "SUB LVL"
        case .dcoNoiseLevel: return "NOISE"
        case .hpfCutoff: return "HPF"
        case .chorus: return "CHORUS"
        case .dcoLfoDepth, .vcfLfoDepth: return "LFO"
        case .dcoEnvDepth, .vcfEnvDepth: return "ENV"
        case .dcoAfterDepth, .vcfAfterDepth, .vcaAfterDepth: return "AFTER"
        case .dcoPwDepth: return "PW/PWM"
        case .dcoPwmRate: return "PWM RATE"
        case .vcfCutoff: return "CUTOFF"
        case .vcfResonance: return "RESO"
        case .vcfKeyFollow, .envKeyFollow: return "KEY"
        case .vcaLevel: return "LEVEL"
        case .lfoRate, .chorusRate: return "RATE"
        case .lfoDelay: return "DELAY"
        case .envT1: return "T1"
        case .envL1: return "L1"
        case .envT2: return "T2"
        case .envL2: return "L2"
        case .envT3: return "T3"
        case .envL3: return "L3"
        case .envT4: return "T4"
        case .benderRange: return "BEND"
        case .keyMode: return "KEY MODE"
        case .portaTime: return "PORTA"
        case .portaSwitch: return "PORTA SW"
        case .modSensitivity: return "MOD SENS"
        case .volume: return "VOLUME"
        case .chordIndex: return "CHORD"
        case .midiChannel: return "MIDI CH"
        case .keyShift: return "KEY SHIFT"
        case .pulseDetune: return "PLS TUNE"
        case .pulseSync: return "SYNC"
        case .pulseEnvMod: return "PLS ENV"
        case .voiceDrift: return "DRIFT"
        case .unisonDetune: return "UNI DETUNE"
        case .delayMix, .reverbMix: return "MIX"
        case .delayTime: return "TIME"
        case .delayFeedback: return "FEEDBACK"
        case .delaySync: return "SYNC"
        case .delayDivision: return "NOTE"
        case .delayTone: return "TONE"
        case .delayPingPong: return "PING-PONG"
        case .reverbSize: return "SIZE"
        case .reverbDamp: return "DAMP"
        case .tempo: return "BPM"
        case .lfoWave: return "WAVE"
        case .lfoSync: return "TEMPO SYNC"
        case .lfoDivision: return "NOTE"
        case .lfoKeySync: return "KEY SYNC"
        case .hpfFreq: return "HPF FREQ"
        case .envRetrigger: return "TRIGGER"
        case .arpOn: return "ARP"
        case .arpMode: return "MODE"
        case .arpRate: return "RATE"
        case .arpOctaves: return "OCTAVES"
        case .arpGate: return "GATE"
        case .arpHold: return "HOLD"
        case .seqOn: return "SEQ"
        case .seqStyle: return "STYLE"
        case .seqRate: return "RATE"
        case .seqLength: return "STEPS"
        case .seqGate: return "GATE"
        case .seqGateVar: return "G.VAR"
        case .distMode: return "DIST"
        case .distDrive: return "DRIVE"
        case .distTone: return "TONE"
        case .distLevel: return "LEVEL"
        case .distMix: return "MIX"
        case .seqStep0, .seqStep1, .seqStep2, .seqStep3, .seqStep4, .seqStep5, .seqStep6, .seqStep7,
             .seqStep8, .seqStep9, .seqStep10, .seqStep11, .seqStep12, .seqStep13, .seqStep14, .seqStep15:
            return "STEP \(rawValue - Param.seqStep0.rawValue + 1)"
        }
    }

    func string(for value: Float) -> String {
        if self == .tempo { return "\(Int(value.rounded()) + 40)" }
        if self == .hpfFreq {
            guard value >= 0.5 else { return "OFF" }
            let hz = SynthEngine.hpfSweepHz(value)
            return hz < 1000 ? "\(Int(hz)) Hz" : String(format: "%.1f kHz", hz / 1000)
        }
        if self == .arpGate || self == .seqGate {
            return "\(Int(Arpeggiator.gateFraction(value) * 100)) %"
        }
        if self == .seqGateVar {
            return "\(Int((value / 127 * 100).rounded())) %"
        }
        if seqStepIndex != nil {
            return SeqStep(raw: Int(value.rounded()))?.label ?? "REST"
        }
        if self == .lfoRate {
            let hz = 0.1 * powf(300, value / 127)
            return hz < 10 ? String(format: "%.2f Hz", hz) : String(format: "%.1f Hz", hz)
        }
        if self == .delayTime {
            let ms = SynthEngine.delaySeconds(value) * 1000
            return ms < 1000 ? "\(Int(ms)) ms" : String(format: "%.2f s", ms / 1000)
        }
        if self == .pulseDetune {
            let semis = (value - 64) / 64 * 12
            return abs(semis) < 0.05 ? "0" : String(format: "%+.1f", semis)
        }
        let i = Int(value.rounded())
        if let strings = valueStrings, strings.indices.contains(i) { return strings[i] }
        return "\(i)"
    }
}
