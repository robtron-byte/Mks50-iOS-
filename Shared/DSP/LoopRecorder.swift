import Foundation
import os

/// Bar-accurate loop recorder running on the audio thread.
///
/// The main thread prepares buffers and arms the recorder; the audio thread
/// starts on the first note (sample-accurate) or on the next bar line of the
/// beat clock and records until the beat clock has advanced exactly `bars`
/// bars. The length is measured in beats, not samples, so a take stays on
/// the bar grid even while the tempo follows a (slightly jittery) MIDI clock;
/// while the clock is halted the take pauses with it.
///
/// Live looping: with a loop pad as target, the bars are written straight
/// into that pad's buffer as well, and the pad starts playing on the very
/// frame the last bar ends, so the sound goes on without a gap. Notes played
/// by hand keep sounding; a running arpeggiator / sequencer is stopped right
/// on the loop end (`patternStopBeat`), so the loop does not play twice.
///
/// Loop point: whatever sounds past the loop end (delay / reverb / release
/// with TAILS, else only a short de-click overlap) is folded onto the loop
/// start, so the end flows into the start without a click. The overlap ends
/// at the first new note (sample-accurate: that note belongs to the next
/// pass), at silence or at its limit, always with a fade. It is at most half
/// the loop long, so folding it in place never touches the frames the live
/// pad is about to play.
///
/// Thread hand-off: configuration changes are made by the main thread under
/// a lock while the audio thread is not using the buffers; the audio thread
/// only ever uses `trylock`, so it never blocks.
final class LoopRecorder {
    enum State: Int32 {
        case idle, armed, recording, finished
    }

    struct Take {
        /// The loop with the overlap already folded onto its start.
        let left: [Float]
        let right: [Float]
        let sampleRate: Double
        /// Beat-clock position of the first recorded frame.
        let startBeat: Double
        /// Loop pad that already plays this take (live looping), else nil.
        let liveSlot: Int?
    }

    private let lock: UnsafeMutablePointer<os_unfair_lock>

    // Shared state (racy reads are fine for UI polling; transitions use the lock).
    private(set) var state: State = .idle
    private var cancelRequested = false
    /// Main thread asks to end the tail now (stop button during the tail).
    private var endTailRequested = false

    // Configuration, written by main under the lock while the audio side is idle.
    private var left: UnsafeMutablePointer<Float>?
    private var right: UnsafeMutablePointer<Float>?
    private var capacity = 0
    /// Room for the bars (nominal length plus slack for tempo drift).
    private var loopCapacity = 0
    /// Nominal length of the bars at the tempo they were armed with (progress).
    private var nominalFrames = 0
    private var loopBeats: Double = 0
    /// Longest overlap folded onto the loop start.
    private var tailLimit = 0
    /// Without TAILS the overlap only de-clicks the loop point: it fades out
    /// over its whole (short) length.
    private var declickOnly = false
    private var startOnNote = true
    private var sampleRate: Double = 44100
    private var startBeat: Double = 0
    /// Live looping target: pad slot and its buffers (owned by `loops`,
    /// reserved for this take until `takeRecording`).
    private var liveSlot = -1
    private var liveLeft: UnsafeMutablePointer<Float>?
    private var liveRight: UnsafeMutablePointer<Float>?

    /// Player the live take is handed to (set once by the engine).
    weak var loops: LoopPlayer?

    // Audio-thread state (read racily by the UI).
    private var latched = false
    /// Frames of the bars recorded so far; their final count once complete.
    private(set) var loopFrames = 0
    private var loopDone = false
    private var tailFrames = 0
    private var tailDone = false
    /// Peak of the output while armed (last block), to tell whether the
    /// take starts from silence.
    private var armedPeak: Float = 0
    /// The take started from silence: the overlap is added onto the loop
    /// start; else it cross-fades into it (see `foldTail`).
    private var foldAdds = true
    /// Consecutive silent frames in the tail (ends the tail early).
    private var silentTailFrames = 0
    /// Tail output below this peak counts as silence (about -80 dBFS) …
    private static let silenceLevel: Float = 1e-4
    /// … once it stayed there this long.
    private static let silenceSeconds = 0.15
    /// Overlap without TAILS: just enough to cross-fade the loop point.
    private static let declickSeconds = 0.012
    /// Fade at a tail cut by a new note.
    private static let cutFadeFrames = 256
    /// True while the audio thread may touch the buffers.
    private(set) var audioBusy = false
    /// Frame (within the current render call) of the first note started in
    /// it, -1: none. Set by the engine on the audio thread.
    private var noteFrame = -1
    /// Beat at which a live take goes live: the engine stops arp / sequencer
    /// there (audio thread). Infinity: nothing to stop.
    var patternStopBeat: Double = .infinity

