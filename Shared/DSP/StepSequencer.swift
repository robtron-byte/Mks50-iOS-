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
    mutating func process(beat: Double, root: Int, rateIndex: Int, length: Int, gate: Double,
                          steps: UnsafePointer<Float>) -> SeqEvents {
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
        let length = s.tie ? 1.0 : (s.accent ? min(1, gate + 0.15) : gate)
        gateOffBeat = s.tie ? .infinity : Double(step) * quarters + quarters * length
        if gateOffBeat <= beat { gateOffBeat = beat + quarters * length }
        return events
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
