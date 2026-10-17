import Foundation

/// Juno-style stereo BBD chorus: a single modulated delay line whose wet
/// signal is taken with opposite LFO polarity for left and right.
final class Chorus {
    private let size = 16384 // > 80 ms at 192 kHz, power of two
    private let mask: Int
    private let buffer: UnsafeMutablePointer<Float>
    private var writeIndex = 0
    private var lfoPhase: Float = 0
    private var sampleRate: Float = 44100
    private var wetLowpassL: Float = 0
    private var wetLowpassR: Float = 0
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
        // BBD anti-alias / reconstruction filter around 9 kHz.
        lowpassCoef = 1 - expf(-2 * Float.pi * 9000 / sampleRate)
        reset()
    }

    func reset() {
        buffer.update(repeating: 0, count: size)
        wetLowpassL = 0
        wetLowpassR = 0
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
            buffer[writeIndex & mask] = 0.5 * (xl + xr)

            mix += (target - mix) * 0.001
            var outL = xl
            var outR = xr
            if mix > 0.0001 {
                lfoPhase += inc
                if lfoPhase >= 1 { lfoPhase -= 1 }
                let tri = 4 * abs(lfoPhase - 0.5) - 1 // -1...1
                let wetL = read(center + depth * tri)
                let wetR = read(center - depth * tri)
                wetLowpassL += (wetL - wetLowpassL) * lowpassCoef
                wetLowpassR += (wetR - wetLowpassR) * lowpassCoef
                // Dry level drops a little when chorus is on, like the original.
                let dry = 1 - 0.3 * mix
                outL = xl * dry + wetLowpassL * 0.75 * mix
                outR = xr * dry + wetLowpassR * 0.75 * mix
            }
            left[n] = outL
            right[n] = outR
            writeIndex = (writeIndex + 1) & mask
        }
    }
}
