import Foundation

@inline(__always) func clampf(_ x: Float, _ lo: Float, _ hi: Float) -> Float {
    x < lo ? lo : (x > hi ? hi : x)
}

/// Wraps a phase into [0, 1).
@inline(__always) func wrap01(_ x: Float) -> Float {
    x - floorf(x)
}

/// Two-sample polynomial band-limited step residual (PolyBLEP).
/// Corresponds to a step of -2 at t = 0 (the reset of a rising saw).
@inline(__always) func polyBlep(_ t: Float, _ dt: Float) -> Float {
    if t < dt {
        let x = t / dt
        return x + x - x * x - 1
    } else if t > 1 - dt {
        let x = (t - 1) / dt
        return x * x + x + x + 1
    }
    return 0
}

/// Band-limited correction for a step of height `h` located at phase `edge`.
@inline(__always) func blepStep(_ t: Float, _ dt: Float, edge: Float, height h: Float) -> Float {
    0.5 * h * polyBlep(wrap01(t - edge), dt)
}

/// Rational tanh approximation, accurate enough for saturation duties.
@inline(__always) func softClip(_ x: Float) -> Float {
    let c = clampf(x, -3, 3)
    let c2 = c * c
    return c * (27 + c2) / (27 + 9 * c2)
}

@inline(__always) func noteToHz(_ note: Float) -> Float {
    440 * exp2f((note - 69) / 12)
}

/// Very small, fast white-noise generator suitable for the audio thread.
struct XorShift32 {
    var state: UInt32

    init(seed: UInt32) { state = seed == 0 ? 0x9E3779B9 : seed }

    @inline(__always) mutating func next() -> Float {
        state ^= state << 13
        state ^= state >> 17
        state ^= state << 5
        return Float(Int32(bitPattern: state)) * (1.0 / 2147483648.0)
    }
}

/// One biquad section (transposed direct form II). Coefficients live in
/// `BiquadCoefficients` so many voices can share them.
struct BiquadCoefficients {
    var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0

    static let bypass = BiquadCoefficients()

    static func highPass(freq: Float, q: Float, sampleRate: Float) -> BiquadCoefficients {
        let w = 2 * Float.pi * freq / sampleRate
        let cw = cosf(w), alpha = sinf(w) / (2 * q)
        let a0 = 1 + alpha
        return BiquadCoefficients(b0: (1 + cw) / 2 / a0, b1: -(1 + cw) / a0, b2: (1 + cw) / 2 / a0,
                                  a1: -2 * cw / a0, a2: (1 - alpha) / a0)
    }

    static func lowShelf(freq: Float, gainDB: Float, sampleRate: Float) -> BiquadCoefficients {
        let a = powf(10, gainDB / 40)
        let w = 2 * Float.pi * freq / sampleRate
        let cw = cosf(w), sw = sinf(w)
        let alpha = sw / 2 * sqrtf(2)
        let sa = 2 * sqrtf(a) * alpha
        let a0 = (a + 1) + (a - 1) * cw + sa
        return BiquadCoefficients(
            b0: a * ((a + 1) - (a - 1) * cw + sa) / a0,
            b1: 2 * a * ((a - 1) - (a + 1) * cw) / a0,
            b2: a * ((a + 1) - (a - 1) * cw - sa) / a0,
            a1: -2 * ((a - 1) + (a + 1) * cw) / a0,
            a2: ((a + 1) + (a - 1) * cw - sa) / a0)
    }
}

struct BiquadState {
    var z1: Float = 0, z2: Float = 0

    @inline(__always) mutating func process(_ x: Float, _ c: BiquadCoefficients) -> Float {
        let y = c.b0 * x + z1
        z1 = c.b1 * x - c.a1 * y + z2
        z2 = c.b2 * x - c.a2 * y
        return y
    }

    mutating func reset() { z1 = 0; z2 = 0 }
}
