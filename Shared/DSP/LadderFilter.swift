import Foundation

/// 24 dB/oct resonant low-pass in the spirit of the IR3109 OTA filter used in
/// the Alpha Juno / MKS-50.
///
/// Topology-preserving-transform (zero-delay feedback) cascade of four
/// one-pole sections with global feedback. The feedback loop is solved
/// linearly and a soft saturator is applied at the input, which keeps the
/// filter stable at any cutoff and lets it self-oscillate at high resonance.
struct LadderFilter {
    private var s1: Float = 0, s2: Float = 0, s3: Float = 0, s4: Float = 0
    private var g: Float = 0.1
    private var G: Float = 0.09
    private var k: Float = 0

    mutating func reset() { s1 = 0; s2 = 0; s3 = 0; s4 = 0 }

    /// - Parameters:
    ///   - cutoff: Hz
    ///   - resonance: 0...1 (>= ~0.95 self-oscillates)
    @inline(__always) mutating func setCoefficients(cutoff: Float, resonance: Float, sampleRate: Float) {
        let fc = clampf(cutoff, 8, sampleRate * 0.45)
        g = tanf(Float.pi * fc / sampleRate)
        G = g / (1 + g)
        k = resonance * 4.15
    }

    @inline(__always) mutating func process(_ input: Float) -> Float {
        let G2 = G * G
        let G3 = G2 * G
        let G4 = G3 * G
        let inv = 1 / (1 + g)

        // Contributions of the stage states to the output (S_i = s_i / (1 + g)).
        let sigma = (G3 * s1 + G2 * s2 + G * s3 + s4) * inv
        // Passband gain compensation like the hardware's resonance makeup.
        let x = input * (1 + 0.35 * k) + 1e-20
        let y4Estimate = (G4 * x + sigma) / (1 + k * G4)
        let u = softClip(x - k * y4Estimate)

        var v = (u - s1) * G
        let y1 = v + s1
        s1 = y1 + v

        v = (y1 - s2) * G
        let y2 = v + s2
        s2 = y2 + v

        v = (y2 - s3) * G
        let y3 = v + s3
        s3 = y3 + v

        v = (y3 - s4) * G
        let y4 = v + s4
        s4 = y4 + v

        return y4
    }
}
