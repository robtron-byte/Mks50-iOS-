import Foundation
import os

/// Bar-accurate loop recorder running on the audio thread.
///
/// The main thread prepares buffers and arms the recorder; the audio thread
/// starts on the first note (or on the next bar of the beat clock) and
/// records exactly `bars` bars.
///
/// Live looping: with a loop pad as target, the bars are written straight
/// into that pad's buffer as well, and the pad starts playing on the very
/// frame the last bar ends, so the sound goes on without a gap. Playing
/// never stops: notes keep sounding and new ones can be played over the
/// loop at once.
///
/// Tail: after the bars the recorder keeps listening for up to
/// `tailSeconds` so delay / reverb / release ringing past the loop end can
/// be folded onto the loop start (seamless repeats). The tail ends as soon
/// as the output has died away or a new note is played (that note belongs
/// to the next pass, not to the loop); the fold is then done in place, in
/// the take and in the pad's buffer.
///
/// Thread hand-off: configuration changes are made by the main thread under
/// a lock while the audio thread is not using the buffers; the audio thread
/// only ever uses `trylock`, so it never blocks.
final class LoopRecorder {
    enum State: Int32 {
        case idle, armed, recording, finished
    }

    struct Take {
        /// The loop with the tail already folded onto its start.
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
    private(set) var framesWritten = 0
    private(set) var totalFrames = 0
    private var cancelRequested = false
    /// Main thread asks to end the tail now (stop button during the tail).
    private var endTailRequested = false

    // Configuration, written by main under the lock while the audio side is idle.
    private var left: UnsafeMutablePointer<Float>?
    private var right: UnsafeMutablePointer<Float>?
    private var capacity = 0
    private var loopFrames = 0
    private var loopBeats: Double = 0
    private var tailFrames = 0
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

