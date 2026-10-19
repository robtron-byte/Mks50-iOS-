import Foundation

/// Organic stereo delay in the spirit of the Erica Synths Echolocator:
/// 0.5 ms ... 2 s (tempo-syncable), saturating feedback loop with tone
/// low-pass and rumble high-pass, tape/BBD-like movement (slow wow, fast
/// flutter and random drift), a slightly longer right channel for width,
/// and pitch-bending glides when the time is changed. Below about 4 ms the
/// loop turns into a comb / flanger / Karplus-style resonator.
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
    // Movement: wow (slow), flutter (fast), drift (smoothed noise).
    private var wowPhase: Float = 0
    private var flutterPhase: Float = 0.37
    private var drift: Float = 0
    private var driftTarget: Float = 0
    private var driftCounter = 0
    private var noise = XorShift32(seed: 0xEC40_1A70)

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
        highCoef = 1 - expf(-2 * Float.pi * 60 / sampleRate)
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

    /// 4-point Hermite interpolation: clean at very short times and while
    /// the time is modulated.
    @inline(__always) private func read(_ buffer: UnsafeMutablePointer<Float>, _ delay: Float) -> Float {
        let pos = Float(writeIndex) - delay
        let i = Int(floorf(pos))
        let t = pos - Float(i)
        let xm1 = buffer[(i - 1) & mask]
        let x0 = buffer[i & mask]
        let x1 = buffer[(i + 1) & mask]
        let x2 = buffer[(i + 2) & mask]
        let c1 = 0.5 * (x1 - xm1)
        let c2 = xm1 - 2.5 * x0 + 2 * x1 - 0.5 * x2
        let c3 = 0.5 * (x2 - xm1) + 1.5 * (x0 - x1)
        return ((c3 * t + c2) * t + c1) * t + x0
    }

    /// Cheap sine for the movement LFOs (phase 0..<1).
    @inline(__always) private static func sine(_ phase: Float) -> Float {
        let x = phase < 0.5 ? phase * 4 - 1 : 3 - phase * 4      // triangle -1...1
        return x * (1.5 - 0.5 * x * x)                           // soft-shaped
    }

    /// - Parameters:
    ///   - seconds: delay time (0.0005 ... about 5)
    ///   - feedback: 0...1.15; above 1 the loop self-oscillates (dub
    ///     style) and is held by the soft clipper in the feedback path
    ///   - tone: 0...1 (dark ... bright)
    ///   - modulation: 0...1 wow / flutter / drift depth
    func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int,
                 mix: Float, seconds: Float, feedback: Float, tone: Float, pingPong: Bool,
                 modulation: Float) {
        // Fully off: no work at all; the buffer is cleared once so old echoes
        // never reappear when the delay is switched on again.
        if mix < 0.0005 && mixSmoothed < 0.0005 {
            reset()
            return
        }
        isClear = false

        // Upper bound leaves room for the right channel's +1.2 % and the
        // modulation offset (2 s still fits at 96 kHz).
        let target = clampf(seconds * sampleRate, 2, Float(size) * 0.95)
        if delaySmoothed == 0 { delaySmoothed = target }
        let lowCoef = 1 - expf(-2 * Float.pi * (900 + tone * tone * 15000) / sampleRate)
        let fb = clampf(feedback, 0, 1.15)
        let m = clampf(modulation, 0, 1)
        let wowInc = 0.55 / sampleRate
        let flutterInc = 6.3 / sampleRate
        // Relative depth (pitch wobble on long echoes) plus a small absolute
        // depth in samples so very short delays flange / chorus.
        let relDepth = m * m * 0.004
        let absDepth = m * 0.0006 * sampleRate
        // Saturation grows with feedback: repeats get warmer, not louder.
        let drive: Float = 1.1 + 0.4 * fb

        for n in 0..<frames {
            // Time changes glide (repitching like tape / BBD).
            delaySmoothed += (target - delaySmoothed) * 0.0004
            mixSmoothed += (mix - mixSmoothed) * 0.002

            wowPhase += wowInc
            if wowPhase >= 1 { wowPhase -= 1 }
            flutterPhase += flutterInc
            if flutterPhase >= 1 { flutterPhase -= 1 }
            driftCounter -= 1
            if driftCounter <= 0 {
                driftCounter = 2048
                driftTarget = noise.next()
            }
            drift += (driftTarget - drift) * 0.0003

            let movement = 0.7 * StereoDelay.sine(wowPhase) + 0.12 * StereoDelay.sine(flutterPhase) + 0.5 * drift
            let offset = movement * (delaySmoothed * relDepth + absDepth)
            let dL = max(2, delaySmoothed + offset)
            // Right side a little longer (and moving the other way) for width.
            let dR = max(2, delaySmoothed * 1.012 - offset)

            let inL = left[n]
            let inR = right[n]
            var wetL = read(bufferL, dL)
            var wetR = read(bufferR, dR)

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
            // Warm saturation; bounds a runaway loop at about ±0.8.
            bufferL[writeIndex] = softClip(writeL * drive) * (0.8 / drive * 1.25)
            bufferR[writeIndex] = softClip(writeR * drive) * (0.8 / drive * 1.25)
            writeIndex = (writeIndex + 1) & mask

            left[n] = inL + wetL * mixSmoothed
            right[n] = inR + wetR * mixSmoothed
        }
    }
}

