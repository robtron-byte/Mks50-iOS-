import Foundation

/// Chord memory: 8 chords of up to 6 notes, stored as semitone offsets
/// relative to the played key (the MKS-50 has 16; 8 keep the buttons
/// manageable live). The defaults are typical electro / Detroit voicings.
enum ChordMemory {
    static let slots = 8
    static let maxNotes = 6

    static let defaultChords: [[Int]] = [
        [0, 3, 7, 10],          // m7: the Detroit / electro stab
        [0, 3, 7, 10, 14],      // m9: deep, dubby pads
        [0, 3, 7],              // minor triad
        [0, 7, 12],             // 5th + octave: Kraftwerk-style power stab
        [0, 5, 10, 15],         // stacked 4ths: open, futuristic
        [0, 5, 7, 10],          // 7sus4: dub techno chord
        [0, 4, 7, 11],          // maj7: the bright answer
        [0, 3, 6, 10],          // m7b5: dark, tense
    ]

    static let defaultNames: [String] = ["m7", "m9", "MIN", "5+8", "4THS", "7SUS4", "MAJ7", "m7b5"]

    /// Short name of a chord (for the buttons): known shapes by name, a
    /// learned one as its intervals.
    static func name(_ chord: [Int]) -> String {
        if let i = defaultChords.firstIndex(of: chord) { return defaultNames[i] }
        let known: [[Int]: String] = [
            [0, 4, 7]: "MAJ", [0, 4, 7, 10]: "7TH", [0, 5, 7]: "SUS4", [0, 2, 7]: "SUS2",
            [0, 7]: "5TH", [0, 12]: "OCT", [0, 4, 7, 11, 14]: "MAJ9", [0, 4, 7, 14]: "ADD9",
            [0, 3, 7, 14]: "m ADD9", [0, 3, 6]: "DIM", [0, 4, 8]: "AUG", [0, 4, 7, 9]: "6TH",
            [0, 3, 7, 10, 14, 17]: "m11", [0, 3, 7, 10, 17]: "m11",
        ]
        if let name = known[chord] { return name }
        return chord.count == 1 ? "ROOT" : chord.dropFirst().map(String.init).joined(separator: "·")
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
