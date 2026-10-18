import Foundation

/// Tempo-synced arpeggiator (audio thread, no allocation).
///
/// Collects the held keys and, on every step of the beat clock, picks the
/// next note of the pattern. The engine plays the notes through its normal
/// note path, so the arpeggio follows the key mode (poly, chord, mono,
/// unison) and the envelope trigger setting.
struct Arpeggiator {
    static let modeNames = ["UP", "DOWN", "UP/DN", "RAND", "ORDER"]
    static let capacity = 16

    /// ARP GATE 0...127 → 5 ... 100 % of a step.
    static func gateFraction(_ raw: Float) -> Double {
        0.05 + 0.95 * Double(max(0, min(127, raw))) / 127
    }

    /// Keys in the order they were played, with their velocities.
    private(set) var keys = [Int](repeating: 0, count: capacity)
    private var velocities = [Int](repeating: 100, count: capacity)
    private(set) var count = 0
    /// Scratch buffer for the sorted pattern (allocated once).
    private var sorted = [Int](repeating: 0, count: capacity)

    /// Note currently sounding (-1: none) and when it has to stop.
    private(set) var soundingKey = -1
    private var gateOffBeat: Double = 0
    private var lastStep: Int64 = .min
    private var position = 0
    private var random = XorShift32(seed: 0xA4B3_C2D1)

    var isEmpty: Bool { count == 0 }

    mutating func add(_ key: Int, velocity: Int) {
        remove(key)
        if count == Arpeggiator.capacity {
            for j in 1..<count {
                keys[j - 1] = keys[j]
                velocities[j - 1] = velocities[j]
            }
            count -= 1
        }
        if count == 0 {
            // A fresh chord starts the pattern from the top, right away.
            position = 0
            lastStep = .min
        }
        keys[count] = key
        velocities[count] = velocity
        count += 1
    }

    mutating func remove(_ key: Int) {
        var w = 0
        for r in 0..<count where keys[r] != key {
            keys[w] = keys[r]
            velocities[w] = velocities[r]
            w += 1
        }
        count = w
    }

    mutating func removeAll() {
        count = 0
    }

    /// Forgets everything without note events (voices already released).
    mutating func reset() {
        count = 0
        soundingKey = -1
        lastStep = .min
    }

    /// Advances to `beat`. Calls `noteOff` / `noteOn` for the events due.
    mutating func process(beat: Double, rateIndex: Int, octaves: Int, mode: Int, gate: Double,
                          noteOn: (Int, Int) -> Void, noteOff: (Int) -> Void) {
        let quarters = LFOShape.divisionQuarters[min(max(rateIndex, 0), LFOShape.divisionQuarters.count - 1)]

        if soundingKey >= 0 && (beat >= gateOffBeat || count == 0) {
            noteOff(soundingKey)
            soundingKey = -1
        }
        guard count > 0 else {
            lastStep = .min
            return
        }

        let step = Int64((beat / quarters).rounded(.down))
        guard step != lastStep else { return }
        // The first note plays immediately; later notes on the grid.
        lastStep = step

        if soundingKey >= 0 {
            noteOff(soundingKey)
            soundingKey = -1
        }
        let (key, velocity) = nextNote(octaves: octaves, mode: mode)
        noteOn(key, velocity)
        soundingKey = key
        gateOffBeat = Double(step) * quarters + quarters * gate
        if gateOffBeat <= beat { gateOffBeat = beat + quarters * gate }
    }

    /// Stops the sounding note (arp switched off, all notes off).
    mutating func stop(noteOff: (Int) -> Void) {
        if soundingKey >= 0 { noteOff(soundingKey) }
        soundingKey = -1
        lastStep = .min
    }

    private mutating func nextNote(octaves: Int, mode: Int) -> (Int, Int) {
        let n = count
        // Pattern source: ascending pitch, or played order for ORDER.
        for i in 0..<n { sorted[i] = i }
        if mode != 4 {
            // Insertion sort of indices by key (n ≤ 16).
            for i in 1..<max(n, 1) {
                let v = sorted[i]
                var j = i - 1
                while j >= 0 && keys[sorted[j]] > keys[v] {
                    sorted[j + 1] = sorted[j]
                    j -= 1
                }
                sorted[j + 1] = v
            }
        }
        let total = n * (min(max(octaves, 0), 3) + 1)
        var index: Int
        switch mode {
        case 1:     // DOWN
            index = total - 1 - position % total
        case 2:     // UP/DOWN without repeating the end notes
            let period = max(1, 2 * total - 2)
            let m = position % period
            index = m < total ? m : period - m
        case 3:     // RANDOM
            index = Int((random.next() * 0.5 + 0.5) * Float(total))
        default:    // UP, ORDER
            index = position % total
        }
        index = min(max(index, 0), total - 1)
        position = (position + 1) % 1_000_000   // just keeps the counter bounded
        let slot = sorted[index % n]
        let key = min(127, keys[slot] + 12 * (index / n))
        return (key, velocities[slot])
    }
}
