import Foundation

/// Stereo BBD chorus modelled on the MN3009 / MN3101 circuit used in the
/// MKS-50 (same family as Juno-60 / JX-3P): one modulated delay line whose wet
/// signal is taken with opposite triangle-LFO polarity for left and right,
/// two-pole anti-alias / reconstruction filtering around the bucket brigade,
/// gentle BBD saturation and a very low hiss floor.
final class Chorus {
    private let size = 16384 // > 80 ms at 192 kHz, power of two
    private let mask: Int
    private let buffer: UnsafeMutablePointer<Float>
    private var writeIndex = 0
    private var lfoPhase: Float = 0
    private var sampleRate: Float = 44100
    private var inputLowpass1: Float = 0
    private var inputLowpass2: Float = 0
    private var wetLowpassL: Float = 0
    private var wetLowpassR: Float = 0
    private var wetLowpassL2: Float = 0
    private var wetLowpassR2: Float = 0
    private var hiss = XorShift32(seed: 0xB0B0_CAFE)
    private var lowpassCoef: Float = 0.5
    /// 0 = off, 1 = on. Smoothed to avoid clicks when switching.
    private var mix: Float = 0

    init() {
        mask = size - 1
        buffer = .allocate(capacity: size)
        buffer.initialize(repeating: 0, count: size)
    }

    deinit { buffer.deallocate() }

    func prepare(sampleRate: Float) {
        self.sampleRate = sampleRate
        // BBD anti-alias / reconstruction filters (2 poles each, ~8 kHz).
        lowpassCoef = 1 - expf(-2 * Float.pi * 8000 / sampleRate)
        reset()
    }

    func reset() {
        buffer.update(repeating: 0, count: size)
        inputLowpass1 = 0
        inputLowpass2 = 0
        wetLowpassL = 0
        wetLowpassR = 0
        wetLowpassL2 = 0
        wetLowpassR2 = 0
    }

    @inline(__always) private func read(_ delaySamples: Float) -> Float {
        let pos = Float(writeIndex) - delaySamples
        let i = Int(floorf(pos))
        let frac = pos - Float(i)
        let a = buffer[i & mask]
        let b = buffer[(i + 1) & mask]
        return a + (b - a) * frac
    }

    /// - Parameters:
    ///   - enabled: chorus switch
    ///   - rate: LFO rate in Hz
    /// The BBD is fed with the mono sum (like the hardware); the dry signal
    /// keeps its stereo image (unison panning).
    func process(inputLeft: UnsafePointer<Float>, inputRight: UnsafePointer<Float>,
                 left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>,
                 frames: Int, enabled: Bool, rate: Float) {
        let target: Float = enabled ? 1 : 0
        let inc = rate / sampleRate
        let center = 0.0035 * sampleRate
        // Slightly less depth at fast rates, like the Juno modes.
        let depth = (0.0019 - min(rate, 8) * 0.0001) * sampleRate

        for n in 0..<frames {
            let xl = inputLeft[n]
            let xr = inputRight[n]
            // Anti-alias filter in front of the BBD, then mild bucket saturation.
            inputLowpass1 += (0.5 * (xl + xr) - inputLowpass1) * lowpassCoef
            inputLowpass2 += (inputLowpass1 - inputLowpass2) * lowpassCoef
            buffer[writeIndex & mask] = softClip(inputLowpass2 * 0.8) * 1.25

            mix += (target - mix) * 0.001
            var outL = xl
            var outR = xr
            if mix > 0.0001 {
                lfoPhase += inc
                if lfoPhase >= 1 { lfoPhase -= 1 }
                let tri = 4 * abs(lfoPhase - 0.5) - 1 // -1...1
                let wetL = read(center + depth * tri)
                let wetR = read(center - depth * tri)
                // Reconstruction filter + BBD hiss (about -84 dBFS).
                let noise = hiss.next() * 0.00006
                wetLowpassL += (wetL + noise - wetLowpassL) * lowpassCoef
                wetLowpassR += (wetR - noise - wetLowpassR) * lowpassCoef
                wetLowpassL2 += (wetLowpassL - wetLowpassL2) * lowpassCoef
                wetLowpassR2 += (wetLowpassR - wetLowpassR2) * lowpassCoef
                // Dry level drops a little when chorus is on, like the original.
                let dry = 1 - 0.3 * mix
                outL = xl * dry + wetLowpassL2 * 0.75 * mix
                outR = xr * dry + wetLowpassR2 * 0.75 * mix
            }
            left[n] = outL
            right[n] = outR
            writeIndex = (writeIndex + 1) & mask
        }
    }
}