    // Audio-thread private.
    private var latched = false
    /// Consecutive silent frames in the tail (ends the tail early).
    private var silentTailFrames = 0
    /// Tail output below this peak counts as silence (about -80 dBFS) …
    private static let silenceLevel: Float = 1e-4
    /// … once it stayed there this long.
    private static let silenceSeconds = 0.15
    /// Fade at a tail cut (new note / time limit), so the fold has no click.
    private static let cutFadeFrames = 256
    /// True while the audio thread may touch the buffers.
    private(set) var audioBusy = false
    /// Set by the engine (audio thread) when a note starts.
    var noteTrigger = false

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
        let loop = Int((beats * 60 / max(tempo, 20) * sampleRate).rounded())
        let tail = Int(tailSeconds * sampleRate)
        let total = loop + tail
        guard loop > 0 else { return false }
        var live: (UnsafeMutablePointer<Float>, UnsafeMutablePointer<Float>)?
        if let slot = liveSlot {
            live = loops?.prepareLive(slot, frames: loop, beats: beats)
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
        loopFrames = loop
        loopBeats = beats
        tailFrames = tail
        totalFrames = total
        framesWritten = 0
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
        guard state == .finished, let l = left, let r = right else { return nil }
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

    /// - Parameters:
    ///   - beatStart: beat-clock position at the first frame
    ///   - beatsPerFrame: beat-clock speed
    func process(left inL: UnsafePointer<Float>, right inR: UnsafePointer<Float>, frames: Int,
                 beatStart: Double, beatsPerFrame: Double) {
        if !latched {
            // Keep a note that started in this very buffer: it may be the
            // one that should start an armed take (don't clear it before latching).
            guard state == .armed, os_unfair_lock_trylock(lock) else { noteTrigger = false; return }
            if state == .armed && !cancelRequested {
                latched = true
                audioBusy = true
            }
            os_unfair_lock_unlock(lock)
            if !latched { noteTrigger = false; return }
        }

        if cancelRequested {
            if os_unfair_lock_trylock(lock) {
                // The live pad is released by the main thread (cleanUpAfterCancel).
                state = .idle
                cancelRequested = false
                latched = false
                audioBusy = false
                os_unfair_lock_unlock(lock)
            }
            return
        }

        var offset = 0
        if state == .armed {
            if startOnNote {
                guard noteTrigger else { return }
                offset = 0
            } else {
                // Next bar line (4/4) of the beat clock.
                let barBeats = 4.0
                let nextBar = (beatStart / barBeats - 1e-9).rounded(.up) * barBeats
                let delta = Int(((nextBar - beatStart) / max(beatsPerFrame, 1e-12)).rounded())
                guard delta < frames else { return }
                offset = max(0, delta)
            }
            noteTrigger = false
            startBeat = beatStart + Double(offset) * beatsPerFrame
            silentTailFrames = 0
            state = .recording
        }

        guard state == .recording, let l = left, let r = right else { return }

        // In the tail: a new note (or the stop button) ends it before this block.
        if framesWritten >= loopFrames && framesWritten < totalFrames && (noteTrigger || endTailRequested) {
            endTail(cut: true)
        }

        let remaining = totalFrames - framesWritten
        if remaining > 0 {
            let count = min(remaining, frames - offset)
            if count > 0 {
                (l + framesWritten).update(from: inL + offset, count: count)
                (r + framesWritten).update(from: inR + offset, count: count)
                // The bars also go straight into the live pad's buffer.
                let loopCount = min(count, loopFrames - framesWritten)
                if loopCount > 0, let ll = liveLeft, let lr = liveRight {
                    (ll + framesWritten).update(from: inL + offset, count: loopCount)
                    (lr + framesWritten).update(from: inR + offset, count: loopCount)
                }
                let wasInLoop = framesWritten < loopFrames
                let tailStart = max(loopFrames - framesWritten, 0)
                framesWritten += count
                if wasInLoop && framesWritten >= loopFrames {
                    // Bars complete: the pad plays on from the next frame, gap-free
                    // (its anchor is the end of the bars, same phase as their start).
                    if liveSlot >= 0 { loops?.startLive(liveSlot, anchor: startBeat + loopBeats) }
                    noteTrigger = false
                }
                if tailStart < count {
                    trackTailSilence(left: inL + offset + tailStart, right: inR + offset + tailStart,
                                     count: count - tailStart)
                }
            }
        }
        if framesWritten >= totalFrames, os_unfair_lock_trylock(lock) {
            foldTail()
            state = .finished
            latched = false
            audioBusy = false
            os_unfair_lock_unlock(lock)
        }
    }

    /// Audio thread: once the tail has stayed silent long enough, it is
    /// complete (the rest of the buffers is already zero).
    private func trackTailSilence(left: UnsafePointer<Float>, right: UnsafePointer<Float>, count: Int) {
        var peak: Float = 0
        for i in 0..<count { peak = max(peak, abs(left[i]), abs(right[i])) }
        silentTailFrames = peak < LoopRecorder.silenceLevel ? silentTailFrames + count : 0
        if silentTailFrames >= Int(LoopRecorder.silenceSeconds * sampleRate) {
            endTail(cut: false)
        }
    }

    /// Audio thread: ends the tail at `framesWritten`. A cut (new note,
    /// stop) fades the last captured frames so the fold has no click.
    private func endTail(cut: Bool) {
        guard let l = left, let r = right else { return }
        let captured = framesWritten - loopFrames
        if cut && captured > 0 {
            let n = min(LoopRecorder.cutFadeFrames, captured)
            for i in 0..<n {
                let g = Float(n - i) / Float(n + 1)
                l[framesWritten - n + i] *= g
                r[framesWritten - n + i] *= g
            }
        }
        // Zero what lies beyond, then mark the take complete.
        let rest = totalFrames - framesWritten
        if rest > 0 {
            (l + framesWritten).initialize(repeating: 0, count: rest)
            (r + framesWritten).initialize(repeating: 0, count: rest)
        }
        tailFrames = max(captured, 0)
        totalFrames = framesWritten
    }

    /// Audio thread: folds the tail onto the loop start, in the take and in
    /// the live pad's buffer (whose next pass then carries the ringing).
    private func foldTail() {
        guard let l = left, let r = right, loopFrames > 0 else { return }
        let tail = framesWritten - loopFrames
        guard tail > 0 else { return }
        for i in 0..<tail {
            let j = i % loopFrames
            let tl = l[loopFrames + i], tr = r[loopFrames + i]
            l[j] += tl
            r[j] += tr
            if let ll = liveLeft, let lr = liveRight {
                ll[j] += tl
                lr[j] += tr
            }
        }
    }

    /// The bars are complete and the tail (effect / release ringing) is
    /// being captured.
    var capturingTail: Bool {
        state == .recording && framesWritten >= loopFrames && framesWritten < totalFrames
    }

    /// Progress through the recorded bars (0...1); the tail is not included.
    var progress: Double {
        loopFrames > 0 ? min(Double(framesWritten) / Double(loopFrames), 1) : 0
    }
}
