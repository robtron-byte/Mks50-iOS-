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

    /// GATE knob → note length in steps: 0...80 is 5 ... 100 % of a step,
    /// above that whole steps, 1 ... 8 (the note rings over rests until its
    /// length is up or the next note takes over).
    static func gateSteps(_ raw: Float) -> Double {
        let v = Double(max(0, min(127, raw)))
        if v <= 80 { return 0.05 + 0.95 * v / 80 }
        return Double(1 + Int((7 * (v - 80) / 47).rounded()))
    }

    private(set) var soundingKey = -1
    private(set) var currentStep = -1
    private var gateOffBeat: Double = 0
    /// A G.VAR long note covers the steps up to here (absolute step count).
    private var holdUntilStep: Int64 = .min
    /// The previous step was covered by a long note (its TIE does not count).
    private var previousCovered = false
    private var lastStep: Int64 = .min

    /// - Parameters:
    ///   - root: held key (-1: none held → stop)
    ///   - steps: the 16 step parameter values
    ///   - gateVariation: 0...1 (G.VAR), how many notes become long notes
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
            holdUntilStep = .min
            previousCovered = false
            currentStep = -1
            return events
        }

        let stepPosition = beat / quarters
        let step = Int64(stepPosition.rounded(.down))
        if lastStep == .min && stepPosition - Double(step) > 0.35 {
            // Started late in a step: begin with the next step instead of
            // a step cut short by it (a "bleep").
            lastStep = step
            return events
        }
        guard step != lastStep else { return events }
        lastStep = step

        let count = min(max(length, 1), StepSequencer.maxSteps)
        let index = Int(((step % Int64(count)) + Int64(count)) % Int64(count))
        let previous = currentStep
        currentStep = index

        // Covered by a G.VAR long note: it keeps sounding, the step is skipped.
        if step < holdUntilStep {
            previousCovered = true
            return events
        }
        let afterLongNote = previousCovered
        previousCovered = false

        guard let s = SeqStep(raw: Int(steps[index].rounded())) else {
            // Rest: a tied note before it ends here; a long gate rings on.
            if soundingKey >= 0 && gateOffBeat == .infinity {
                events.off = soundingKey
                soundingKey = -1
            }
            return events
        }

        let key = min(max(root + s.note, 0), 127)
        let tiedFromPrevious = previous >= 0 && soundingKey >= 0 && !afterLongNote
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

        let hold = gateVariation > 0
            ? StepSequencer.holdSteps(index: index, count: count, amount: gateVariation, steps: steps) : 1
        if hold > 1 && !s.tie {
            // Long note: exactly `hold` whole steps, the steps under it are skipped.
            holdUntilStep = step + Int64(hold)
            gateOffBeat = Double(step + Int64(hold)) * quarters
            return events
        }
        // Tied steps hold until the next step; others stop after the gate.
        let length = s.tie ? 1.0 : (s.accent && gate < 1 ? min(1, gate + 0.15) : gate)
        gateOffBeat = s.tie ? .infinity : Double(step) * quarters + quarters * length
        if gateOffBeat <= beat { gateOffBeat = beat + quarters * length }
        return events
    }

    /// Lengths of G.VAR long notes in steps and their weights: mostly
    /// two steps (an 8th on the 16th grid), then dotted (3) and 4 steps.
    private static let holdLengths = (2, 3, 4)

    /// G.VAR: length of the note on `index` in whole steps (1 = normal
    /// GATE). Each step has a fixed random value from the pattern itself,
    /// so turning G.VAR up only adds long notes (on the beat first) and
    /// the rhythm stays the same until NEW / VARY. A long note never runs
    /// past the end of the pattern.
    static func holdSteps(index: Int, count: Int, amount: Double, steps: UnsafePointer<Float>) -> Int {
        guard amount > 0, index < count, SeqStep(raw: Int(steps[index].rounded())) != nil else { return 1 }
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for i in 0..<maxSteps {
            h = (h ^ UInt64(max(0, Int(steps[i].rounded())))) &* 0x100_0000_01b3
        }
        h = (h ^ UInt64(index + 1)) &* 0x9e37_79b9_7f4a_7c15
        h ^= h >> 29
        let chance = Double(h & 0xFFFF) / 65536
        let pick = Double((h >> 16) & 0xFFFF) / 65536
        // Downbeats and 8ths take long notes more readily than off-16ths.
        let weight = index % 4 == 0 ? 1.0 : (index % 2 == 0 ? 0.8 : 0.45)
        guard chance < amount * 0.8 * weight else { return 1 }
        let length = pick < 0.5 ? holdLengths.0 : (pick < 0.8 ? holdLengths.1 : holdLengths.2)
        return max(1, min(length, count - index))
    }

    /// For the step grid: which steps a G.VAR long note covers (they are
    /// skipped while it sounds), following the pattern from step 1.
    static func coveredSteps(count: Int, amount: Double, steps: UnsafePointer<Float>) -> [Bool] {
        var covered = [Bool](repeating: false, count: maxSteps)
        var i = 0
        while i < count {
            let isTie = SeqStep(raw: Int(steps[i].rounded()))?.tie ?? false
            let hold = isTie ? 1 : holdSteps(index: i, count: count, amount: amount, steps: steps)
            for k in 1..<max(hold, 1) where i + k < maxSteps { covered[i + k] = true }
            i += max(hold, 1)
        }
        return covered
    }

    /// Stops the pattern; returns the note to release (-1: none).
    mutating func stop() -> Int {
        let key = soundingKey
        soundingKey = -1
        holdUntilStep = .min
        previousCovered = false
        lastStep = .min
        currentStep = -1
        return key
    }

    /// Voices were released elsewhere: forget the sounding note.
    mutating func silence() {
        soundingKey = -1
        holdUntilStep = .min
        previousCovered = false
        lastStep = .min
    }
}