    init() {
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        left?.deallocate()
        right?.deallocate()
        lock.deallocate()
    }

    // MARK: Main thread

    /// Arms a take of `bars` bars at `tempo`. With `liveSlot`, that loop pad
    /// takes over the moment the bars are complete. Returns false while busy.
    func arm(bars: Int, tempo: Double, sampleRate: Double, startOnNote: Bool, tailSeconds: Double,
             liveSlot: Int? = nil) -> Bool {
        guard !audioBusy, state == .idle || state == .finished else { return false }
        cleanUpAfterCancel()
        let beats = Double(bars * 4)
        let nominal = Int((beats * 60 / max(tempo, 20) * sampleRate).rounded())
        guard nominal > 0 else { return false }
        // 10 % slack: a followed MIDI clock may run slower than its tempo was.
        let loopRoom = nominal + nominal / 10 + 1024
        let wanted = tailSeconds > 0 ? tailSeconds : LoopRecorder.declickSeconds
        let tail = min(Int(wanted * sampleRate), nominal / 2)
        let total = loopRoom + tail
        var live: (UnsafeMutablePointer<Float>, UnsafeMutablePointer<Float>)?
        if let slot = liveSlot {
            live = loops?.prepareLive(slot, frames: loopRoom, beats: beats)
        }

        os_unfair_lock_lock(lock)
        if total > capacity {
            left?.deallocate()
            right?.deallocate()
            left = .allocate(capacity: total)
            right = .allocate(capacity: total)
            capacity = total
        }
        left?.initialize(repeating: 0, count: total)
        right?.initialize(repeating: 0, count: total)
        loopCapacity = loopRoom
        nominalFrames = nominal
        loopBeats = beats
        tailLimit = tail
        declickOnly = tailSeconds <= 0
        loopFrames = 0
        armedPeak = 0
        loopDone = false
        tailFrames = 0
        tailDone = false
        self.startOnNote = startOnNote
        self.sampleRate = sampleRate
        self.liveSlot = live != nil ? liveSlot ?? -1 : -1
        liveLeft = live?.0
        liveRight = live?.1
        cancelRequested = false
        endTailRequested = false
        state = .armed
        os_unfair_lock_unlock(lock)
        return true
    }

    /// Cancels an armed take or one still recording its bars. In the tail
    /// the loop is already complete (and maybe playing): the tail just ends.
    func cancel() {
        os_unfair_lock_lock(lock)
        if capturingTail {
            endTailRequested = true
        } else {
            if state == .armed || state == .recording { cancelRequested = true }
            if !audioBusy {
                state = .idle
                cancelRequested = false
                releaseCancelledLive()
            }
        }
        os_unfair_lock_unlock(lock)
    }

    /// Main thread, after a cancel: frees the live pad reservation (the pad
    /// keeps what it had). Safe to call any time.
    func cleanUpAfterCancel() {
        os_unfair_lock_lock(lock)
        if state == .idle { releaseCancelledLive() }
        os_unfair_lock_unlock(lock)
    }

    /// Under the lock, main thread, audio side idle.
    private func releaseCancelledLive() {
        if liveSlot >= 0 { loops?.releaseLive(liveSlot, started: false) }
        liveSlot = -1
        liveLeft = nil
        liveRight = nil
    }

