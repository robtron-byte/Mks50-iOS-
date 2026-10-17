import Foundation

/// Times (seconds, already key-follow scaled) and levels (0...1) of the
/// Alpha Juno 4-segment envelope: T1→L1, T2→L2, T3→L3 (sustain), T4→0.
struct EnvelopeSettings {
    var t1: Float = 0.001, l1: Float = 1
    var t2: Float = 0.001, l2: Float = 1
    var t3: Float = 0.001, l3: Float = 1
    var t4: Float = 0.05
}

struct Envelope {
    enum Stage { case idle, segment1, segment2, segment3, sustain, release }

    private(set) var stage: Stage = .idle
    private(set) var value: Float = 0
    private var start: Float = 0
    private var target: Float = 0
    private var progress: Float = 0
    private var increment: Float = 0
    var sampleRate: Float = 44100

    var isIdle: Bool { stage == .idle }

    mutating func reset() {
        stage = .idle
        value = 0
    }

    /// Key on. Starts from the current level so retriggers don't click.
    mutating func gateOn(_ s: EnvelopeSettings) {
        begin(.segment1, to: s.l1, time: s.t1)
    }

    mutating func gateOff(_ s: EnvelopeSettings) {
        guard stage != .idle else { return }
        begin(.release, to: 0, time: s.t4)
    }

    private mutating func begin(_ next: Stage, to level: Float, time: Float) {
        stage = next
        start = value
        target = level
        progress = 0
        increment = 1 / max(time * sampleRate, 1)
    }

    /// Exponential-looking segment shape with an exact, finite duration.
    @inline(__always) private static func curve(_ p: Float) -> Float {
        // (1 - e^(-4.5 p)) / (1 - e^(-4.5))
        (1 - expf(-4.5 * p)) * 1.011_235
    }

    @inline(__always) mutating func next(_ s: EnvelopeSettings) -> Float {
        switch stage {
        case .idle:
            return 0
        case .sustain:
            // Follow live changes of L3 smoothly.
            value += (s.l3 - value) * 0.002
            return value
        default:
            progress += increment
            if progress >= 1 {
                value = target
                advance(s)
            } else {
                // Attack is linear (charging towards a high target on analog
                // gear looks nearly linear), all others exponential.
                let shape = stage == .segment1 ? progress : Envelope.curve(progress)
                value = start + (target - start) * shape
            }
            return value
        }
    }

    private mutating func advance(_ s: EnvelopeSettings) {
        switch stage {
        case .segment1: begin(.segment2, to: s.l2, time: s.t2)
        case .segment2: begin(.segment3, to: s.l3, time: s.t3)
        case .segment3: stage = .sustain
        case .release: stage = .idle; value = 0
        default: break
        }
    }
}