/// Large modulated stereo reverb in the spirit of the Eventide Black Hole,
/// that also does short rooms: input pre-delay, 4 diffusers and an 8-line
/// feedback delay network with a Householder matrix (O(N) mixing). SIZE sets
/// the space (small room ... huge hall, with pre-delay), DECAY the time
/// (0.15 s ... 60 s), every line is slowly modulated (MOD) for the lush,
/// chorused tail, DAMP darkens it.
final class Reverb {
    private static let lineCount = 8
    private static let lineCapacity = 1 << 15
    private static let baseLengths: [Float] = [1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617] // @44.1k
    private static let diffuserLengths: [Float] = [142, 107, 379, 277]
    private static let diffuserCapacity = 1 << 12
    private static let preDelayCapacity = 1 << 13

    /// DECAY 0...127 → RT60 in seconds (0.15 ... 60).
    static func decaySeconds(_ raw: Float) -> Float {
        0.15 * powf(400, min(max(raw, 0), 127) / 127)
    }

    private let lines: UnsafeMutablePointer<Float>
    private let diffusers: UnsafeMutablePointer<Float>
    private let preDelay: UnsafeMutablePointer<Float>
    private var lineWrite = 0
    private var diffuserWrite = 0
    private var preWrite = 0
    // Fixed-size SIMD storage: no heap / copy-on-write checks on the audio thread.
    private var lengths = SIMD8<Float>(repeating: 1000)
    private var diffuserSizes = SIMD4<Int>(repeating: 100)
    private var damping = SIMD8<Float>(repeating: 0)
    private var lfoPhases = SIMD8<Float>(0.0, 0.13, 0.29, 0.41, 0.57, 0.66, 0.78, 0.9)
    private var lfoIncrements = SIMD8<Float>(repeating: 0)
    private var sampleRate: Float = 44100
    private var mixSmoothed: Float = 0
    private var sizeSmoothed: Float = -1
    private var isClear = true

    init() {
        lines = .allocate(capacity: Reverb.lineCount * Reverb.lineCapacity)
        lines.initialize(repeating: 0, count: Reverb.lineCount * Reverb.lineCapacity)
        diffusers = .allocate(capacity: 4 * Reverb.diffuserCapacity)
        diffusers.initialize(repeating: 0, count: 4 * Reverb.diffuserCapacity)
        preDelay = .allocate(capacity: Reverb.preDelayCapacity)
        preDelay.initialize(repeating: 0, count: Reverb.preDelayCapacity)
    }

    deinit {
        lines.deallocate()
        diffusers.deallocate()
        preDelay.deallocate()
    }

    /// Not real-time: called from prepare.
    func prepare(sampleRate: Float) {
        self.sampleRate = sampleRate
        // Initialise static tables here, never lazily on the audio thread.
        _ = Reverb.baseLengths.count + Reverb.diffuserLengths.count
        _ = DelayDivision.quarters.count
        // Slow, unrelated LFO rates (0.23 ... 0.97 Hz).
        let rates: [Float] = [0.23, 0.31, 0.37, 0.47, 0.53, 0.67, 0.79, 0.97]
        for i in 0..<Reverb.lineCount { lfoIncrements[i] = rates[i] / sampleRate }
        isClear = false
        reset()
    }

    func reset() {
        guard !isClear else { return }
        lines.update(repeating: 0, count: Reverb.lineCount * Reverb.lineCapacity)
        diffusers.update(repeating: 0, count: 4 * Reverb.diffuserCapacity)
        preDelay.update(repeating: 0, count: Reverb.preDelayCapacity)
        damping = SIMD8<Float>(repeating: 0)
        mixSmoothed = 0
        isClear = true
    }