    /// Copies a finished take out, releases its live pad and resets to idle.
    func takeRecording() -> Take? {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        guard state == .finished, let l = left, let r = right, loopFrames > 0 else { return nil }
        let take = Take(left: Array(UnsafeBufferPointer(start: l, count: loopFrames)),
                        right: Array(UnsafeBufferPointer(start: r, count: loopFrames)),
                        sampleRate: sampleRate, startBeat: startBeat,
                        liveSlot: liveSlot >= 0 ? liveSlot : nil)
        if liveSlot >= 0 { loops?.releaseLive(liveSlot, started: true) }
        liveSlot = -1
        liveLeft = nil
        liveRight = nil
        state = .idle
        return take
    }

    // MARK: Audio thread

    /// Engine: a note starts at `frame` of the current render call.
    func noteStarted(at frame: Int) {
        if noteFrame < 0 || frame < noteFrame { noteFrame = max(frame, 0) }
    }

    /// - Parameters:
    ///   - beatStart: beat-clock position at the first frame
    ///   - beatsPerFrame: beat-clock speed (0: transport halted, the take pauses)
    func process(left inL: UnsafePointer<Float>, right inR: UnsafePointer<Float>, frames: Int,
                 beatStart: Double, beatsPerFrame bpf: Double) {
        let note = noteFrame
        noteFrame = -1

        if !latched {
            guard state == .armed, os_unfair_lock_trylock(lock) else { return }
            if state == .armed && !cancelRequested {
                latched = true
                audioBusy = true
            }
            os_unfair_lock_unlock(lock)
            if !latched { return }
        }

        if cancelRequested {
            if os_unfair_lock_trylock(lock) {
                // The live pad is released by the main thread (cleanUpAfterCancel).
                state = .idle
                cancelRequested = false
                latched = false
                audioBusy = false
                patternStopBeat = .infinity
                os_unfair_lock_unlock(lock)
            }
            return
        }

        guard let l = left, let r = right else { return }
        var pos = 0
        if state == .armed {
            var peak: Float = 0
            var start = -1
            if startOnNote {
                // Exactly on the first note's frame.
                if note >= 0, note < frames { start = note }
            } else if bpf > 0 {
                // Next bar line (4/4) of the beat clock.
                let nextBar = (beatStart / 4 - 1e-9).rounded(.up) * 4
                let delta = Int(((nextBar - beatStart) / bpf).rounded())
                if delta < frames { start = max(0, delta) }
            }
            guard start >= 0 else {
                for i in 0..<frames { peak = max(peak, abs(inL[i]), abs(inR[i])) }
                armedPeak = peak
                return
            }
            pos = start
            // Sound right before the start (this block and the last one)?
            for i in 0..<pos { peak = max(peak, abs(inL[i]), abs(inR[i])) }
            foldAdds = max(peak, armedPeak) < LoopRecorder.silenceLevel * 10
            if !foldAdds { tailLimit = min(tailLimit, Int(0.02 * sampleRate)) }
            startBeat = beatStart + Double(pos) * bpf
            silentTailFrames = 0
            if liveSlot >= 0 { patternStopBeat = startBeat + loopBeats }
            state = .recording
        }
        guard state == .recording else { return }

        // The bars: until the beat clock reaches their end.
        if !loopDone {
            guard bpf > 0 else { return }               // clock halted: pause
            let endBeat = startBeat + loopBeats
            let here = beatStart + Double(pos) * bpf
            let untilEnd = max(0, Int(((endBeat - here) / bpf - 1e-6).rounded(.up)))
            let n = min(untilEnd, frames - pos, loopCapacity - loopFrames)
            if n > 0 {
                (l + loopFrames).update(from: inL + pos, count: n)
                (r + loopFrames).update(from: inR + pos, count: n)
                if let ll = liveLeft, let lr = liveRight {
                    (ll + loopFrames).update(from: inL + pos, count: n)
                    (lr + loopFrames).update(from: inR + pos, count: n)
                }
                loopFrames += n
                pos += n
            }
            if n >= untilEnd || loopFrames >= loopCapacity {
                // Bars complete: the pad plays on from this very frame, gap-free
                // (its anchor is the end of the bars, same phase as their start).
                loopDone = true
                if liveSlot >= 0 { loops?.startLive(liveSlot, anchor: endBeat, frames: loopFrames) }
            }
        }

        // The overlap past the loop end, up to the next note.
        if loopDone && !tailDone {
            let cutByNote = note >= pos
            let stop = endTailRequested ? pos : (cutByNote ? note : frames)
            let n = min(max(stop - pos, 0), tailLimit - tailFrames)
            if n > 0 {
                (l + loopFrames + tailFrames).update(from: inL + pos, count: n)
                (r + loopFrames + tailFrames).update(from: inR + pos, count: n)
                tailFrames += n
                trackTailSilence(left: inL + pos, right: inR + pos, count: n)
            }
            if endTailRequested || cutByNote {
                endTail(fade: LoopRecorder.cutFadeFrames)
            } else if tailFrames >= tailLimit {
                // Time limit: fade the ringing out over its last third.
                endTail(fade: max(LoopRecorder.cutFadeFrames, tailFrames / 3))
            }
        }

        if tailDone, os_unfair_lock_trylock(lock) {
            foldTail()
            state = .finished
            latched = false
            audioBusy = false
            os_unfair_lock_unlock(lock)
        }
    }

