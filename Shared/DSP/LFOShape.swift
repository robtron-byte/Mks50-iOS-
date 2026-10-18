import Foundation

/// LFO waveforms. 0 = triangle, the only shape of the original Alpha Juno /
/// MKS-50 LFO (kept as the default); the others extend it like modern
/// emulations do.
enum LFOShape {
    static let names = ["TRI", "SINE", "SAW UP", "SAW DN", "SQUARE", "S&H", "RANDOM"]

    /// Tempo-sync note values (in quarter notes), from 1/32 up to 4 bars.
    static let divisionNames = ["1/32", "1/16T", "1/16", "1/16.", "1/8T", "1/8", "1/8.", "1/4T",
                                "1/4", "1/4.", "1/2", "1/1", "2/1", "4/1"]
    static let divisionQuarters: [Double] = [0.125, 1.0 / 6, 0.25, 0.375, 1.0 / 3, 0.5, 0.75, 2.0 / 3,
                                             1, 1.5, 2, 4, 8, 16]

    /// Value of a deterministic shape at phase 0..<1 (bipolar -1...1).
    /// Random shapes are handled by the engine (they need state).
    @inline(__always) static func value(_ shape: Int, phase p: Float) -> Float {
        switch shape {
        case 1: return sinf(2 * Float.pi * p)
        case 2: return 2 * p - 1
        case 3: return 1 - 2 * p
        case 4: return p < 0.5 ? 1 : -1
        default: return 1 - 4 * abs(p - 0.5)   // triangle, starts at -1
        }
    }
}
