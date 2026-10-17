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

    static let toneParameterCount = 36
    static let storageSize = 128

    static var toneParams: [Param] { allCases.filter { $0.isTone } }
    static var patchParams: [Param] { allCases.filter { !$0.isTone } }

    var id: Int { rawValue }
    var address: AUParameterAddress { AUParameterAddress(rawValue) }
    var isTone: Bool { rawValue < Param.toneParameterCount }

    var maxValue: Int {
        switch self {
        case .dcoEnvMode, .vcfEnvMode, .vcaEnvMode, .dcoPulse, .dcoRange,
             .dcoSubLevel, .dcoNoiseLevel, .hpfCutoff:
            return 3
        case .dcoSaw, .dcoSub:
            return 5
        case .chorus, .portaSwitch, .pulseSync:
            return 1
        case .benderRange:
            return 12
        case .keyMode:
            return 3
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
        case .chorus, .portaSwitch, .pulseSync:
            return ["OFF", "ON"]
        case .keyMode:
            return ["POLY", "CHORD", "MONO", "UNISON"]
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
        case .voiceDrift: return 24
        case .unisonDetune: return 40
        default: return 0
        }
    }

    var identifier: String { "p\(rawValue)_" + shortName.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "/", with: "") }

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
        }
    }

    func string(for value: Float) -> String {
        if self == .pulseDetune {
            let semis = (value - 64) / 64 * 12
            return abs(semis) < 0.05 ? "0" : String(format: "%+.1f", semis)
        }
        let i = Int(value.rounded())
        if let strings = valueStrings, strings.indices.contains(i) { return strings[i] }
        return "\(i)"
    }
}
