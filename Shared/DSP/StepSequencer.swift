import Foundation

/// One sequencer step, stored in a single 0...127 parameter value:
/// 0 = rest, otherwise 1 + (note + 12) + 32 × accent + 64 × tie,
/// with note -12...+18 semitones relative to the held key.
struct SeqStep: Equatable {
    static let noteRange = -12...18

    var note: Int
    var accent: Bool
    var tie: Bool

    init(note: Int, accent: Bool = false, tie: Bool = false) {
        self.note = min(max(note, SeqStep.noteRange.lowerBound), SeqStep.noteRange.upperBound)
        self.accent = accent
        self.tie = tie
    }

    /// nil for a rest.
    init?(raw: Int) {
        guard raw > 0 else { return nil }
        let c = min(raw, 127) - 1
        note = min(c % 32 - 12, SeqStep.noteRange.upperBound)   // 31 is unused
        accent = (c / 32) & 1 == 1
        tie = (c / 64) & 1 == 1
    }

    var raw: Int { min(127, 1 + (note + 12) + (accent ? 32 : 0) + (tie ? 64 : 0)) }

    var label: String {
        (note == 0 ? "0" : String(format: "%+d", note)) + (accent ? " ACC" : "") + (tie ? " TIE" : "")
    }
}

/// Note events of one sequencer step (-1: none). `legato`: start the new
/// note before releasing the old one (tied steps).
struct SeqEvents {
    var off = -1
    var on = -1
    var velocity = 0
    var legato = false
}

/// 16-step sequencer on the beat clock (audio thread, no allocation). The
/// pattern is transposed by the held key and stays aligned to the bar, so
/// loop recordings line up.
struct StepSequencer {
    static let maxSteps = 16

    private(set) var soundingKey = -1
    private(set) var currentStep = -1
    private var gateOffBeat: Double = 0
    private var lastStep: Int64 = .min

    /// - Parameters:
    ///   - root: held key (-1: none held → stop)
    ///   - steps: the 16 step parameter values
    ///   - gateVariation: 0...1, how far each step's gate departs from `gate`
    mutating func process(beat: Double, root: Int, rateIndex: Int, length: Int, gate: Double,
                          gateVariation: Double = 0, steps: UnsafePointer<Float>) -> SeqEvents {
        var events = SeqEvents()
        let quarters = LFOShape.divisionQuarters[min(max(rateIndex, 0), LFOShape.divisionQuarters.count - 1)]

        if soundingKey >= 0 && (beat >= gateOffBeat || root < 0) {
            events.off = soundingKey
            soundingKey = -1
        }
        guard root >= 0 else {
            lastStep = .min
            currentStep = -1
            return events
        }

        let step = Int64((beat / quarters).rounded(.down))
        guard step != lastStep else { return events }
        lastStep = step

        let count = min(max(length, 1), StepSequencer.maxSteps)
        let index = Int(((step % Int64(count)) + Int64(count)) % Int64(count))
        let previous = currentStep
        currentStep = index

        guard let s = SeqStep(raw: Int(steps[index].rounded())) else {
            // Rest: a tied note before it ends here.
            if soundingKey >= 0 {
                events.off = soundingKey
                soundingKey = -1
            }
            return events
        }

        let key = min(max(root + s.note, 0), 127)
        let tiedFromPrevious = previous >= 0 && soundingKey >= 0
            && (SeqStep(raw: Int(steps[previous].rounded()))?.tie ?? false)
        if soundingKey >= 0 {
            events.off = soundingKey
            events.legato = tiedFromPrevious && soundingKey != key
            if tiedFromPrevious && soundingKey == key {
                // Tie to the same note: just keep it sounding.
                events.off = -1
            }
        }
        if events.off == -1 && soundingKey == key {
            // Continues the tied note.
        } else {
            events.on = key
            events.velocity = s.accent ? 127 : 88
        }
        soundingKey = key
        // Tied steps hold until the next step; others stop after the gate.
        var stepGate = gate
        if gateVariation > 0 {
            // Blend from the GATE knob towards the groove's length.
            let target = StepSequencer.grooveGate(index: index, count: count, steps: steps)
            stepGate = min(max(gate + gateVariation * (target - gate), 0.05), 1)
        }
        let length = s.tie ? 1.0 : (s.accent ? min(1, stepGate + 0.15) : stepGate)
        gateOffBeat = s.tie ? .infinity : Double(step) * quarters + quarters * length
        if gateOffBeat <= beat { gateOffBeat = beat + quarters * length }
        return events
    }

    /// Gate lengths of the groove, from staccato to legato.
    private static let grooveLevels: [Double] = [0.18, 0.4, 0.65, 0.92]

    /// Groove templates for one beat (four 16ths), as `grooveLevels` indices.
    /// Each pairs with a variation used on the last beat of the bar as a
    /// phrase ending.
    private static let grooveTemplates: [(main: [Int], end: [Int])] = [
        ([3, 1, 2, 1], [3, 1, 1, 3]),      // long – short – mid – short
        ([3, 1, 1, 2], [2, 1, 3, 0]),      // gallop
        ([2, 0, 3, 0], [3, 0, 3, 1]),      // off-beat push
        ([3, 2, 1, 0], [1, 1, 2, 3]),      // decaying, answer swells
        ([1, 1, 3, 1], [3, 1, 1, 1]),      // stab on the "and"
    ]

    /// Gate length (0...1) of one step for G.VAR. A groove template, picked
    /// from the pattern itself, repeats every beat (so it locks to the
    /// rhythm) with a variation on the bar's last beat, then reads the
    /// pattern: notes before a rest ring out, accents get longer, octave
    /// jumps up become short bleeps. Changes with NEW / VARY.
    static func grooveGate(index: Int, count: Int, steps: UnsafePointer<Float>) -> Double {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for i in 0..<maxSteps {
            h = (h ^ UInt64(max(0, Int(steps[i].rounded())))) &* 0x100_0000_01b3
        }
        h ^= h >> 31
        let template = grooveTemplates[Int(h % UInt64(grooveTemplates.count))]
        let inBeat = index % 4
        let lastBeat = (index % 16) / 4 == 3 || index / 4 == (count - 1) / 4
        var level = lastBeat && count > 4 ? template.end[inBeat] : template.main[inBeat]

        if let step = SeqStep(raw: Int(steps[index].rounded())) {
            let next = SeqStep(raw: Int(steps[(index + 1) % count].rounded()))
            if next == nil {
                level = max(level, 2)                  // room to ring before a rest
            } else if let n = next, n.note - step.note >= 12 {
                level = min(level, 1)                  // clipped before an octave leap
            }
            if step.accent { level = min(level + 1, 3) }
            let prevIndex = (index + count - 1) % count
            if let prev = SeqStep(raw: Int(steps[prevIndex].rounded())), step.note - prev.note >= 12 {
                level = 0                              // the leap itself: a short bleep
            }
        }
        return grooveLevels[level]
    }

    /// Stops the pattern; returns the note to release (-1: none).
    mutating func stop() -> Int {
        let key = soundingKey
        soundingKey = -1
        lastStep = .min
        currentStep = -1
        return key
    }

    /// Voices were released elsewhere: forget the sounding note.
    mutating func silence() {
        soundingKey = -1
        lastStep = .min
    }
}
