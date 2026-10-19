import Foundation

/// A waveform built the way the Alpha Juno's MB87123 DCO builds them: an
/// 8-bit ramp counter whose output is AND-ed ("chopped") with counter bits,
/// i.e. square gates at power-of-two multiples of the base frequency.
///
/// A gate is open while its local phase is at or above its threshold `w`
/// (a counter bit is high in the upper half of its period, the PWM gate
/// while the low counter bits are >= PW), so all shapes keep the hardware's
/// phase relation between ramp, pulse and sub.
/// Multipliers are relative to the phase the shape is evaluated with.
/// Every discontinuity is band-limited with a PolyBLEP whose height is
/// measured directly on the naive waveform, so arbitrary chop combinations
/// stay alias-reduced.
struct ChopShape {
    /// Ramp multiplier; 0 = no ramp (constant 1 → pure gate product).
    var ramp: Float = 0
    var m0: Float = 0, w0: Float = 0.5
    var m1: Float = 0, w1: Float = 0.5
    var m2: Float = 0, w2: Float = 0.5

    var isEnabled: Bool { ramp > 0 || m0 > 0 }

    static let off = ChopShape()

    static func gate(_ m: Float, _ w: Float = 0.5) -> ChopShape {
        ChopShape(ramp: 0, m0: m, w0: w)
    }

    /// Unipolar naive value 0...1.
    @inline(__always) func naive(_ p: Float) -> Float {
        if m0 > 0 && wrap01(p * m0) < w0 { return 0 }
        if m1 > 0 && wrap01(p * m1) < w1 { return 0 }
        if m2 > 0 && wrap01(p * m2) < w2 { return 0 }
        return ramp > 0 ? wrap01(p * ramp) : 1
    }

    /// Bipolar band-limited output.
    ///
    /// Fast path: local phases are computed once and reused both for the
    /// naive value and for edge detection; no rounding, and the full naive
    /// evaluation for step heights only runs within one sample of an edge.
    @inline(__always) func render(_ p: Float, _ dt: Float) -> Float {
        let l0: Float = m0 > 0 ? wrap01(p * m0) : 0
        let l1: Float = m1 > 0 ? wrap01(p * m1) : 0
        let l2: Float = m2 > 0 ? wrap01(p * m2) : 0
        let lr: Float = ramp > 0 ? wrap01(p * ramp) : 0

        let isOpen = (m0 <= 0 || l0 >= w0) && (m1 <= 0 || l1 >= w1) && (m2 <= 0 || l2 >= w2)
        var out: Float = isOpen ? 2 * (ramp > 0 ? lr : 1) - 1 : -1

        var seen = SIMD8<Float>(repeating: 9)
        var seenCount = 0

        // 7 edge families: ramp reset, and rise / fall of each gate.
        for c in 0..<7 {
            let m: Float
            let local: Float
            let offset: Float
            switch c {
            case 0: m = ramp; local = lr; offset = 0
            case 1: m = m0; local = l0; offset = 0
            case 2: m = m0; local = l0; offset = w0
            case 3: m = m1; local = l1; offset = 0
            case 4: m = m1; local = l1; offset = w1
            case 5: m = m2; local = l2; offset = 0
            default: m = m2; local = l2; offset = w2
            }
            if m <= 0 { continue }

            // Signed distance (in units of p) to the nearest edge of this family.
            var x = local - offset            // -1 < x < 1
            if x < -0.5 { x += 1 } else if x >= 0.5 { x -= 1 }
            let d = x / m
            if d >= dt || d <= -dt { continue }

            let edge = p - d
            var duplicate = false
            for j in 0..<seenCount where abs(seen[j] - edge) < 1e-5 { duplicate = true }
            if duplicate { continue }
            seen[seenCount] = edge
            seenCount += 1

            let h = naive(wrap01(edge + 1e-5)) - naive(wrap01(edge - 1e-5))
            if h != 0 { out += h * polyBlep(wrap01(d), dt) }
        }
        return out
    }
}

/// Per-block oscillator settings derived from the tone parameters.
struct DCOSettings {
    /// Pulse shape, evaluated on the pulse phase (1 = main frequency).
    var pulse = ChopShape.off
    /// Saw and sub shapes, evaluated on the master phase (4 = main frequency).
    var saw = ChopShape(ramp: 4)
    var sub = ChopShape.off
    var subLevel: Float = 0
    var noiseLevel: Float = 0

