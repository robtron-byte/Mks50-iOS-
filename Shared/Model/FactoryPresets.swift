import Foundation

/// Original factory sounds programmed in MKS-50 parameter space.
///
/// Value order (MKS-50 tone parameter numbers):
///  ENV MODES  dco vcf vca | WAVE pulse saw sub | range subLvl noise | hpf chorus |
///  DCO lfo env after pw pwmRate | VCF cutoff reso lfo env key after |
///  VCA level after | LFO rate delay | ENV T1 L1 T2 L2 T3 L3 T4 key | chorusRate bender
enum FactoryPresets {
    /// All factory sounds, sorted by category (stable within a category), so
    /// the preset arrows browse category by category.
    static let all: [ToneData] = source.enumerated().sorted { a, b in
        let ca = PresetCategory.allCases.firstIndex(of: a.element.category ?? .initTone) ?? 0
        let cb = PresetCategory.allCases.firstIndex(of: b.element.category ?? .initTone) ?? 0
        return ca != cb ? ca < cb : a.offset < b.offset
    }.map { $0.element }

    private static let source: [ToneData] = [
        make(.initTone, "INIT TONE",
             [0, 0, 0,  0, 1, 0,  1, 0, 0,  1, 0,
              0, 0, 0, 0, 0,  127, 0, 0, 0, 0, 0,  110, 0,  64, 0,
              0, 127, 0, 127, 0, 127, 20, 0,  60, 2]),

        make(.lead, "HOOVER",
             [1, 0, 0,  2, 5, 3,  1, 2, 0,  1, 1,
              0, 38, 20, 88, 92,  112, 8, 0, 0, 40, 0,  118, 0,  70, 0,
              0, 127, 34, 96, 60, 84, 46, 0,  98, 2],
             keyMode: 2, porta: 1, portaTime: 46),

        make(.stringsBrass, "JUNO BRASS",
             [0, 0, 2,  0, 1, 0,  1, 0, 0,  1, 1,
              0, 0, 0, 0, 0,  38, 18, 0, 86, 64, 20,  112, 10,  64, 0,
              34, 127, 62, 92, 60, 88, 42, 20,  52, 2]),

        make(.pad, "WARM PAD",
             [0, 0, 0,  3, 1, 0,  1, 0, 0,  2, 1,
              0, 0, 0, 72, 30,  62, 14, 6, 38, 52, 0,  104, 0,  44, 0,
              84, 127, 84, 108, 70, 100, 84, 0,  40, 2]),

        make(.bass, "FAT BASS",
             [0, 0, 2,  0, 1, 1,  2, 3, 0,  0, 0,
              0, 0, 0, 0, 0,  28, 52, 0, 74, 40, 0,  124, 0,  64, 0,
              0, 127, 52, 36, 54, 30, 16, 0,  60, 2],
             keyMode: 2),

        make(.bass, "SUB BASS",
             [0, 0, 0,  1, 0, 3,  1, 3, 0,  0, 0,
              0, 0, 0, 0, 0,  24, 10, 0, 40, 30, 0,  126, 0,  64, 0,
              0, 127, 60, 80, 60, 80, 14, 0,  60, 2],
             keyMode: 2, porta: 1, portaTime: 18),

        make(.keys, "PLUCK KEYS",
             [0, 2, 2,  1, 1, 0,  1, 0, 0,  1, 1,
              0, 0, 0, 0, 0,  46, 26, 0, 80, 96, 0,  116, 0,  64, 0,
              0, 127, 46, 20, 50, 0, 40, 40,  70, 2]),

        make(.stringsBrass, "STRINGS",
             [0, 0, 0,  0, 2, 0,  1, 0, 0,  2, 1,
              10, 0, 18, 60, 42,  72, 6, 0, 18, 40, 10,  108, 8,  74, 60,
              70, 127, 70, 118, 70, 118, 74, 0,  74, 2]),

        // TB-303 style: the VCA follows the gate (GATE-D, accents via
        // velocity), the envelope only sweeps the resonant filter. Ties
        // slide (portamento AUTO) without retriggering the envelope.
        // Hold a key (or HOLD + play) to run the line.
        make(.bass, "ACID LINE",
             [0, 0, 3,  0, 1, 0,  1, 0, 0,  1, 0,
              0, 0, 0, 0, 0,  22, 116, 0, 92, 50, 0,  118, 0,  64, 0,
              0, 127, 58, 18, 45, 10, 14, 0,  60, 2],
             keyMode: 2, porta: 2, portaTime: 14,
             extra: [.envRetrigger: 1,
                     .seqOn: 1, .seqStyle: 3, .seqGate: 45, .seqGateVar: 45,
                     .distMode: 2, .distDrive: 52, .distTone: 72, .distLevel: 64, .distMix: 100,
                     .delayMix: 22, .delayDivision: 6, .delayFeedback: 35,
                     .seqStep0: 45, .seqStep1: 13, .seqStep2: 25, .seqStep3: 77, .seqStep4: 16, .seqStep5: 0, .seqStep6: 45, .seqStep7: 87, .seqStep8: 25, .seqStep9: 13, .seqStep10: 0, .seqStep11: 52, .seqStep12: 13, .seqStep13: 80, .seqStep14: 18, .seqStep15: 57]),

        make(.keys, "GLASS BELL",
             [0, 0, 2,  2, 0, 0,  0, 0, 0,  3, 1,
              0, 0, 0, 40, 0,  92, 30, 0, 30, 100, 0,  118, 0,  64, 0,
              0, 127, 90, 30, 96, 0, 92, 60,  86, 2]),

        make(.lead, "SYNC LEAD",
             [0, 0, 0,  3, 3, 0,  1, 0, 0,  1, 1,
              34, 46, 30, 60, 0,  86, 30, 0, 30, 60, 0,  118, 0,  80, 64,
              0, 127, 40, 90, 60, 90, 30, 0,  66, 2],
             keyMode: 2, porta: 1, portaTime: 34),

        make(.fxPerc, "NOISE SWP",
             [0, 0, 0,  0, 0, 0,  1, 0, 3,  1, 1,
              0, 0, 0, 0, 0,  14, 96, 74, 50, 0, 0,  108, 0,  22, 0,
              104, 127, 80, 110, 80, 110, 96, 0,  30, 2]),

        make(.keys, "ORGAN",
             [0, 0, 1,  1, 0, 1,  1, 2, 0,  1, 1,
              6, 0, 10, 0, 0,  94, 0, 0, 0, 40, 0,  110, 0,  82, 50,
              0, 127, 0, 127, 0, 127, 6, 0,  112, 2]),

        make(.stab, "HOUSE STAB",
             [0, 0, 2,  1, 1, 0,  1, 0, 0,  2, 1,
              0, 0, 0, 0, 0,  56, 30, 0, 62, 50, 0,  110, 0,  64, 0,
              0, 127, 44, 40, 52, 0, 30, 0,  56, 2],
             keyMode: 1, chord: 0),

        make(.bass, "WOBBLE",
             [0, 0, 0,  0, 4, 1,  1, 2, 0,  1, 0,
              0, 0, 0, 56, 70,  48, 70, 84, 0, 40, 0,  120, 0,  70, 0,
              0, 127, 0, 127, 0, 127, 20, 0,  60, 2],
             keyMode: 2),

        make(.lead, "SYNC SWEEP",
             [0, 0, 0,  1, 0, 0,  1, 0, 0,  1, 1,
              20, 0, 20, 0, 0,  100, 20, 0, 20, 40, 0,  112, 0,  76, 70,
              0, 127, 70, 60, 70, 40, 30, 0,  66, 2],
             keyMode: 2, porta: 1, portaTime: 26,
             extra: [.pulseSync: 1, .pulseDetune: 76, .pulseEnvMod: 70]),

        make(.lead, "UNISON SAW",
             [0, 0, 0,  0, 3, 0,  1, 1, 0,  2, 1,
              0, 0, 0, 40, 60,  80, 16, 0, 30, 50, 0,  118, 0,  64, 0,
              10, 127, 60, 100, 60, 100, 40, 0,  48, 2],
             keyMode: 3, porta: 1, portaTime: 20,
             extra: [.unisonDetune: 70, .voiceDrift: 40]),

        make(.pad, "DARK DRONE",
             [0, 1, 0,  3, 5, 5,  2, 2, 1,  0, 1,
              4, 0, 0, 100, 18,  36, 62, 12, 24, 20, 0,  110, 0,  18, 90,
              100, 127, 90, 100, 90, 100, 110, 0,  24, 2]),

        // MARK: Electro funk (in the spirit of Kraftwerk / Anthony Rother)

        make(.bass, "ROBO BASS",
             [0, 0, 2,  1, 1, 0,  2, 2, 0,  1, 0,
              0, 0, 0, 30, 0,  30, 64, 0, 78, 50, 0,  122, 0,  64, 0,
              0, 127, 38, 20, 40, 10, 12, 0,  60, 2],
             keyMode: 2, porta: 1, portaTime: 8),

        make(.sequence, "NUMBERS",
             [0, 0, 0,  1, 0, 0,  0, 0, 0,  2, 0,
              0, 0, 0, 0, 0,  40, 105, 0, 90, 127, 0,  112, 0,  64, 0,
              0, 127, 26, 0, 30, 0, 22, 30,  60, 2],
             extra: [.delayMix: 50, .delayFeedback: 45, .delayDivision: 5, .delayPingPong: 1, .reverbMix: 30]),

        make(.sequence, "CALCULATR",
             [0, 0, 2,  3, 0, 0,  0, 0, 0,  2, 0,
              0, 0, 0, 100, 0,  100, 20, 0, 20, 60, 0,  104, 0,  64, 0,
              0, 127, 20, 0, 20, 0, 14, 0,  60, 2],
             extra: [.keyShift: 24, .delayMix: 40, .delayFeedback: 30, .delayDivision: 2, .reverbMix: 25]),

        make(.stringsBrass, "TRANS EURO",
             [0, 0, 0,  3, 1, 0,  1, 0, 0,  2, 1,
              6, 0, 10, 64, 34,  70, 10, 0, 14, 40, 0,  106, 0,  70, 70,
              70, 127, 70, 118, 70, 118, 76, 0,  44, 2],
             extra: [.reverbMix: 60, .reverbSize: 95, .reverbDamp: 60, .delayMix: 25, .delayDivision: 8]),

        make(.lead, "ROBOT VOX",
             [0, 0, 0,  2, 4, 0,  1, 0, 0,  2, 1,
              10, 0, 0, 50, 20,  58, 90, 30, 10, 40, 0,  112, 0,  40, 60,
              10, 127, 40, 110, 40, 110, 40, 0,  50, 2],
             keyMode: 2, porta: 1, portaTime: 30,
             extra: [.reverbMix: 40, .delayMix: 20, .delayDivision: 6]),

        make(.bass, "AUTO BASS",
             [0, 0, 0,  0, 2, 0,  2, 2, 0,  1, 0,
              0, 0, 0, 0, 0,  36, 40, 0, 64, 50, 0,  122, 0,  64, 0,
              0, 127, 50, 40, 50, 35, 20, 0,  60, 2],
             keyMode: 2, porta: 1, portaTime: 14,
             extra: [.delayMix: 20, .delayDivision: 6, .delayFeedback: 30]),

        make(.stab, "ELEC STAB",
             [0, 0, 2,  3, 1, 0,  1, 0, 0,  2, 1,
              0, 0, 0, 40, 0,  50, 40, 0, 70, 50, 0,  112, 0,  64, 0,
              0, 127, 34, 30, 40, 0, 26, 0,  56, 2],
             keyMode: 1, chord: 2,
             extra: [.delayMix: 45, .delayDivision: 6, .delayFeedback: 45, .delayPingPong: 1, .reverbMix: 40]),

        make(.bass, "ACID ELEC",
             [0, 0, 2,  0, 1, 0,  1, 0, 0,  1, 0,
              0, 0, 0, 0, 0,  26, 112, 0, 84, 60, 0,  120, 0,  64, 0,
              0, 127, 34, 10, 40, 0, 14, 0,  60, 2],
             keyMode: 2, porta: 1, portaTime: 18,
             extra: [.delayMix: 30, .delayDivision: 2, .delayFeedback: 40]),

        make(.pad, "MACHINE PD",
             [0, 1, 0,  3, 5, 4,  1, 2, 0,  0, 1,
              0, 0, 0, 90, 22,  40, 50, 20, 30, 30, 0,  108, 0,  22, 0,
              100, 127, 90, 100, 90, 100, 100, 0,  30, 2],
             extra: [.reverbMix: 70, .reverbSize: 110, .reverbDamp: 70, .delayMix: 30, .delayDivision: 9]),

        make(.zap, "ZAP",
             [0, 0, 0,  1, 0, 0,  0, 0, 0,  2, 0,
              0, 110, 0, 0, 0,  90, 30, 0, 30, 60, 0,  116, 0,  64, 0,
              0, 127, 48, 40, 40, 0, 36, 0,  60, 2],
             extra: [.keyShift: 24, .delayMix: 45, .delayDivision: 5, .delayFeedback: 55, .delayPingPong: 1, .reverbMix: 30]),

        make(.fxPerc, "ELEC HAT",
             [0, 0, 0,  0, 0, 0,  1, 0, 3,  3, 0,
              0, 0, 0, 0, 0,  110, 20, 0, 0, 0, 0,  110, 0,  64, 0,
              0, 127, 14, 0, 14, 0, 10, 0,  60, 2],
             extra: [.reverbMix: 25, .reverbSize: 40]),

        make(.fxPerc, "BOOM 808",
             [0, 0, 0,  0, 0, 0,  1, 3, 0,  0, 0,
              0, 50, 0, 0, 0,  22, 0, 0, 0, 40, 0,  127, 0,  64, 0,
              0, 127, 80, 0, 80, 0, 70, 0,  60, 2],
             keyMode: 2),

        make(.lead, "SPACE LEAD",
             [0, 0, 0,  3, 3, 0,  1, 0, 0,  1, 1,
              30, 0, 30, 50, 40,  80, 40, 0, 30, 60, 0,  116, 0,  76, 70,
              6, 127, 50, 100, 50, 100, 40, 0,  60, 2],
             keyMode: 2, porta: 1, portaTime: 30,
             extra: [.delayMix: 55, .delayDivision: 9, .delayFeedback: 60, .delayPingPong: 1,
                     .reverbMix: 50, .reverbSize: 85]),

        make(.pad, "ROBO CHOIR",
             [0, 0, 0,  3, 2, 0,  1, 0, 0,  2, 1,
              8, 0, 0, 70, 50,  62, 30, 8, 20, 40, 0,  104, 0,  70, 40,
              60, 127, 70, 110, 70, 110, 70, 0,  80, 2],
             extra: [.reverbMix: 55, .reverbSize: 90]),

        // MARK: LFO sequences (tempo-synced LFO, sample & hold)

        // Step-sequencer patterns: hold one key (or use HOLD), it transposes.
        make(.sequence, "SEQ KRAFT",
             [0, 0, 0,  1, 0, 0,  0, 0, 0,  2, 0,
              0, 0, 0, 0, 0,  40, 105, 0, 90, 127, 0,  112, 0,  64, 0,
              0, 127, 22, 0, 26, 0, 18, 20,  60, 2],
             keyMode: 2,
             extra: [.seqOn: 1, .seqStyle: 0, .seqGate: 38,
                     .delayMix: 35, .delayFeedback: 35, .delayDivision: 6, .delayPingPong: 1, .reverbMix: 20,
                     .seqStep0: 45, .seqStep1: 25, .seqStep2: 13, .seqStep3: 25, .seqStep4: 13, .seqStep5: 25, .seqStep6: 20, .seqStep7: 25, .seqStep8: 45, .seqStep9: 25, .seqStep10: 13, .seqStep11: 25, .seqStep12: 16, .seqStep13: 25, .seqStep14: 23, .seqStep15: 25]),

        make(.sequence, "SEQ ROTHER",
             [0, 0, 2,  0, 1, 0,  2, 2, 0,  1, 0,
              0, 0, 0, 0, 0,  34, 92, 0, 70, 60, 0,  120, 0,  64, 0,
              0, 127, 30, 40, 30, 40, 12, 0,  60, 2],
             keyMode: 2, porta: 2, portaTime: 10,
             extra: [.seqOn: 1, .seqStyle: 1, .seqGate: 35,
                     .delayMix: 20, .delayDivision: 2, .reverbMix: 15,
                     .seqStep0: 45, .seqStep1: 0, .seqStep2: 13, .seqStep3: 25, .seqStep4: 0, .seqStep5: 13, .seqStep6: 46, .seqStep7: 0, .seqStep8: 13, .seqStep9: 0, .seqStep10: 25, .seqStep11: 43, .seqStep12: 13, .seqStep13: 0, .seqStep14: 84, .seqStep15: 13]),

        // Arpeggiator sequences: hold a chord (or use HOLD) and play.
        make(.sequence, "ARP ROBOT",
             [0, 0, 0,  1, 0, 0,  0, 0, 0,  2, 0,
              0, 0, 0, 0, 0,  40, 105, 0, 90, 127, 0,  112, 0,  64, 0,
              0, 127, 22, 0, 26, 0, 18, 20,  60, 2],
             extra: [.arpOn: 1, .arpMode: 0, .arpRate: 2, .arpOctaves: 1, .arpGate: 60,
                     .delayMix: 45, .delayFeedback: 40, .delayDivision: 6, .delayPingPong: 1, .reverbMix: 25]),

        make(.sequence, "ARP UPDOWN",
             [0, 0, 2,  3, 0, 0,  0, 0, 0,  2, 0,
              0, 0, 0, 100, 0,  70, 60, 0, 60, 70, 0,  104, 0,  64, 0,
              0, 127, 20, 0, 20, 0, 14, 0,  60, 2],
             extra: [.keyShift: 24, .arpOn: 1, .arpMode: 2, .arpRate: 2, .arpOctaves: 2, .arpGate: 90,
                     .delayMix: 35, .delayDivision: 5, .delayFeedback: 35, .reverbMix: 30]),

        make(.sequence, "ARP BASS",
             [0, 0, 2,  0, 1, 0,  2, 2, 0,  1, 0,
              0, 0, 0, 0, 0,  34, 92, 0, 70, 60, 0,  120, 0,  64, 0,
              0, 127, 30, 40, 30, 40, 12, 0,  60, 2],
             keyMode: 2,
             extra: [.arpOn: 1, .arpMode: 4, .arpRate: 2, .arpOctaves: 1, .arpGate: 70,
                     .delayMix: 15, .delayDivision: 2]),

        make(.sequence, "S&H BLEEP",
             [0, 0, 0,  1, 0, 0,  0, 0, 0,  2, 0,
              0, 0, 0, 0, 0,  46, 104, 92, 40, 90, 0,  112, 0,  64, 0,
              0, 127, 30, 40, 40, 30, 24, 0,  60, 2],
             extra: [.lfoWave: 5, .lfoSync: 1, .lfoDivision: 2, .lfoKeySync: 1,
                     .delayMix: 40, .delayDivision: 6, .delayFeedback: 45, .delayPingPong: 1, .reverbMix: 20]),

        make(.sequence, "S&H BASS",
             [0, 0, 2,  0, 1, 0,  2, 2, 0,  1, 0,
              0, 0, 0, 0, 0,  34, 92, 70, 50, 50, 0,  120, 0,  64, 0,
              0, 127, 40, 50, 40, 45, 12, 0,  60, 2],
             keyMode: 2, porta: 1, portaTime: 8,
             extra: [.lfoWave: 5, .lfoSync: 1, .lfoDivision: 2, .lfoKeySync: 1,
                     .delayMix: 15, .delayDivision: 2]),

        make(.sequence, "OCT BOUNCE",
             [0, 0, 2,  1, 1, 0,  2, 2, 0,  1, 0,
              90, 0, 0, 30, 0,  40, 60, 0, 60, 50, 0,  120, 0,  64, 0,
              0, 127, 40, 60, 40, 55, 14, 0,  60, 2],
             keyMode: 2,
             extra: [.lfoWave: 4, .lfoSync: 1, .lfoDivision: 2, .lfoKeySync: 1, .keyShift: 18,
                     .delayMix: 20, .delayDivision: 6]),

        make(.sequence, "SAW SWEEP",
             [0, 0, 2,  0, 1, 0,  1, 0, 0,  2, 1,
              0, 0, 0, 0, 0,  40, 60, 80, 40, 60, 0,  112, 0,  64, 0,
              0, 127, 40, 30, 40, 20, 30, 0,  56, 2],
             extra: [.lfoWave: 3, .lfoSync: 1, .lfoDivision: 8,
                     .delayMix: 30, .delayDivision: 6, .reverbMix: 25]),

        make(.sequence, "TRIPLETZAP",
             [0, 0, 0,  3, 2, 0,  1, 0, 0,  1, 0,
              0, 0, 0, 50, 40,  36, 100, 86, 30, 60, 0,  116, 0,  64, 0,
              0, 127, 30, 60, 40, 50, 20, 0,  60, 2],
             keyMode: 2,
             extra: [.lfoWave: 2, .lfoSync: 1, .lfoDivision: 4, .lfoKeySync: 1,
                     .delayMix: 30, .delayDivision: 4]),

        make(.stab, "GATE CHORD",
             [0, 0, 0,  3, 1, 0,  1, 0, 0,  2, 1,
              0, 0, 0, 40, 0,  30, 40, 127, 10, 40, 0,  112, 0,  64, 0,
              0, 127, 0, 127, 0, 127, 20, 0,  50, 2],
             keyMode: 1, chord: 0,
             extra: [.lfoWave: 4, .lfoSync: 1, .lfoDivision: 2, .lfoKeySync: 1,
                     .reverbMix: 35, .delayMix: 20, .delayDivision: 6]),

        make(.bass, "WOBBLE 1/8",
             [0, 0, 0,  0, 1, 0,  2, 2, 0,  1, 0,
              0, 0, 0, 0, 0,  40, 80, 96, 0, 40, 0,  122, 0,  64, 0,
              0, 127, 0, 127, 0, 127, 14, 0,  60, 2],
             keyMode: 2,
             extra: [.lfoWave: 1, .lfoSync: 1, .lfoDivision: 5, .lfoKeySync: 1]),

        make(.fxPerc, "COMP TALK",
             [0, 0, 1,  3, 0, 0,  0, 0, 0,  2, 0,
              70, 0, 0, 90, 0,  80, 60, 30, 0, 60, 0,  108, 0,  64, 0,
              0, 127, 0, 127, 0, 127, 10, 0,  60, 2],
             extra: [.keyShift: 24, .lfoWave: 5, .lfoSync: 1, .lfoDivision: 0,
                     .delayMix: 35, .delayDivision: 5, .delayPingPong: 1, .reverbMix: 25]),

        make(.fxPerc, "S&H NOISE",
             [0, 0, 0,  0, 0, 0,  1, 0, 3,  3, 0,
              0, 0, 0, 0, 0,  90, 60, 70, 0, 0, 0,  108, 0,  64, 0,
              0, 127, 14, 0, 14, 0, 12, 0,  60, 2],
             extra: [.lfoWave: 5, .lfoSync: 1, .lfoDivision: 2, .reverbMix: 20]),

        make(.pad, "DRIFT PAD",
             [0, 0, 0,  3, 1, 0,  1, 0, 0,  2, 1,
              0, 0, 0, 60, 30,  52, 40, 60, 20, 30, 0,  104, 0,  64, 0,
              90, 127, 90, 110, 90, 110, 90, 0,  40, 2],
             extra: [.lfoWave: 6, .lfoSync: 1, .lfoDivision: 12,
                     .reverbMix: 65, .reverbSize: 100, .delayMix: 20, .delayDivision: 9]),

        make(.lead, "VIBE LEAD",
             [0, 0, 0,  3, 1, 0,  1, 0, 0,  1, 1,
              24, 0, 20, 50, 30,  84, 30, 0, 30, 60, 0,  116, 0,  64, 70,
              0, 127, 50, 100, 50, 100, 40, 0,  60, 2],
             keyMode: 2, porta: 1, portaTime: 20,
             extra: [.lfoWave: 1, .lfoSync: 1, .lfoDivision: 4,
                     .delayMix: 40, .delayDivision: 6, .delayPingPong: 1, .reverbMix: 35]),

        // MARK: Electro zaps (pitch-envelope sweeps, sync and resonance zaps)

        make(.zap, "ZAP CLASSC",
             [0, 0, 0,  1, 0, 0,  0, 0, 0,  2, 0,
              0, 110, 0, 0, 0,  90, 20, 0, 20, 60, 0,  118, 0,  64, 0,
              0, 127, 46, 30, 38, 0, 34, 0,  60, 2],
             extra: [.delayMix: 25, .delayDivision: 2, .delayPingPong: 1]),

        make(.zap, "LASER",
             [0, 0, 0,  0, 1, 0,  0, 0, 0,  2, 0,
              0, 127, 0, 0, 0,  70, 80, 0, 60, 60, 0,  116, 0,  64, 0,
              0, 127, 52, 50, 44, 0, 40, 0,  60, 2],
             extra: [.keyShift: 24, .delayMix: 40, .delayDivision: 2, .delayFeedback: 50, .delayPingPong: 1, .reverbMix: 20]),

        make(.zap, "PEW PEW",
             [0, 0, 0,  3, 0, 0,  0, 0, 0,  3, 0,
              0, 100, 0, 100, 0,  100, 10, 0, 0, 40, 0,  116, 0,  64, 0,
              0, 127, 42, 30, 34, 0, 30, 0,  60, 2],
             extra: [.delayMix: 45, .delayDivision: 2, .delayFeedback: 55, .delayPingPong: 1]),

        make(.zap, "RISE ZAP",
             [1, 0, 0,  1, 1, 0,  0, 0, 0,  2, 0,
              0, 90, 0, 0, 0,  80, 40, 0, 30, 60, 0,  114, 0,  64, 0,
              0, 127, 50, 40, 42, 0, 38, 0,  60, 2],
             extra: [.delayMix: 30, .delayDivision: 5]),

        make(.zap, "SYNC ZAP",
             [0, 0, 0,  1, 0, 0,  1, 0, 0,  2, 0,
              0, 30, 0, 0, 0,  100, 20, 0, 0, 40, 0,  116, 0,  64, 0,
              0, 127, 50, 50, 42, 0, 38, 0,  60, 2],
             extra: [.pulseSync: 1, .pulseDetune: 100, .pulseEnvMod: 127, .delayMix: 25, .delayDivision: 5]),

        make(.zap, "NOISE ZAP",
             [0, 0, 0,  0, 0, 0,  1, 0, 3,  2, 0,
              0, 0, 0, 0, 0,  20, 115, 0, 127, 0, 0,  116, 0,  64, 0,
              0, 127, 46, 30, 40, 0, 34, 0,  60, 2],
             extra: [.reverbMix: 25]),

        make(.zap, "RES ZAP",
             [0, 0, 0,  0, 0, 0,  1, 0, 1,  1, 0,
              0, 0, 0, 0, 0,  30, 127, 0, 127, 100, 0,  120, 0,  64, 0,
              0, 127, 48, 35, 40, 0, 36, 0,  60, 2],
             extra: [.delayMix: 20, .delayDivision: 2]),

        make(.zap, "DUB ZAP",
             [0, 0, 0,  1, 1, 0,  0, 0, 0,  2, 1,
              0, 120, 0, 0, 0,  80, 50, 0, 40, 60, 0,  112, 0,  64, 0,
              0, 127, 52, 45, 46, 0, 42, 0,  50, 2],
             extra: [.delayMix: 60, .delayDivision: 6, .delayFeedback: 70, .delayTone: 60, .delayPingPong: 1,
                     .reverbMix: 45, .reverbSize: 100]),

        // MARK: JX-8P style strings (saw + detuned PWM pulse, chorus) for electro

        make(.stringsBrass, "JX STRINGS",
             [0, 0, 0,  3, 1, 0,  1, 0, 0,  2, 1,
              6, 0, 8, 56, 36,  72, 10, 0, 16, 50, 12,  106, 10,  70, 60,
              62, 127, 70, 118, 70, 115, 72, 0,  40, 2],
             extra: [.pulseDetune: 65, .voiceDrift: 30, .reverbMix: 40, .reverbSize: 90]),

        make(.stringsBrass, "JX ENSEMBL",
             [0, 0, 0,  3, 2, 0,  1, 0, 0,  2, 1,
              8, 0, 0, 64, 44,  76, 8, 0, 10, 40, 0,  104, 0,  72, 50,
              70, 127, 70, 120, 70, 118, 80, 0,  96, 2],
             extra: [.pulseDetune: 65, .voiceDrift: 55, .reverbMix: 45]),

        make(.stringsBrass, "STR STAB",
             [0, 0, 2,  3, 1, 0,  1, 0, 0,  2, 1,
              0, 0, 0, 50, 30,  55, 20, 0, 50, 50, 0,  112, 0,  64, 0,
              0, 127, 40, 40, 50, 30, 40, 0,  50, 2],
             extra: [.pulseDetune: 65, .delayMix: 30, .delayDivision: 6, .delayPingPong: 1, .reverbMix: 30]),

        make(.stringsBrass, "DARK STR",
             [0, 0, 0,  3, 5, 0,  1, 1, 0,  1, 1,
              0, 0, 0, 70, 24,  40, 22, 0, 20, 30, 0,  108, 0,  64, 0,
              84, 127, 80, 110, 80, 110, 90, 0,  32, 2],
             extra: [.pulseDetune: 65, .reverbMix: 60, .reverbSize: 110, .reverbDamp: 70]),

        make(.stringsBrass, "SWEEP STR",
             [0, 0, 0,  3, 1, 0,  1, 0, 0,  2, 1,
              0, 0, 0, 56, 34,  50, 30, 60, 10, 40, 0,  106, 0,  64, 0,
              70, 127, 70, 118, 70, 118, 80, 0,  44, 2],
             extra: [.lfoWave: 0, .lfoSync: 1, .lfoDivision: 13, .pulseDetune: 65, .reverbMix: 45]),

        make(.stringsBrass, "BRIGHT STR",
             [0, 0, 0,  3, 1, 0,  0, 0, 0,  3, 1,
              6, 0, 0, 50, 40,  95, 14, 0, 10, 60, 0,  100, 0,  70, 60,
              50, 127, 60, 115, 60, 112, 64, 0,  60, 2],
             extra: [.pulseDetune: 65, .delayMix: 25, .delayDivision: 8, .delayPingPong: 1, .reverbMix: 35]),

        make(.stringsBrass, "STR CHORD",
             [0, 0, 0,  3, 1, 0,  1, 0, 0,  2, 1,
              0, 0, 0, 56, 36,  62, 14, 0, 30, 40, 0,  108, 0,  64, 0,
              30, 127, 60, 110, 60, 100, 60, 0,  44, 2],
             keyMode: 1, chord: 1,
             extra: [.pulseDetune: 65, .reverbMix: 45, .delayMix: 20, .delayDivision: 6]),

        make(.stringsBrass, "SLOW STR",
             [0, 0, 0,  3, 1, 0,  1, 0, 0,  2, 1,
              8, 0, 0, 60, 30,  64, 10, 0, 12, 40, 0,  104, 0,  64, 80,
              104, 127, 90, 120, 90, 118, 104, 0,  40, 2],
             extra: [.pulseDetune: 65, .voiceDrift: 35, .reverbMix: 70, .reverbSize: 120]),
    ]

    private static func make(_ category: PresetCategory, _ name: String, _ tone: [Int],
                             keyMode: Int = 0, porta: Int = 0, portaTime: Int = 30,
                             chord: Int = 0, volume: Int = 100,
                             extra: [Param: Int] = [:]) -> ToneData {
        var patch = Dictionary(uniqueKeysWithValues: Param.patchParams.map { ($0.rawValue, $0.defaultValue) })
        patch[Param.keyMode.rawValue] = keyMode
        patch[Param.portaSwitch.rawValue] = porta
        patch[Param.portaTime.rawValue] = portaTime
        patch[Param.chordIndex.rawValue] = chord
        patch[Param.volume.rawValue] = volume
        for (p, v) in extra { patch[p.rawValue] = v }
        // MIDI channel is a device setting, not part of a sound.
        for p in Param.patchParams where p.isDeviceSetting { patch.removeValue(forKey: p.rawValue) }
        return ToneData(name: name, tone: tone, patch: patch, category: category)
    }
}
