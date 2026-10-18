import Foundation

/// Tempo-syncable stereo delay with ping-pong, in the spirit of the TAL-Pha FX
/// section. The feedback path is band-limited (tone low-pass + 150 Hz high-pass)
/// and softly saturated, so long feedback stays musical instead of muddy.
final class StereoDelay {
    private let size = 1 << 18          // 262 144 samples ≈ 5.4 s at 48 kHz
    private let mask: Int
    private let bufferL: UnsafeMutablePointer<Float>
    private let bufferR: UnsafeMutablePointer<Float>
    private var writeIndex = 0
    private var sampleRate: Float = 44100
    private var delaySmoothed: Float = 0
    private var lowL: Float = 0, lowR: Float = 0
    private var highL: Float = 0, highR: Float = 0
    private var highCoef: Float = 0.02
    private var mixSmoothed: Float = 0
    private var isClear = true

    init() {
        mask = size - 1
        bufferL = .allocate(capacity: size)
        bufferR = .allocate(capacity: size)
        bufferL.initialize(repeating: 0, count: size)
        bufferR.initialize(repeating: 0, count: size)
    }

    deinit {
        bufferL.deallocate()
        bufferR.deallocate()
    }

    func prepare(sampleRate: Float) {
        self.sampleRate = sampleRate
        highCoef = 1 - expf(-2 * Float.pi * 150 / sampleRate)
        reset()
    }

    func reset() {
        guard !isClear else { return }
        bufferL.update(repeating: 0, count: size)
        bufferR.update(repeating: 0, count: size)
        lowL = 0; lowR = 0; highL = 0; highR = 0
        mixSmoothed = 0
        isClear = true
    }

    @inline(__always) private func read(_ buffer: UnsafeMutablePointer<Float>, _ delay: Float) -> Float {
        let pos = Float(writeIndex) - delay
        let i = Int(floorf(pos))
        let frac = pos - Float(i)
        let a = buffer[i & mask]
        let b = buffer[(i + 1) & mask]
        return a + (b - a) * frac
    }

    /// - Parameters:
    ///   - seconds: delay time
    ///   - feedback: 0...1.15; above 1 the loop self-oscillates (dub
    ///     style) and is held by the soft clipper in the feedback path
    ///   - tone: 0...1 (dark ... bright)
    func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int,
                 mix: Float, seconds: Float, feedback: Float, tone: Float, pingPong: Bool) {
        // Fully off: no work at all; the buffer is cleared once so old echoes
        // never reappear when the delay is switched on again.
        if mix < 0.0005 && mixSmoothed < 0.0005 {
            reset()
            return
        }
        isClear = false

        let target = clampf(seconds * sampleRate, 1, Float(size - 4))
        if delaySmoothed == 0 { delaySmoothed = target }
        let lowCoef = 1 - expf(-2 * Float.pi * (1200 + tone * tone * 14000) / sampleRate)
        let fb = clampf(feedback, 0, 1.15)

        for n in 0..<frames {
            // Smooth time changes (tape-like glide instead of clicks).
            delaySmoothed += (target - delaySmoothed) * 0.0005
            mixSmoothed += (mix - mixSmoothed) * 0.002

            let inL = left[n]
            let inR = right[n]
            var wetL = read(bufferL, delaySmoothed)
            var wetR = read(bufferR, delaySmoothed)

            // Feedback filtering: tone low-pass, then remove rumble.
            lowL += (wetL - lowL) * lowCoef
            lowR += (wetR - lowR) * lowCoef
            highL += (lowL - highL) * highCoef
            highR += (lowR - highR) * highCoef
            wetL = lowL - highL
            wetR = lowR - highR

            let writeL: Float
            let writeR: Float
            if pingPong {
                // Input enters left only and bounces L → R → L.
                writeL = 0.5 * (inL + inR) + wetR * fb
                writeR = wetL * fb
            } else {
                writeL = inL + wetL * fb
                writeR = inR + wetR * fb
            }
            // The clipper bounds a runaway loop at about ±0.8.
            bufferL[writeIndex] = softClip(writeL * 1.25) * 0.8
            bufferR[writeIndex] = softClip(writeR * 1.25) * 0.8
            writeIndex = (writeIndex + 1) & mask

            left[n] = inL + wetL * mixSmoothed
            right[n] = inR + wetR * mixSmoothed
        }
    }
}