    /// Builds the MKS-50 waveforms from their panel numbers, following the
    /// MB87123 counter-bit model (ErroneousBosh's alphaOsc analysis, matching
    /// the june-21 emulator): bit 7 = main square, bit 6 = +1 oct, bit 5 =
    /// +2 oct, bit 4 = +3 oct, bits 8 / 9 = sub -1 / -2 oct; the PWM gate is
    /// "low 7 counter bits >= PW", i.e. a +1 oct pulse with threshold `pw`.
    /// Only Pulse 3 and Saw 3 follow PW / PWM.
    ///
    /// - Parameter pw: PWM threshold 0 ... <1 (PW value / 128).
    mutating func configure(pulse: Int, saw: Int, sub: Int, pw: Float) {
        // Pulse phase: main = 1, +1 oct = 2.
        switch pulse {
        case 1: self.pulse = .gate(1)                                            // square (bit 7)
        case 2: self.pulse = ChopShape(ramp: 0, m0: 1, w0: 0.5, m1: 2)           // 25 % (bit 7 · bit 6)
        case 3: self.pulse = ChopShape(ramp: 0, m0: 1, w0: 0.5, m1: 2, w1: pw)   // PWM, 50 % → 0 %
        default: self.pulse = .off
        }
        // Master phase units: -2 oct = 1, -1 oct = 2, main = 4, +1 oct = 8,
        // +2 oct = 16, +3 oct = 32.
        switch saw {
        case 1: self.saw = ChopShape(ramp: 4)                                    // ramp
        case 2: self.saw = ChopShape(ramp: 4, m0: 8)                             // ramp · bit 6
        case 3: self.saw = ChopShape(ramp: 4, m0: 8, w0: pw)                     // ramp · PWM gate
        case 4: self.saw = ChopShape(ramp: 4, m0: 32)                            // ramp · bit 4
        case 5: self.saw = ChopShape(ramp: 4, m0: 8, w0: 0.5, m1: 32)            // ramp · bit 6 · bit 4
        default: self.saw = .off
        }
        switch sub {
        case 1: self.sub = ChopShape(ramp: 0, m0: 2, w0: 0.5, m1: 4)             // bit 8 · bit 7 (25 %)
        case 2: self.sub = ChopShape(ramp: 0, m0: 2, w0: 0.5, m1: 8)             // bit 8 · bit 6
        case 3: self.sub = ChopShape(ramp: 0, m0: 2, w0: 0.5, m1: 16)            // bit 8 · bit 5
        case 4: self.sub = .gate(1)                                              // bit 9 (-2 oct)
        case 5: self.sub = ChopShape(ramp: 0, m0: 1, w0: 0.5, m1: 2)             // bit 9 · bit 8 (25 %)
        default: self.sub = .gate(2)                                             // bit 8 (-1 oct)
        }
    }
}

/// Alpha Juno / MKS-50 style DCO plus the TAL-Pha style pulse extensions
/// (pulse detune, pulse hard sync).
///
/// One master phase runs at f/4 so the main wave, the chop gates and the
/// sub octaves are phase-locked like the hardware's divider chain. The pulse
/// part has its own phase that can be detuned and synced to the main cycle.
struct DCO {
    var phase: Float = 0
    var pulsePhase: Float = 0
    private var lastMainPhase: Float = 0
    var noise: XorShift32

    init(seed: UInt32) {
        noise = XorShift32(seed: seed)
    }

    mutating func reset() {
        phase = 0
        pulsePhase = 0
        lastMainPhase = 0
    }

    /// - Parameters:
    ///   - dt: phase increment of the main (8') waveform in cycles/sample
    ///   - pulseRatio: frequency ratio of the pulse part (1 = locked)
    ///   - sync: hard-sync the pulse part to the main cycle
    @inline(__always) mutating func tick(dt rawDt: Float, pulseRatio: Float, sync: Bool, _ s: DCOSettings) -> Float {
        let dt = min(rawDt, 0.45)
        let dtMaster = dt * 0.25
        phase += dtMaster
        if phase >= 1 { phase -= 1 }

        let main = wrap01(phase * 4)
        let mainWrapped = main < lastMainPhase
        lastMainPhase = main

        var out: Float = 0

        if s.pulse.isEnabled {
            if pulseRatio == 1 && !sync {
                pulsePhase = main
                out += s.pulse.render(main, dt)
            } else {
                let pdt = min(dt * pulseRatio, 0.45)
                if sync && mainWrapped {
                    // Reset at the exact sub-sample position of the main wrap.
                    let since = main / max(dt, 1e-9)
                    let before = wrap01(pulsePhase + pdt * (1 - since))
                    pulsePhase = wrap01(pdt * since)
                    // Band-limit the sync jump itself; the shape's own edges
                    // are not evaluated in this one sample.
                    let h = s.pulse.naive(0) - s.pulse.naive(before)
                    out += 2 * s.pulse.naive(pulsePhase) - 1 + h * polyBlep(main, dt)
                } else {
                    pulsePhase += pdt
                    if pulsePhase >= 1 { pulsePhase -= floorf(pulsePhase) }
                    out += s.pulse.render(pulsePhase, pdt)
                }
            }
        }

        if s.saw.isEnabled {
            out += s.saw.render(phase, dtMaster)
        }

        if s.subLevel > 0 {
            out += s.sub.render(phase, dtMaster) * s.subLevel
        }

        if s.noiseLevel > 0 {
            out += noise.next() * s.noiseLevel
        }
        return out
    }
}
