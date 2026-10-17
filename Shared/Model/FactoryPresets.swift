import Foundation

/// Original factory sounds programmed in MKS-50 parameter space.
///
/// Value order (MKS-50 tone parameter numbers):
///  ENV MODES  dco vcf vca | WAVE pulse saw sub | range subLvl noise | hpf chorus |
///  DCO lfo env after pw pwmRate | VCF cutoff reso lfo env key after |
///  VCA level after | LFO rate delay | ENV T1 L1 T2 L2 T3 L3 T4 key | chorusRate bender
enum FactoryPresets {
    static let all: [ToneData] = [
        make("INIT TONE",
             [0, 0, 0,  0, 1, 0,  1, 0, 0,  1, 0,
              0, 0, 0, 0, 0,  127, 0, 0, 0, 0, 0,  110, 0,  64, 0,
              0, 127, 0, 127, 0, 127, 20, 0,  60, 2]),

        make("HOOVER",
             [1, 0, 0,  3, 5, 3,  1, 2, 0,  1, 1,
              0, 38, 20, 88, 92,  112, 8, 0, 0, 40, 0,  118, 0,  70, 0,
              0, 127, 34, 96, 60, 84, 46, 0,  98, 2],
             keyMode: 2, porta: 1, portaTime: 46),

        make("JUNO BRASS",
             [0, 0, 2,  0, 1, 0,  1, 0, 0,  1, 1,
              0, 0, 0, 0, 0,  38, 18, 0, 86, 64, 20,  112, 10,  64, 0,
              34, 127, 62, 92, 60, 88, 42, 20,  52, 2]),

        make("WARM PAD",
             [0, 0, 0,  2, 1, 0,  1, 0, 0,  2, 1,
              0, 0, 0, 72, 30,  62, 14, 6, 38, 52, 0,  104, 0,  44, 0,
              84, 127, 84, 108, 70, 100, 84, 0,  40, 2]),

        make("FAT BASS",
             [0, 0, 2,  0, 1, 1,  0, 3, 0,  0, 0,
              0, 0, 0, 0, 0,  28, 52, 0, 74, 40, 0,  124, 0,  64, 0,
              0, 127, 52, 36, 54, 30, 16, 0,  60, 2],
             keyMode: 2),

        make("SUB BASS",
             [0, 0, 0,  1, 0, 3,  1, 3, 0,  0, 0,
              0, 0, 0, 0, 0,  24, 10, 0, 40, 30, 0,  126, 0,  64, 0,
              0, 127, 60, 80, 60, 80, 14, 0,  60, 2],
             keyMode: 2, porta: 1, portaTime: 18),

        make("PLUCK KEYS",
             [0, 2, 2,  1, 1, 0,  1, 0, 0,  1, 1,
              0, 0, 0, 0, 0,  46, 26, 0, 80, 96, 0,  116, 0,  64, 0,
              0, 127, 46, 20, 50, 0, 40, 40,  70, 2]),

        make("STRINGS",
             [0, 0, 0,  0, 2, 0,  1, 0, 0,  2, 1,
              10, 0, 18, 60, 42,  72, 6, 0, 18, 40, 10,  108, 8,  74, 60,
              70, 127, 70, 118, 70, 118, 74, 0,  74, 2]),

        make("ACID LINE",
             [0, 0, 2,  0, 1, 0,  1, 0, 0,  1, 0,
              0, 0, 0, 0, 0,  20, 112, 0, 88, 60, 0,  120, 0,  64, 0,
              0, 127, 42, 0, 50, 0, 18, 0,  60, 2],
             keyMode: 2, porta: 1, portaTime: 22),

        make("GLASS BELL",
             [0, 0, 2,  3, 0, 0,  2, 0, 0,  3, 1,
              0, 0, 0, 40, 0,  92, 30, 0, 30, 100, 0,  118, 0,  64, 0,
              0, 127, 90, 30, 96, 0, 92, 60,  86, 2]),

        make("SYNC LEAD",
             [0, 0, 0,  2, 3, 0,  1, 0, 0,  1, 1,
              34, 46, 30, 60, 0,  86, 30, 0, 30, 60, 0,  118, 0,  80, 64,
              0, 127, 40, 90, 60, 90, 30, 0,  66, 2],
             keyMode: 2, porta: 1, portaTime: 34),

        make("NOISE SWEEP",
             [0, 0, 0,  0, 0, 0,  1, 0, 3,  1, 1,
              0, 0, 0, 0, 0,  14, 96, 74, 50, 0, 0,  108, 0,  22, 0,
              104, 127, 80, 110, 80, 110, 96, 0,  30, 2]),

        make("ORGAN",
             [0, 0, 1,  1, 0, 1,  1, 2, 0,  1, 1,
              6, 0, 10, 0, 0,  94, 0, 0, 0, 40, 0,  110, 0,  82, 50,
              0, 127, 0, 127, 0, 127, 6, 0,  112, 2]),

        make("HOUSE STAB",
             [0, 0, 2,  1, 1, 0,  1, 0, 0,  2, 1,
              0, 0, 0, 0, 0,  56, 30, 0, 62, 50, 0,  110, 0,  64, 0,
              0, 127, 44, 40, 52, 0, 30, 0,  56, 2],
             keyMode: 1, chord: 0),

        make("WOBBLE",
             [0, 0, 0,  0, 4, 1,  1, 2, 0,  1, 0,
              0, 0, 0, 56, 70,  48, 70, 84, 0, 40, 0,  120, 0,  70, 0,
              0, 127, 0, 127, 0, 127, 20, 0,  60, 2],
             keyMode: 2),

        make("DARK DRONE",
             [0, 1, 0,  2, 5, 5,  0, 2, 1,  0, 1,
              4, 0, 0, 100, 18,  36, 62, 12, 24, 20, 0,  110, 0,  18, 90,
              100, 127, 90, 100, 90, 100, 110, 0,  24, 2]),
    ]

    private static func make(_ name: String, _ tone: [Int],
                             keyMode: Int = 0, porta: Int = 0, portaTime: Int = 30,
                             chord: Int = 0, volume: Int = 100) -> ToneData {
        var patch = Dictionary(uniqueKeysWithValues: Param.patchParams.map { ($0.rawValue, $0.defaultValue) })
        patch[Param.keyMode.rawValue] = keyMode
        patch[Param.portaSwitch.rawValue] = porta
        patch[Param.portaTime.rawValue] = portaTime
        patch[Param.chordIndex.rawValue] = chord
        patch[Param.volume.rawValue] = volume
        // MIDI channel is a device setting, not part of a sound.
        patch.removeValue(forKey: Param.midiChannel.rawValue)
        return ToneData(name: name, tone: tone, patch: patch)
    }
}