/// Compact stereo reverb: 4 input diffusers + 8-line feedback delay network
/// with a Householder matrix (O(N) mixing), per-line damping and slight
/// delay-line modulation. Smooth plate/hall character at low CPU cost.
final class Reverb {
    private static let lineCount = 8
    private static let lineCapacity = 1 << 14
    private static let baseLengths: [Float] = [1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617] // @44.1k
    private static let diffuserLengths: [Float] = [142, 107, 379, 277]
    private static let diffuserCapacity = 1 << 11

    private let lines: UnsafeMutablePointer<Float>
    private let diffusers: UnsafeMutablePointer<Float>
    private var lineWrite = 0
    private var diffuserWrite = 0
    // Fixed-size SIMD storage: no heap / copy-on-write checks on the audio thread.
    private var lengths = SIMD8<Float>(repeating: 1000)
    private var diffuserSizes = SIMD4<Int>(repeating: 100)
    private var damping = SIMD8<Float>(repeating: 0)
    private var sampleRate: Float = 44100
    private var lfoPhase: Float = 0
    private var mixSmoothed: Float = 0
    private var isClear = true

    init() {
        lines = .allocate(capacity: Reverb.lineCount * Reverb.lineCapacity)
        lines.initialize(repeating: 0, count: Reverb.lineCount * Reverb.lineCapacity)
        diffusers = .allocate(capacity: 4 * Reverb.diffuserCapacity)
        diffusers.initialize(repeating: 0, count: 4 * Reverb.diffuserCapacity)
    }

    deinit {
        lines.deallocate()
        diffusers.deallocate()
    }

    /// Not real-time: called from prepare.
    func prepare(sampleRate: Float) {
        self.sampleRate = sampleRate
        // Initialise static tables here, never lazily on the audio thread.
        _ = Reverb.baseLengths.count
        _ = DelayDivision.quarters.count
        let scale = sampleRate / 44100
        for i in 0..<4 {
            diffuserSizes[i] = min(Reverb.diffuserCapacity - 1, Int(Reverb.diffuserLengths[i] * scale))
        }
        isClear = false
        reset()
    }

    func reset() {
        guard !isClear else { return }
        lines.update(repeating: 0, count: Reverb.lineCount * Reverb.lineCapacity)
        diffusers.update(repeating: 0, count: 4 * Reverb.diffuserCapacity)
        damping = SIMD8<Float>(repeating: 0)
        mixSmoothed = 0
        isClear = true
    }

