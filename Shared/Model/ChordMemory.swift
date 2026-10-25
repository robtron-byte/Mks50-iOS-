import Foundation

/// Chord memory: 8 chords of up to 6 notes, stored as semitone offsets
/// relative to the played key (the MKS-50 has 16; 8 keep the buttons
/// manageable live). The defaults are the chord types measured in Rother's and
/// Egyptian Lover's pads (the same as the FM1 firmware's).
enum ChordMemory {
    static let slots = 8
    static let maxNotes = 6

    static let defaultChords: [[Int]] = [
        [0, 3, 7, 10],          // m7: the Detroit / electro stab
        [0, 2, 7],              // sus2: Rother's open pads
        [0, 3, 7],              // minor triad: Rother's main pad chord
        [0, 7, 12],             // 5th + octave: power stab (Kraftwerk, Egyptian Lover)
        [0, 5, 7],              // sus4
        [0, 4, 7, 10],          // dominant 7th: Egyptian Lover's stabs
        [0, 4, 7],              // major triad
        [0, 3, 6, 10],          // m7b5: dark, tense
    ]

    static let defaultNames: [String] = ["m7", "SUS2", "MIN", "5+8", "SUS4", "7TH", "MAJ", "m7b5"]

    /// Short name of a chord (for the buttons): known shapes by name, a
    /// learned one as its intervals.
    static func name(_ chord: [Int]) -> String {
        if let name = knownName(chord) { return name }
        return chord.count == 1 ? "ROOT" : chord.dropFirst().map(String.init).joined(separator: "·")
    }

    /// Name of a default or common chord, nil for any other interval set
    /// (e.g. two notes 15 semitones apart).
    static func knownName(_ chord: [Int]) -> String? {
        if let i = defaultChords.firstIndex(of: chord) { return defaultNames[i] }
        let known: [[Int]: String] = [
            [0, 3, 7, 10, 14]: "m9", [0, 5, 10, 15]: "4THS", [0, 5, 7, 10]: "7SUS4", [0, 4, 7, 11]: "MAJ7",
            [0, 7]: "5TH", [0, 12]: "OCT", [0, 4, 7, 11, 14]: "MAJ9", [0, 4, 7, 14]: "ADD9",
            [0, 3, 7, 14]: "m ADD9", [0, 3, 6]: "DIM", [0, 4, 8]: "AUG", [0, 4, 7, 9]: "6TH",
            [0, 3, 7, 10, 14, 17]: "m11", [0, 3, 7, 10, 17]: "m11",
        ]
        return known[chord]
    }

    /// Turns a set of held MIDI notes into offsets relative to the lowest note.
    static func chord(fromHeld notes: [Int]) -> [Int] {
        let sorted = Array(Set(notes)).sorted().prefix(maxNotes)
        guard let root = sorted.first else { return [0] }
        return sorted.map { $0 - root }
    }

    static func describe(_ chord: [Int]) -> String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        return chord.map { names[(($0 % 12) + 12) % 12] + ($0 >= 12 ? "'" : "") }.joined(separator: " ")
    }
}
