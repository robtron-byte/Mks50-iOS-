import Foundation

/// Random electro sequences that stay musical: every style draws from a
/// fixed scale, a style-typical rhythm and repetition (motifs, call and
/// response), which is what makes Kraftwerk / Anthony Rother style lines
/// sound "right" instead of random.
enum SequenceGenerator {
    static let styleNames = ["KRAFT", "ROTHER", "ROBOT", "ACID"]

    /// Returns 16 raw step values (see `SeqStep`).
    static func generate(style: Int) -> [Int] {
        var rng = SystemRandomNumberGenerator()
        let steps: [SeqStep?]
        switch style {
        case 1: steps = rother(&rng)
        case 2: steps = robot(&rng)
        case 3: steps = acid(&rng)
        default: steps = kraft(&rng)
        }
        return steps.map { $0?.raw ?? 0 }
    }

    /// Small variation of an existing pattern: changes 1–2 steps in the
    /// style's scale, keeps the downbeat.
    static func vary(_ raw: [Int], style: Int) -> [Int] {
        var rng = SystemRandomNumberGenerator()
        var steps = raw.map { SeqStep(raw: $0) }
        let scale = Self.scale(for: style)
        for _ in 0..<Int.random(in: 1...2, using: &rng) {
            let i = Int.random(in: 1..<steps.count, using: &rng)
            if steps[i] == nil || Double.random(in: 0..<1, using: &rng) < 0.25 {
                steps[i] = steps[i] == nil ? SeqStep(note: pick(scale, &rng)) : nil
            } else {
                steps[i]!.note = pick(scale, &rng)
            }
        }
        return steps.map { $0?.raw ?? 0 }
    }

    // MARK: Styles

    private static func scale(for style: Int) -> [Int] {
        switch style {
        case 1: return [0, 0, 0, 12, 12, 1, -2, 7, 3, -12, 10]      // phrygian minor, root heavy
        case 2: return [0, 7, 12, 15, 3, 10, 17, 5]                  // wide pentatonic bleeps
        case 3: return [0, 0, 12, 3, 7, 10, 5, -2, 8]                // minor
        default: return [0, 0, 12, 7, 3, 10, 5, -5]                  // minor pentatonic
        }
    }

    /// Kraftwerk: straight, mechanical, a 4- or 8-step motif repeated with a
    /// transposed answer ("Numbers", "Computer World", "Trans Europa").
    private static func kraft(_ rng: inout SystemRandomNumberGenerator) -> [SeqStep?] {
        let scale = Self.scale(for: 0)
        let motifLength = Bool.random(using: &rng) ? 4 : 8
        var motif: [SeqStep?] = []
        let bounce = Double.random(in: 0..<1, using: &rng) < 0.4
        for i in 0..<motifLength {
            if i == 0 {
                motif.append(SeqStep(note: 0, accent: true))
            } else if bounce {
                // Octave bounce with the occasional fifth / third.
                let alt = i % 2 == 1 ? 12 : 0
                let note = Double.random(in: 0..<1, using: &rng) < 0.25 ? pick([7, 3, 10], &rng) : alt
                motif.append(SeqStep(note: note))
            } else if Double.random(in: 0..<1, using: &rng) < 0.18 {
                motif.append(nil)
            } else {
                motif.append(SeqStep(note: pick(scale, &rng), accent: i % 4 == 0))
            }
        }
        var steps: [SeqStep?] = []
        let answer = pick([0, 0, -2, 3, 5, -5], &rng)
        for rep in 0..<(16 / motifLength) {
            let last = rep == 16 / motifLength - 1
            steps += motif.map { (step: SeqStep?) -> SeqStep? in
                guard let s = step, last else { return step }
                return SeqStep(note: s.note + answer, accent: s.accent)
            }
        }
        return steps
    }

    /// Anthony Rother: dark, syncopated 16th basslines (Euclidean rhythm),
    /// root and octave heavy, flat-2 and flat-7 tension, accents on
    /// off-beats, the odd tie.
    private static func rother(_ rng: inout SystemRandomNumberGenerator) -> [SeqStep?] {
        let scale = Self.scale(for: 1)
        let hits = euclid(pick([7, 9, 10, 11], &rng), 16, rotate: Int.random(in: 0...2, using: &rng))
        var steps: [SeqStep?] = []
        for i in 0..<16 {
            guard hits[i] || i == 0 else {
                steps.append(nil)
                continue
            }
            let note = i == 0 ? 0 : pick(scale, &rng)
            let offbeat = i % 4 == 2 || i % 4 == 3
            let accent = i == 0 || (offbeat && Double.random(in: 0..<1, using: &rng) < 0.45)
            let tie = i < 15 && hits[(i + 1) % 16] && Double.random(in: 0..<1, using: &rng) < 0.12
            steps.append(SeqStep(note: note, accent: accent, tie: tie))
        }
        // Call and response: repeat the first half, vary its end.
        if Double.random(in: 0..<1, using: &rng) < 0.6 {
            for i in 0..<8 { steps[i + 8] = steps[i] }
            if let s = steps[14] { steps[14] = SeqStep(note: pick([12, -2, 1, 7], &rng), accent: s.accent) }
        }
        return steps
    }

    /// Robot bleeps ("Pocket Calculator"): sparse, high, wide intervals.
    private static func robot(_ rng: inout SystemRandomNumberGenerator) -> [SeqStep?] {
        let scale = Self.scale(for: 2)
        let hits = euclid(pick([4, 5, 6, 7], &rng), 16, rotate: Int.random(in: 0...3, using: &rng))
        var steps: [SeqStep?] = []
        for i in 0..<16 {
            if hits[i] || i == 0 {
                steps.append(SeqStep(note: i == 0 ? 0 : pick(scale, &rng),
                                     accent: Double.random(in: 0..<1, using: &rng) < 0.3))
            } else {
                steps.append(nil)
            }
        }
        return steps
    }

    /// Electro acid: dense, slides (ties) and accents, minor scale.
    private static func acid(_ rng: inout SystemRandomNumberGenerator) -> [SeqStep?] {
        let scale = Self.scale(for: 3)
        let hits = euclid(pick([11, 12, 13], &rng), 16, rotate: 0)
        var steps: [SeqStep?] = []
        for i in 0..<16 {
            guard hits[i] || i == 0 else {
                steps.append(nil)
                continue
            }
            let tie = i < 15 && hits[i + 1] && Double.random(in: 0..<1, using: &rng) < 0.25
            steps.append(SeqStep(note: i == 0 ? 0 : pick(scale, &rng),
                                 accent: Double.random(in: 0..<1, using: &rng) < 0.35,
                                 tie: tie))
        }
        return steps
    }

    // MARK: Helpers

    private static func pick(_ values: [Int], _ rng: inout SystemRandomNumberGenerator) -> Int {
        values[Int.random(in: 0..<values.count, using: &rng)]
    }

    /// Euclidean rhythm: `k` hits spread as evenly as possible over `n` steps.
    static func euclid(_ k: Int, _ n: Int, rotate: Int) -> [Bool] {
        (0..<n).map { i in
            let j = (i + rotate) % n
            return (j * k) % n < k
        }
    }
}