    /// - Parameters:
    ///   - size: 0...1 (small room ... huge space; also pre-delay 0 ... 60 ms)
    ///   - decay: DECAY parameter 0...127 (RT60 0.15 ... 60 s)
    ///   - damp: 0...1 (bright ... dark)
    ///   - modulation: 0...1
    func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int,
                 mix: Float, size: Float, decay: Float, damp: Float, modulation: Float) {
        if mix < 0.0005 && mixSmoothed < 0.0005 {
            reset()
            return
        }
        isClear = false

        let sr = sampleRate
        // Size changes are smoothed per block (no zipper on the line lengths).
        if sizeSmoothed < 0 { sizeSmoothed = size }
        sizeSmoothed += (size - sizeSmoothed) * min(1, Float(frames) / (0.05 * sr))
        let sz = sizeSmoothed
        let lengthScale = sr / 44100 * (0.18 + 2.6 * sz * sz)
        let t60 = Reverb.decaySeconds(decay)
        let maxLength = Float(Reverb.lineCapacity - 64)
        var gains = SIMD8<Float>(repeating: 0)
        for i in 0..<Reverb.lineCount {
            lengths[i] = min(maxLength, Reverb.baseLengths[i] * lengthScale)
            gains[i] = powf(10, -3 * lengths[i] / (t60 * sr))
        }
        let diffScale = sr / 44100 * (0.35 + 1.4 * sz)
        for i in 0..<4 {
            diffuserSizes[i] = max(1, min(Reverb.diffuserCapacity - 1, Int(Reverb.diffuserLengths[i] * diffScale)))
        }
        // Denser, smoother build-up in big spaces.
        let diffusion: Float = 0.55 + 0.17 * sz
        let preSamples = min(Reverb.preDelayCapacity - 1, max(1, Int(sz * sz * 0.06 * sr)))
        let dampCoef = 1 - expf(-2 * Float.pi * (16000 - damp * 14500) / sr)
        let modDepth = modulation * (1.5 + 14 * sz) * sr / 44100
        let lineCap = Reverb.lineCapacity
        let lineMask = lineCap - 1
        let diffCap = Reverb.diffuserCapacity
        let diffMask = diffCap - 1
        let preMask = Reverb.preDelayCapacity - 1

        for n in 0..<frames {
            mixSmoothed += (mix - mixSmoothed) * 0.002
            let inL = left[n]
            let inR = right[n]

            // Pre-delay.
            preDelay[preWrite] = 0.5 * (inL + inR)
            var x = preDelay[(preWrite - preSamples) & preMask]
            preWrite = (preWrite + 1) & preMask

            // Input diffusion (Schroeder all-passes in series).
            for d in 0..<4 {
                let base = diffusers + d * diffCap
                let delayed = base[(diffuserWrite - diffuserSizes[d]) & diffMask]
                let v = x + diffusion * delayed
                base[diffuserWrite & diffMask] = v
                x = delayed - diffusion * v
            }

            // Every line slowly modulated (triangle LFOs, cheap).
            lfoPhases += lfoIncrements
            for i in 0..<Reverb.lineCount where lfoPhases[i] >= 1 { lfoPhases[i] -= 1 }
            var y = SIMD8<Float>(repeating: 0)
            for i in 0..<Reverb.lineCount {
                let p = lfoPhases[i]
                let tri = p < 0.5 ? 4 * p - 1 : 3 - 4 * p
                let pos = Float(lineWrite) - (lengths[i] + modDepth * tri)
                let k = Int(floorf(pos))
                let frac = pos - Float(k)
                let base = lines + i * lineCap
                let a = base[k & lineMask]
                let b = base[(k + 1) & lineMask]
                let v = a + (b - a) * frac
                damping[i] += (v - damping[i]) * dampCoef
                y[i] = damping[i]
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

/// Distortion for synth basses, acid lines and leads, before chorus /
/// delay / reverb. The clipper runs at 2× oversampling (47-tap half-band
/// FIR up and down, about −70 dB image rejection), so even hard settings
/// stay free of the gritty "digital" aliasing; the dry path is delayed by
/// the same 24 samples so MIX never combs.
///
/// Signal per channel: tightening high-pass (keeps the low end clean in
/// front of the clipper) → mid/treble pre-emphasis → drive → clipper →
/// DC blocker → 2-pole tone low-pass → level, then MIX with the dry signal.
///
/// Modes: 1 OD (two-stage asymmetric tube overdrive), 2 DIST (soft stage
/// into a smooth-knee hard clipper with a strong mid push, DS-1 style),
/// 3 RAT (op-amp gain into silicon diodes, a touch of rectification for
/// the rasp), 4 TUBE (warm, even-harmonic tube saturation with soft
/// compression, after the SPL Kultube that Anthony Rother lists on his
/// master output in the DEKATRON production notes — he names no
/// distortion plugin there; gentle at low drive, thick at high drive).
final class AcidDistortion {
    static let modeNames = ["OFF", "OD", "DIST", "RAT", "TUBE"]

    /// Half-band taps at odd offsets 1, 3, 5 ... from the centre (0.5).
    private static let halfBand: [Float] = [
        0.3163647824, -0.1003918960, 0.0545327660, -0.0334618158, 0.0211372679, -0.0132048055,
        0.0079527640, -0.0045132248, 0.0023474055, -0.0010708521, 0.0003905110, -0.0000820879]
    private static let latency = 24

    private var sampleRate: Float = 44100
    private var preL: Float = 0, preR: Float = 0          // pre-emphasis low-pass
    private var tightL: Float = 0, tightR: Float = 0      // tightening high-pass state
    private var dcXL: Float = 0, dcYL: Float = 0          // DC blocker after the clipper
    private var dcXR: Float = 0, dcYR: Float = 0
    private var lp1L: Float = 0, lp2L: Float = 0          // post tone (2 × one-pole)
    private var lp1R: Float = 0, lp2R: Float = 0
    private var preCoef: Float = 0
    private var dcCoef: Float = 0.999
    private var gainSmoothed: Float = 1
    private var mixSmoothed: Float = 0

    // Oversampling rings (per channel): base-rate input history (32),
    // oversampled clipper output (64), dry delay (32).
    private let inHist: UnsafeMutablePointer<Float>       // L: 0..<32, R: 32..<64
    private let osHist: UnsafeMutablePointer<Float>       // L: 0..<64, R: 64..<128
    private let dryHist: UnsafeMutablePointer<Float>      // L: 0..<32, R: 32..<64
    private var inPos = 0
    private var osPos = 0
    private var taps = SIMD16<Float>(repeating: 0)

    init() {
        inHist = .allocate(capacity: 64)
        osHist = .allocate(capacity: 128)
        dryHist = .allocate(capacity: 64)
        inHist.initialize(repeating: 0, count: 64)
        osHist.initialize(repeating: 0, count: 128)
        dryHist.initialize(repeating: 0, count: 64)
        for k in 0..<12 { taps[k] = AcidDistortion.halfBand[k] }
    }

    deinit {
        inHist.deallocate()
        osHist.deallocate()
        dryHist.deallocate()
    }

    func prepare(sampleRate: Float) {
        self.sampleRate = sampleRate
        preCoef = 1 - expf(-2 * Float.pi * 280 / sampleRate)
        dcCoef = expf(-2 * Float.pi * 12 / sampleRate)
        reset()
    }

    func reset() {
        preL = 0; preR = 0; tightL = 0; tightR = 0
        dcXL = 0; dcYL = 0; dcXR = 0; dcYR = 0
        lp1L = 0; lp2L = 0; lp1R = 0; lp2R = 0
        mixSmoothed = 0
        inHist.update(repeating: 0, count: 64)
        osHist.update(repeating: 0, count: 128)
        dryHist.update(repeating: 0, count: 64)
    }

    /// 2× oversampled clipping of one channel sample (`ch` 0 = L, 1 = R).
    @inline(__always) private func oversampledClip(_ x: Float, ch: Int, mode: Int) -> Float {
        let ib = inHist + ch * 32
        ib[inPos] = x
        let ip = inPos
        func h(_ j: Int) -> Float { ib[(ip - j) & 31] }
        // Interpolate: even phase = x[m-12], odd phase = half-band midpoint.
        let even = h(12)
        var odd: Float = 0
        for k in 0..<12 { odd += taps[k] * (h(12 + k) + h(11 - k)) }
        odd *= 2

        let ob = osHist + ch * 64
        ob[osPos] = AcidDistortion.clip(even, mode: mode)
        ob[(osPos + 1) & 63] = AcidDistortion.clip(odd, mode: mode)
        let newest = (osPos + 1) & 63
        func v(_ j: Int) -> Float { ob[(newest - j) & 63] }
        // Decimate around the odd-offset centre (integer 24-sample latency).
        var y = 0.5 * v(25)
        for k in 0..<12 { y += taps[k] * (v(25 - (2 * k + 1)) + v(25 + (2 * k + 1))) }
        return y
    }

    /// - Parameters: drive, tone, level, mix: 0...1.
    func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int,
                 mode: Int, drive: Float, tone: Float, level: Float, mix: Float) {
        let targetMix: Float = mode == 0 ? 0 : mix
        if mode == 0 && mixSmoothed < 0.0001 {
            mixSmoothed = 0
            return
        }
        let m = min(max(mode, 1), 4)
        // Per mode: drive range, pre-emphasis, tightening high-pass, makeup.
        // (Plain switch: no array literals on the audio thread.)
        let driveDB: Float, emphasis: Float, tightHz: Float, makeup: Float
        switch m {
        case 1: driveDB = 6 + drive * 48; emphasis = 1.0; tightHz = 45; makeup = 0.55
        case 2: driveDB = 6 + drive * 48; emphasis = 2.5; tightHz = 110; makeup = 0.4
        case 3: driveDB = 12 + drive * 48; emphasis = 1.6; tightHz = 90; makeup = 0.45
        default: driveDB = drive * 30; emphasis = 0.3; tightHz = 18; makeup = 0.85
        }
        let targetGain = powf(10, driveDB / 20)
        let tightCoef = 1 - expf(-2 * Float.pi * tightHz / sampleRate)
        let out = powf(10, (level * 24 - 18) / 20) * makeup
        // Tone: 1 ... 16 kHz, second pole an octave above (keeps the bite).
        let toneHz = min(1000 * powf(16, tone), sampleRate * 0.45)
        let lpCoef = 1 - expf(-2 * Float.pi * toneHz / sampleRate)
        let lpCoef2 = 1 - expf(-2 * Float.pi * min(toneHz * 2, sampleRate * 0.45) / sampleRate)
        let smooth: Float = 0.002
        let lat = AcidDistortion.latency

        for n in 0..<frames {
            gainSmoothed += (targetGain - gainSmoothed) * smooth
            mixSmoothed += (targetMix - mixSmoothed) * smooth
            let g = gainSmoothed

            let xl = left[n], xr = right[n]
            // Dry path delayed by the oversampler latency.
            dryHist[inPos] = xl
            dryHist[32 + inPos] = xr
            let dryL = dryHist[(inPos - lat) & 31]
            let dryR = dryHist[32 + ((inPos - lat) & 31)]

            // Tightening high-pass, then pre-emphasis and drive.
            tightL += (xl - tightL) * tightCoef
            tightR += (xr - tightR) * tightCoef
            let hl = xl - tightL
            let hr = xr - tightR
            preL += (hl - preL) * preCoef
            preR += (hr - preR) * preCoef
            let el = (hl + emphasis * (hl - preL)) * g
            let er = (hr + emphasis * (hr - preR)) * g

            var yl = oversampledClip(el, ch: 0, mode: m)
            var yr = oversampledClip(er, ch: 1, mode: m)
            inPos = (inPos + 1) & 31
            osPos = (osPos + 2) & 63

            let dl = yl - dcXL + dcCoef * dcYL
            dcXL = yl; dcYL = dl
            let dr = yr - dcXR + dcCoef * dcYR
            dcXR = yr; dcYR = dr

            lp1L += (dl - lp1L) * lpCoef; lp2L += (lp1L - lp2L) * lpCoef2
            lp1R += (dr - lp1R) * lpCoef; lp2R += (lp1R - lp2R) * lpCoef2
            yl = lp2L * out
            yr = lp2R * out

            let w = mixSmoothed
            left[n] = dryL + (yl - dryL) * w
            right[n] = dryR + (yr - dryR) * w
        }
    }

    @inline(__always) private static func clip(_ x: Float, mode: Int) -> Float {
        switch mode {
        case 1:
            // Two cascaded asymmetric tube stages.
            let a = tanhf(x + 0.35) - 0.336_375_8
            return tanhf(2.2 * a) * 1.03
        case 2:
            // Soft stage into a smooth-knee hard clipper (p = 6): square-ish,
            // buzzy, but without the infinite-harmonic corner.
            let v = tanhf(x) * 1.9
            let a = abs(v) / 0.8
            let a6 = a * a * a
            return v / powf(1 + a6 * a6, 1 / 6) * 1.25
        case 4:
            // Tube: triode-like asymmetry (the negative half compresses
            // earlier -> 2nd harmonic), soft knee, no hard ceiling.
            let b: Float = 0.2
            let u = x + b
            let t = u >= 0 ? tanhf(u * 0.9) / 0.9 : tanhf(u * 1.35) / 1.35
            return (t - tanhf(b * 0.9) / 0.9) * 1.15
        default:
            // Silicon diodes, unequal halves, plus some full-wave
            // rectification (even harmonics, fuzzy rasp).
            let d = x >= 0 ? 1 - expf(-2.2 * x) : -(1 - expf(1.8 * x)) * 0.8
            return min(max(0.8 * d + 0.35 * abs(d), -1), 1)
        }
    }
}
