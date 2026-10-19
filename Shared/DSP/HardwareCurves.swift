import Foundation

/// Parameter curves of the original Alpha Juno-2 / MKS-50 (0...127 → real
/// units).
///
/// Sources: the tables of the june-21 Alpha Juno emulator, which were
/// measured on a real Juno-2 (its author notes the measurements were not
/// perfectly stable), sampled every 16 steps and interpolated
/// exponentially in between; and the MB87123 DCO bit model (see DCO.swift).
/// All tables are touched once in `warmUp()` so the audio thread never
/// initialises them.
enum HardwareCurves {
    // Values at 0, 16, 32, 48, 64, 80, 96, 112, 127.
    private static let envT3: [Float] = [0.09, 0.184, 0.266, 0.474, 1.032, 3.03, 11.864, 23.102, 37.58]
    private static let envT4: [Float] = [0.007, 0.0564, 0.2032, 0.6632, 1.904, 5.2, 11.454, 23.182, 39.34]
    private static let lfoRate: [Float] = [0.02, 0.0508, 0.1434, 0.4028, 1.1935, 3.2167, 9.7766, 25.6894, 64.9854]
    private static let pwmRate: [Float] = [0.02, 0.0436, 0.1048, 0.2494, 0.6535, 1.5306, 3.6868, 8.7365, 20.429]
    private static let chorusRate: [Float] = [0.01, 0.0217, 0.0524, 0.1243, 0.3117, 0.777, 1.8335, 4.83, 10.2564]
    /// DCO LFO MOD: peak frequency deviation as a fraction of the pitch.
    private static let vibratoFraction: [Float] = [0, 0.0212, 0.0477, 0.0736, 0.104, 0.1544, 0.2174, 0.3205, 0.4279]

    static func warmUp() {
        _ = envT3.count + envT4.count + lfoRate.count + pwmRate.count + chorusRate.count + vibratoFraction.count
    }

    @inline(__always) private static func segment(_ raw: Float) -> (Int, Float) {
        let v = min(max(raw, 0), 127)
        let i = min(Int(v / 16), 7)
        let x0 = Float(i * 16)
        let x1: Float = i == 7 ? 127 : x0 + 16
        return (i, (v - x0) / (x1 - x0))
    }

    /// Exponential (log-linear) interpolation for times and rates.
    @inline(__always) private static func expInterp(_ table: [Float], _ raw: Float) -> Float {
        let (i, t) = segment(raw)
        return table[i] * powf(table[i + 1] / table[i], t)
    }

    @inline(__always) private static func linInterp(_ table: [Float], _ raw: Float) -> Float {
        let (i, t) = segment(raw)
        return table[i] + (table[i + 1] - table[i]) * t
    }

    /// Envelope segment time in seconds. T1 / T2 follow 0.354 s · 2^((v − 64) / 10)
    /// (4 ms ... 27 s), T3 and T4 their own measured tables.
    @inline(__always) static func envelopeSeconds(_ raw: Float, segment: Int) -> Float {
        switch segment {
        case 3: return expInterp(envT3, raw)
        case 4: return expInterp(envT4, raw)
        default: return 0.354 * exp2f((min(max(raw, 0), 127) - 64) / 10)
        }
    }

    /// LFO rate, about 0.02 Hz ... 65 Hz.
    @inline(__always) static func lfoHz(_ raw: Float) -> Float { expInterp(lfoRate, raw) }

    /// PW LFO rate for PWM RATE 1...127 (0 = manual pulse width).
    @inline(__always) static func pwmHz(_ raw: Float) -> Float { expInterp(pwmRate, raw) }

    /// Chorus LFO rate, about 0.01 Hz ... 10 Hz.
    @inline(__always) static func chorusHz(_ raw: Float) -> Float { expInterp(chorusRate, raw) }

    /// LFO DELAY in seconds: exp(v / 14.2 − 3) / 10, 0 = no delay (up to about 38 s).
    @inline(__always) static func lfoDelaySeconds(_ raw: Float) -> Float {
        raw < 0.5 ? 0 : expf(min(raw, 127) / 14.2 - 3) / 10
    }

    /// DCO LFO MOD depth as peak deviation in semitones (0 ... about 3.3).
    @inline(__always) static func vibratoSemitones(_ raw: Float) -> Float {
        12 * log2f(1 + linInterp(vibratoFraction, raw) / 2)
    }
}
