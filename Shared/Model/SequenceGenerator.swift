import Foundation

/// Random electro sequences that stay musical: every style draws from a
/// fixed scale, a style-typical rhythm and repetition (motifs, call and
/// response), which is what makes Kraftwerk / Anthony Rother style lines
/// sound "right" instead of random.
enum SequenceGenerator {
    static let styleNames = ["KRAFT", "ROTHER", "ROBOT", "ACID", "MIAMI"]

    /// Returns 16 raw step values (see `SeqStep`).
    static func generate(style: Int) -> [Int] {
        var rng = SystemRandomNumberGenerator()
        let steps: [SeqStep?]
        switch style {
        case 1: steps = rother(&rng)
        case 2: steps = robot(&rng)
        case 3: steps = acid(&rng)
        case 4: steps = miami(&rng)
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
        case 4: return [0, 0, 0, 0, 5, 7, -5, 3, -2, 12]             // 808 bass: root, 4th, 5th, octave
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

    /// Anthony Rother, measured on the bass stems of DEKATRON (2026): 3–11
    /// notes a bar (most 4–8), single 16ths with the odd slide, mostly off
    /// the kick (the line interlocks with the electro kick x..x..x...x..x..),
    /// moving by steps in phrygian minor: repeats, a semitone or tone,
    /// fourths and fifths, thirds.
    private static func rother(_ rng: inout SystemRandomNumberGenerator) -> [SeqStep?] {
        let count = pick([3, 4, 4, 5, 5, 6, 7], &rng)
        let moves = [0, 0, -1, -1, -1, -1, 1, 5, -5, 7, -7, 3, -3, 2, -2, 4, -4, 12]
        let kick: Set<Int> = [3, 6, 10, 13]                          // the kick figure it dodges
        let hits = euclid(count, 16, rotate: Int.random(in: 0..<16, using: &rng))
        var on = Set<Int>([0])
        for i in 0..<16 where hits[i] {
            var k = i
            if kick.contains(k) && Double.random(in: 0..<1, using: &rng) >= 0.25 { k = (k + 1) % 16 }
            on.insert(k)
        }
        var steps: [SeqStep?] = Array(repeating: nil, count: 16)
        var note = 0
        for i in 0..<16 where on.contains(i) {
            if i > 0 { note = phrygian(min(max(note + pick(moves, &rng), -5), 13)) }
            let offbeat = i % 4 == 2 || i % 4 == 3
            let accent = i == 0 || (offbeat && Double.random(in: 0..<1, using: &rng) < 0.45)
            let tie = i < 15 && on.contains(i + 1) && Double.random(in: 0..<1, using: &rng) < 0.12
            steps[i] = SeqStep(note: note, accent: accent, tie: tie)
        }
        // Call and response: repeat the first half, vary its end.
        if Double.random(in: 0..<1, using: &rng) < 0.6 {
            for i in 0..<8 { steps[i + 8] = steps[i] }
            if let s = steps[14] { steps[14] = SeqStep(note: pick([12, -2, 1, 7], &rng), accent: s.accent) }
        }
        return steps
    }

    /// Miami / Egyptian Lover 808 bass, measured on the bass stems of The
    /// Egyptian Lover's 1986: 2–6 notes a bar on the kick figure, held for
    /// 2–5 steps, the root most of the time, with fourths, fifths, the minor
    /// third, the seventh below and the octave.
    private static func miami(_ rng: inout SystemRandomNumberGenerator) -> [SeqStep?] {
        let figures: [[Int]] = [[0, 6, 10], [0, 4, 6, 10], [0, 6, 8, 11], [0, 4, 6, 8, 12], [0, 6, 10, 13]]
        let on = pick(figures, &rng)
        var steps: [SeqStep?] = Array(repeating: nil, count: 16)
        for (n, i) in on.enumerated() {
            let note = i == 0 || Double.random(in: 0..<1, using: &rng) < 0.75 ? 0 : pick([5, 7, -5, 3, -2, 12, 12], &rng)
            let next = n + 1 < on.count ? on[n + 1] : 16
            let accent = i == 0 || Double.random(in: 0..<1, using: &rng) < 0.3
            steps[i] = SeqStep(note: note, accent: accent)
            // Long 808 notes: held into the next steps.
            if Double.random(in: 0..<1, using: &rng) < 0.65 {
                let length = Int.random(in: 2...5, using: &rng)
                var k = 1
                while k < length && i + k < next {
                    steps[i + k - 1]!.tie = true
                    steps[i + k] = SeqStep(note: note)
                    k += 1
                }
            }
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

    /// Nearest degree of phrygian minor (0 1 3 5 7 8 10).
    private static func phrygian(_ n: Int) -> Int {
        let degree = [0, 1, 1, 3, 3, 5, 5, 7, 8, 8, 10, 10]
        let octave = Int((Double(n) / 12).rounded(.down))
        return 12 * octave + degree[n - 12 * octave]
    }

    private static func pick<T>(_ values: [T], _ rng: inout SystemRandomNumberGenerator) -> T {
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