    /// - Parameters:
    ///   - size: 0...1 (room size and decay time 0.3 ... 8 s)
    ///   - damp: 0...1 (bright ... dark)
    func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int,
                 mix: Float, size: Float, damp: Float) {
        if mix < 0.0005 && mixSmoothed < 0.0005 {
            reset()
            return
        }
        isClear = false

        let sr = sampleRate
        let lengthScale = sr / 44100 * (0.55 + 0.75 * size)
        let t60 = 0.3 * powf(26, size)
        let maxLength = Float(Reverb.lineCapacity - 8)
        var gains = SIMD8<Float>(repeating: 0)
        for i in 0..<Reverb.lineCount {
            lengths[i] = min(maxLength, Reverb.baseLengths[i] * lengthScale)
            gains[i] = powf(10, -3 * lengths[i] / (t60 * sr))
        }
        let dampCoef = 1 - expf(-2 * Float.pi * (16000 - damp * 14500) / sr)
        let lfoInc = 0.7 / sr
        let lineCap = Reverb.lineCapacity
        let lineMask = lineCap - 1
        let diffCap = Reverb.diffuserCapacity
        let diffMask = diffCap - 1

        for n in 0..<frames {
            mixSmoothed += (mix - mixSmoothed) * 0.002
            let inL = left[n]
            let inR = right[n]

            // Input diffusion (Schroeder all-passes in series).
            var x = 0.5 * (inL + inR)
            for d in 0..<4 {
                let base = diffusers + d * diffCap
                let delayed = base[(diffuserWrite - diffuserSizes[d]) & diffMask]
                let v = x + 0.6 * delayed
                base[diffuserWrite & diffMask] = v
                x = delayed - 0.6 * v
            }

            // Read the FDN lines (two of them slightly modulated).
            lfoPhase += lfoInc
            if lfoPhase >= 1 { lfoPhase -= 1 }
            let mod = sinf(2 * Float.pi * lfoPhase) * 6
            var y = SIMD8<Float>(repeating: 0)
            for i in 0..<Reverb.lineCount {
                var len = lengths[i]
                if i == 1 { len += mod } else if i == 6 { len -= mod }
                let pos = Float(lineWrite) - len
                let k = Int(floorf(pos))
                let frac = pos - Float(k)
                let base = lines + i * lineCap
                let a = base[k & lineMask]
                let b = base[(k + 1) & lineMask]
                var v = a + (b - a) * frac
                damping[i] += (v - damping[i]) * dampCoef
                v = damping[i]
                y[i] = v
            }

            // Householder feedback matrix: x_i - 2/N * sum(x).
            let sum = (y * gains).sum() * (2 / Float(Reverb.lineCount))
            for i in 0..<Reverb.lineCount {
                let sign: Float = (i & 1) == 0 ? 1 : -1
                let feedback = y[i] * gains[i] - sum
                (lines + i * lineCap)[lineWrite & lineMask] = feedback + x * sign * 0.35
            }
            lineWrite = (lineWrite + 1) & lineMask
            diffuserWrite = (diffuserWrite + 1) & diffMask

            let wetL = 0.4 * (y[0] - y[2] + y[4] - y[6] + 0.5 * y[1])
            let wetR = 0.4 * (y[1] - y[3] + y[5] - y[7] + 0.5 * y[0])
            left[n] = inL + wetL * mixSmoothed
            right[n] = inR + wetR * mixSmoothed
        }
    }
}

/// Note values for tempo-synced delay, in quarter notes.
enum DelayDivision {
    static let names = ["1/32", "1/16T", "1/16", "1/16.", "1/8T", "1/8", "1/8.", "1/4T", "1/4", "1/4.", "1/2", "1/1"]
    static let quarters: [Float] = [0.125, 1.0 / 6, 0.25, 0.375, 1.0 / 3, 0.5, 0.75, 2.0 / 3, 1, 1.5, 2, 4]
}

/// Distortion voiced for 303-style acid lines. A mid/treble pre-emphasis
/// pushes the resonant filter peak into the clipper (the "squelch" gets
/// louder and nastier), the clipper is asymmetric for even harmonics, and a
/// post tone low-pass tames the fizz. MIX blends with the dry signal so the
/// bass weight stays when driving hard.
///
/// Modes: 1 OD (two-stage asymmetric tube overdrive), 2 DIST (soft stage
/// into a hard clipper with a strong mid push, DS-1 style), 3 RAT (high-gain
/// diode fuzz with a touch of rectification for the rasp).
final class AcidDistortion {
    static let modeNames = ["OFF", "OD", "DIST", "RAT"]

    private var sampleRate: Float = 44100
    private var preL: Float = 0, preR: Float = 0          // pre-emphasis low-pass
    private var dcXL: Float = 0, dcYL: Float = 0          // DC blocker after the clipper
    private var dcXR: Float = 0, dcYR: Float = 0
    private var lp1L: Float = 0, lp2L: Float = 0          // post tone (2 × one-pole)
    private var lp1R: Float = 0, lp2R: Float = 0
    private var preCoef: Float = 0
    private var dcCoef: Float = 0.999
    private var gainSmoothed: Float = 1
    private var mixSmoothed: Float = 0

