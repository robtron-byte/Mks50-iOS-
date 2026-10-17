import Foundation

/// MKS-50 style chord memory: 16 chords of up to 6 notes, stored as
/// semitone offsets relative to the played key.
enum ChordMemory {
    static let slots = 16
    static let maxNotes = 6

    static let defaultChords: [[Int]] = [
        [0, 3, 7, 10],          // m7
        [0, 4, 7],              // maj
        [0, 3, 7],              // min
        [0, 4, 7, 11],          // maj7
        [0, 4, 7, 10],          // 7
        [0, 5, 7],              // sus4
        [0, 7],                 // 5th
        [0, 12],                // octave
        [0, 3, 7, 10, 14],      // m9
        [0, 4, 7, 11, 14],      // maj9
        [0, 4, 7, 14],          // add9
        [0, 3, 6],              // dim
        [0, 4, 8],              // aug
        [0, 4, 7, 9],           // 6
        [0, 3, 7, 10, 14, 17],  // m11
        [0, 5, 10, 15],         // 4ths
    ]

    static let defaultNames: [String] = [
        "1 m7", "2 MAJ", "3 MIN", "4 MAJ7", "5 7TH", "6 SUS4", "7 5TH", "8 OCT",
        "9 m9", "10 MAJ9", "11 ADD9", "12 DIM", "13 AUG", "14 6TH", "15 m11", "16 4THS",
    ]

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