    /// Audio thread: once the tail has stayed silent long enough, it is complete.
    private func trackTailSilence(left: UnsafePointer<Float>, right: UnsafePointer<Float>, count: Int) {
        var peak: Float = 0
        for i in 0..<count { peak = max(peak, abs(left[i]), abs(right[i])) }
        silentTailFrames = peak < LoopRecorder.silenceLevel ? silentTailFrames + count : 0
        if silentTailFrames >= Int(LoopRecorder.silenceSeconds * sampleRate) { endTail(fade: 0) }
    }

    /// Audio thread: the overlap is complete; fades its end (over its whole
    /// length when it only de-clicks the loop point).
    private func endTail(fade: Int) {
        guard !tailDone, let l = left, let r = right else { return }
        tailDone = true
        let base = loopFrames
        let n = declickOnly ? tailFrames : min(fade, tailFrames)
        for i in 0..<n {
            let g = Float(n - i) / Float(n + 1)
            l[base + tailFrames - n + i] *= g
            r[base + tailFrames - n + i] *= g
        }
    }

    /// Audio thread: joins the overlap to the loop start, in the take and in
    /// the live pad's buffer. It is at most half the loop long, and the live
    /// pad is past it by now, so nothing it is about to play changes.
    /// - The take began from silence: the overlap is added, so delay /
    ///   reverb ring on into the next pass.
    /// - Sound was already playing (e.g. a sequence with its reverb): the
    ///   loop start already holds that ringing, so the overlap only
    ///   cross-fades into it over 20 ms (adding it would double it).
    /// Without any overlap (a note right on the loop end) the loop end fades
    /// out briefly instead, so the jump to the start does not click.
    private func foldTail() {
        guard let l = left, let r = right, loopFrames > 0 else { return }
        let tail = min(tailFrames, loopFrames)
        let crossfade = foldAdds ? 0 : min(tail, Int(0.02 * sampleRate))
        for i in 0..<(foldAdds ? tail : crossfade) {
            let tl = l[loopFrames + i], tr = r[loopFrames + i]
            if foldAdds {
                l[i] += tl
                r[i] += tr
            } else {
                let g = Float(i) / Float(crossfade)      // 0: overlap … 1: loop
                l[i] = l[i] * g + tl * (1 - g)
                r[i] = r[i] * g + tr * (1 - g)
            }
            if let ll = liveLeft, let lr = liveRight {
                ll[i] = l[i]
                lr[i] = r[i]
            }
        }
        if tail < 32 {
            let n = min(Int(0.002 * sampleRate), loopFrames / 4)
            for i in 0..<n {
                let g = Float(n - i) / Float(n + 1)
                let k = loopFrames - n + i
                l[k] *= g
                r[k] *= g
                if let ll = liveLeft, let lr = liveRight {
                    ll[k] *= g
                    lr[k] *= g
                }
            }
        }
    }

    /// The bars are complete and the overlap past them is being captured.
    var capturingTail: Bool {
        state == .recording && loopDone && !tailDone
    }

    /// Progress through the recorded bars (0...1); the tail is not included.
    var progress: Double {
        if loopDone { return 1 }
        return nominalFrames > 0 ? min(Double(loopFrames) / Double(nominalFrames), 1) : 0
    }
}