    func prepare(sampleRate: Float) {
        self.sampleRate = sampleRate
        preCoef = 1 - expf(-2 * Float.pi * 280 / sampleRate)
        dcCoef = expf(-2 * Float.pi * 12 / sampleRate)
        reset()
    }

    func reset() {
        preL = 0; preR = 0
        dcXL = 0; dcYL = 0; dcXR = 0; dcYR = 0
        lp1L = 0; lp2L = 0; lp1R = 0; lp2R = 0
        mixSmoothed = 0
    }

    /// - Parameters: drive, tone, level, mix: 0...1.
    func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int,
                 mode: Int, drive: Float, tone: Float, level: Float, mix: Float) {
        let targetMix: Float = mode == 0 ? 0 : mix
        if mode == 0 && mixSmoothed < 0.0001 {
            mixSmoothed = 0
            return
        }
        let m = min(max(mode, 1), 3)
        // +6 ... +54 dB of drive (already gritty at 0); RAT starts hotter.
        let targetGain = powf(10, (6 + drive * 48 + (m == 3 ? 6 : 0)) / 20)
        let emphasis: Float = m == 1 ? 1.0 : (m == 2 ? 2.5 : 1.6)
        // Output: -18 ... +6 dB around the dry synth's level.
        let out = powf(10, (level * 24 - 18) / 20) * (m == 1 ? 0.55 : (m == 2 ? 0.4 : 0.45))
        // Tone: 1 ... 16 kHz, second pole an octave above (keeps the bite).
        let toneHz = min(1000 * powf(16, tone), sampleRate * 0.45)
        let lpCoef = 1 - expf(-2 * Float.pi * toneHz / sampleRate)
        let lpCoef2 = 1 - expf(-2 * Float.pi * min(toneHz * 2, sampleRate * 0.45) / sampleRate)
        let smooth: Float = 0.002

        for n in 0..<frames {
            gainSmoothed += (targetGain - gainSmoothed) * smooth
            mixSmoothed += (targetMix - mixSmoothed) * smooth
            let g = gainSmoothed

            let xl = left[n], xr = right[n]
            preL += (xl - preL) * preCoef
            preR += (xr - preR) * preCoef
            let el = (xl + emphasis * (xl - preL)) * g
            let er = (xr + emphasis * (xr - preR)) * g

            var yl = AcidDistortion.clip(el, mode: m)
            var yr = AcidDistortion.clip(er, mode: m)

            let dl = yl - dcXL + dcCoef * dcYL
            dcXL = yl; dcYL = dl
            let dr = yr - dcXR + dcCoef * dcYR
            dcXR = yr; dcYR = dr

            lp1L += (dl - lp1L) * lpCoef; lp2L += (lp1L - lp2L) * lpCoef2
            lp1R += (dr - lp1R) * lpCoef; lp2R += (lp1R - lp2R) * lpCoef2
            yl = lp2L * out
            yr = lp2R * out

            let w = mixSmoothed
            left[n] = xl + (yl - xl) * w
            right[n] = xr + (yr - xr) * w
        }
    }

    @inline(__always) private static func clip(_ x: Float, mode: Int) -> Float {
        switch mode {
        case 1:
            // Two cascaded asymmetric tube stages.
            let a = tanhf(x + 0.35) - 0.336_375_8
            return tanhf(2.2 * a) * 1.03
        case 2:
            // Soft stage into a hard clipper: square-ish, buzzy.
            let v = tanhf(x) * 1.9
            return min(max(v, -0.8), 0.8) * 1.25
        default:
            // Silicon diodes, unequal halves, plus some full-wave
            // rectification (even harmonics, fuzzy rasp).
            let d = x >= 0 ? 1 - expf(-2.2 * x) : -(1 - expf(1.8 * x)) * 0.8
            return min(max(0.8 * d + 0.35 * abs(d), -1), 1)
        }
    }
}
