import Foundation

/// Per-block oscillator settings derived from the tone parameters.
struct DCOSettings {
    var pulse: Int = 0
    var saw: Int = 1
    var sub: Int = 0
    var subLevel: Float = 0
    var noiseLevel: Float = 0
    /// Pulse width in 0.04...0.5 (0.5 = square).
    var pw: Float = 0.5
}

/// Alpha Juno / MKS-50 style DCO.
///
/// One master phase runs at f/4 so the main, sub (-1 oct) and sub (-2 oct)
/// waveforms are all phase-locked like the hardware's divider chain.
/// All waveforms are band-limited with PolyBLEP residuals.
///
/// The MKS-50 offers 4 pulse, 6 sawtooth and 6 sub waveforms. The variants
/// here recreate their character (gated / chopped / PWM'd shapes); they are
/// models, not sample-exact copies of the Roland waveform ROM.
struct DCO {
    var phase: Float = 0
    var noise: XorShift32

    init(seed: UInt32) {
        noise = XorShift32(seed: seed)
    }

    mutating func reset() { phase = 0 }

    // MARK: Band-limited primitives

    @inline(__always) static func saw(_ t: Float, _ dt: Float) -> Float {
        2 * t - 1 - polyBlep(t, dt)
    }

    @inline(__always) static func square(_ t: Float, _ dt: Float) -> Float {
        (t < 0.5 ? 1 : -1) + polyBlep(t, dt) - polyBlep(wrap01(t + 0.5), dt)
    }

    @inline(__always) static func pulse(_ t: Float, _ dt: Float, _ w: Float) -> Float {
        (t < w ? 1 : -1) + polyBlep(t, dt) - polyBlep(wrap01(t - w), dt)
    }

    /// Sawtooth that is only passed while t < w (Alpha Juno "saw x pulse").
    @inline(__always) static func gatedSaw(_ t: Float, _ dt: Float, _ w: Float) -> Float {
        (t < w ? 2 * t - 1 : 0)
            + blepStep(t, dt, edge: 0, height: -1)
            + blepStep(t, dt, edge: w, height: 1 - 2 * w)
    }

    /// Sawtooth chopped by a square wave one octave higher.
    @inline(__always) static func choppedSaw(_ t: Float, _ dt: Float) -> Float {
        let open = t < 0.25 || (t >= 0.5 && t < 0.75)
        return (open ? 2 * t - 1 : 0)
            + blepStep(t, dt, edge: 0, height: -1)
            + blepStep(t, dt, edge: 0.25, height: 0.5)
            + blepStep(t, dt, edge: 0.75, height: -0.5)
    }

    // MARK: Render

    /// - Parameter dt: phase increment of the main (8') waveform in cycles/sample.
    @inline(__always) mutating func tick(dt rawDt: Float, _ s: DCOSettings) -> Float {
        let dt = min(rawDt, 0.45)
        phase += dt * 0.25
        if phase >= 1 { phase -= 1 }

        let p4 = phase
        let p2 = wrap01(phase * 2)
        let p1 = wrap01(phase * 4)
        let pw = s.pw

        var out: Float = 0

        switch s.pulse {
        case 1: out += DCO.square(p1, dt)
        case 2: out += DCO.pulse(p1, dt, pw)
        case 3: out += 0.75 * DCO.pulse(p1, dt, pw) - 0.35 * DCO.square(wrap01(p1 * 2), min(dt * 2, 0.5))
        default: break
        }

        switch s.saw {
        case 1: out += DCO.saw(p1, dt)
        case 2: out += DCO.gatedSaw(p1, dt, pw + 0.5)
        case 3: out += DCO.choppedSaw(p1, dt)
        case 4: out += 0.6 * DCO.saw(p1, dt) + 0.6 * DCO.gatedSaw(p1, dt, pw)
        case 5: out += DCO.saw(p1, dt) - 0.6 * DCO.pulse(p1, dt, pw)
        default: break
        }

        if s.sub > 0 && s.subLevel > 0 {
            let d2 = dt * 0.5, d4 = dt * 0.25
            let sub: Float
            switch s.sub {
            case 1: sub = DCO.square(p2, d2)
            case 2: sub = DCO.pulse(p2, d2, 0.25)
            case 3: sub = DCO.square(p4, d4)
            case 4: sub = DCO.pulse(p4, d4, 0.25)
            default: sub = 0.5 * (DCO.square(p2, d2) + DCO.square(p4, d4))
            }
            out += sub * s.subLevel
        }

        if s.noiseLevel > 0 {
            out += noise.next() * s.noiseLevel
        }
        return out
    }
}
