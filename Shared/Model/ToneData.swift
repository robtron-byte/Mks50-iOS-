import Foundation

/// A complete sound: the 36 MKS-50 tone parameters, the tone name and the
/// patch-level performance settings.
struct ToneData: Codable, Equatable {
    var name: String
    /// Raw values for tone parameters #0...#35 (MKS-50 numbering).
    var tone: [Int]
    /// Patch parameters keyed by `Param.rawValue`.
    var patch: [Int: Int]
    /// Optional chord memory contents.
    var chords: [[Int]]?
    /// Preset category (factory sounds); nil for user / SysEx sounds.
    var category: PresetCategory?

    init(name: String, tone: [Int], patch: [Int: Int] = [:], chords: [[Int]]? = nil,
         category: PresetCategory? = nil) {
        precondition(tone.count == Param.toneParameterCount, "A tone needs exactly 36 values")
        self.name = name
        self.tone = tone
        self.patch = patch
        self.chords = chords
        self.category = category
    }

    static var initTone: ToneData {
        ToneData(name: "INIT TONE",
                 tone: Param.toneParams.map { $0.defaultValue },
                 patch: Dictionary(uniqueKeysWithValues: Param.patchParams.map { ($0.rawValue, $0.defaultValue) }))
    }

    func value(_ p: Param) -> Int? {
        p.isTone ? tone[p.rawValue] : patch[p.rawValue]
    }
}

/// Preset categories, in browsing order.
enum PresetCategory: String, CaseIterable, Codable {
    case initTone = "Init"
    case bass = "Bass"
    case lead = "Lead"
    case sequence = "Sequence"
    case zap = "Electro Zaps"
    case stab = "Stab"
    case keys = "Keys"
    case stringsBrass = "Strings & Brass"
    case pad = "Pad"
    case fxPerc = "FX & Perc"

    var icon: String {
        switch self {
        case .initTone: return "circle.dashed"
        case .bass: return "speaker.wave.3.fill"
        case .lead: return "music.mic"
        case .sequence: return "square.grid.3x3.fill"
        case .zap: return "bolt.horizontal.fill"
        case .stab: return "bolt.fill"
        case .keys: return "pianokeys"
        case .stringsBrass: return "music.quarternote.3"
        case .pad: return "cloud.fill"
        case .fxPerc: return "sparkles"
        }
    }

    /// Short label for the LCD.
    var short: String {
        switch self {
        case .initTone: return "INIT"
        case .bass: return "BASS"
        case .lead: return "LEAD"
        case .sequence: return "SEQ"
        case .zap: return "ZAP"
        case .stab: return "STAB"
        case .keys: return "KEYS"
        case .stringsBrass: return "STR"
        case .pad: return "PAD"
        case .fxPerc: return "FX"
        }
    }
}

/// MKS-50 / Alpha Juno SysEx support (Roland "APR" all-parameter and
/// "IPR" individual-parameter messages, tone level).
enum MKS50SysEx {
    static let rolandID: UInt8 = 0x41
    static let opAPR: UInt8 = 0x35
    static let opIPR: UInt8 = 0x36
    static let formatType: UInt8 = 0x23   // MKS-50 / Alpha Juno
    static let levelTone: UInt8 = 0x20
    static let group: UInt8 = 0x01

    enum Message {
        case tone(ToneData)
        case parameter(Param, Int)
    }

    /// MKS-50 character table for tone names.
    private static let charset: [Character] = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 -")

    static func decodeName(_ bytes: ArraySlice<UInt8>) -> String {
        String(bytes.map { b -> Character in
            let i = Int(b & 0x3F)
            return charset[i]
        }).trimmingCharacters(in: .whitespaces)
    }

    static func encodeName(_ name: String) -> [UInt8] {
        let padded = Array(name.prefix(10)).map { ch -> UInt8 in
            if let i = charset.firstIndex(of: ch) { return UInt8(i) }
            if let up = ch.uppercased().first, let i = charset.firstIndex(of: up) { return UInt8(i) }
            return 62 // space
        }
        return padded + Array(repeating: 62, count: 10 - padded.count)
    }

    /// Hardware sometimes transmits switch-type values scaled to 0...127.
    /// Accept both representations.
    static func normalize(_ value: Int, for p: Param) -> Int {
        let v = max(0, min(127, value))
        if v <= p.maxValue { return v }
        return min(p.maxValue, v * (p.maxValue + 1) / 128)
    }

    /// Splits a byte stream (e.g. a .syx file) into individual F0...F7 messages.
    static func split(_ data: [UInt8]) -> [[UInt8]] {
        var result: [[UInt8]] = []
        var current: [UInt8]?
        for b in data {
            if b == 0xF0 { current = [b] }
            else if current != nil {
                current!.append(b)
                if b == 0xF7 { result.append(current!); current = nil }
            }
        }
        return result
    }

    static func parse(_ msg: [UInt8]) -> Message? {
        guard msg.count >= 10, msg[0] == 0xF0, msg[1] == rolandID,
              msg[4] == formatType, msg[5] == levelTone || msg[5] == 0x01 else { return nil }
        switch msg[2] {
        case opIPR:
            guard let p = Param(rawValue: Int(msg[7])), p.isTone else { return nil }
            return .parameter(p, normalize(Int(msg[8]), for: p))
        case opAPR:
            let toneStart = 7
            let nameStart = toneStart + Param.toneParameterCount
            guard msg.count >= nameStart + 10 + 1 else { return nil }
            let values = Param.toneParams.map { normalize(Int(msg[toneStart + $0.rawValue]), for: $0) }
            let name = decodeName(msg[nameStart..<(nameStart + 10)])
            return .tone(ToneData(name: name.isEmpty ? "SYSEX TONE" : name, tone: values))
        default:
            return nil
        }
    }

    static func toneAPR(_ tone: ToneData, channel: Int = 0) -> [UInt8] {
        var msg: [UInt8] = [0xF0, rolandID, opAPR, UInt8(channel & 0x0F), formatType, levelTone, group]
        msg += tone.tone.map { UInt8(max(0, min(127, $0))) }
        msg += encodeName(tone.name)
        msg.append(0xF7)
        return msg
    }

    static func parameterIPR(_ p: Param, value: Int, channel: Int = 0) -> [UInt8] {
        [0xF0, rolandID, opIPR, UInt8(channel & 0x0F), formatType, levelTone, group,
         UInt8(p.rawValue), UInt8(max(0, min(127, value))), 0xF7]
    }
}
