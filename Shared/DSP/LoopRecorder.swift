import Foundation
import os

/// Bar-accurate loop recorder running on the audio thread.
///
/// The main thread prepares buffers and arms the recorder; the audio thread
/// starts on the first note (or on the next bar of the beat clock), records
/// exactly `bars` bars plus an optional tail, and marks the take finished.
/// The main thread then folds the tail onto the loop start (so delay /
/// reverb ring seamlessly across the loop point) and writes a WAV file.
///
/// Thread hand-off: configuration changes are made by the main thread under
/// a lock while the audio thread is not using the buffers; the audio thread
/// only ever uses `trylock`, so it never blocks.
final class LoopRecorder {
    enum State: Int32 {
        case idle, armed, recording, finished
    }

    struct Take {
        let left: [Float]
        let right: [Float]
        let loopFrames: Int
        let tailFrames: Int
        let sampleRate: Double
    }

    private let lock: UnsafeMutablePointer<os_unfair_lock>

    // Shared state (racy reads are fine for UI polling; transitions use the lock).
    private(set) var state: State = .idle
    private(set) var framesWritten = 0
    private(set) var totalFrames = 0
    private var cancelRequested = false

    // Configuration, written by main under the lock while the audio side is idle.
    private var left: UnsafeMutablePointer<Float>?
    private var right: UnsafeMutablePointer<Float>?
    private var capacity = 0
    private var loopFrames = 0
    private var tailFrames = 0
    private var startOnNote = true
    private var sampleRate: Double = 44100

    // Audio-thread private.
    private var latched = false
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

    /// Arms a take of `bars` bars at `tempo`. Returns false while busy.
    func arm(bars: Int, tempo: Double, sampleRate: Double, startOnNote: Bool, tailSeconds: Double) -> Bool {
        guard !audioBusy, state == .idle || state == .finished else { return false }
        let beats = Double(bars * 4)
        let loop = Int((beats * 60 / max(tempo, 20) * sampleRate).rounded())
        let tail = Int(tailSeconds * sampleRate)
        let total = loop + tail
        guard total > 0 else { return false }

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
        tailFrames = tail
        totalFrames = total
        framesWritten = 0
        self.startOnNote = startOnNote
        self.sampleRate = sampleRate
        cancelRequested = false
        state = .armed
        os_unfair_lock_unlock(lock)
        return true
    }

    func cancel() {
        os_unfair_lock_lock(lock)
        if state == .armed || state == .recording { cancelRequested = true }
        if !audioBusy { state = .idle; cancelRequested = false }
        os_unfair_lock_unlock(lock)
    }

    /// Copies a finished take out and resets to idle.
    func takeRecording() -> Take? {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        guard state == .finished, let l = left, let r = right else { return nil }
        let take = Take(left: Array(UnsafeBufferPointer(start: l, count: totalFrames)),
                        right: Array(UnsafeBufferPointer(start: r, count: totalFrames)),
                        loopFrames: loopFrames, tailFrames: tailFrames, sampleRate: sampleRate)
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
            noteTrigger = false
            guard state == .armed else { return }
            guard os_unfair_lock_trylock(lock) else { return }
            if state == .armed && !cancelRequested {
                latched = true
                audioBusy = true
            }
            os_unfair_lock_unlock(lock)
            if !latched { return }
        }

        if cancelRequested {
            if os_unfair_lock_trylock(lock) {
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
            state = .recording
        }

        guard state == .recording, let l = left, let r = right else { return }
        let remaining = totalFrames - framesWritten
        if remaining > 0 {
            let count = min(remaining, frames - offset)
            if count > 0 {
                (l + framesWritten).update(from: inL + offset, count: count)
                (r + framesWritten).update(from: inR + offset, count: count)
                framesWritten += count
            }
        }
        if framesWritten >= totalFrames, os_unfair_lock_trylock(lock) {
            state = .finished
            latched = false
            audioBusy = false
            os_unfair_lock_unlock(lock)
        }
    }

    var progress: Double {
        totalFrames > 0 ? Double(framesWritten) / Double(totalFrames) : 0
    }
}

extension LoopRecorder.Take {
    /// Folds the tail onto the loop start so the loop plays back seamlessly.
    func seamlessLoop(wrapTail: Bool) -> (left: [Float], right: [Float]) {
        var l = Array(left.prefix(loopFrames))
        var r = Array(right.prefix(loopFrames))
        if wrapTail && loopFrames > 0 {
            for i in 0..<min(tailFrames, left.count - loopFrames) {
                l[i % loopFrames] += left[loopFrames + i]
                r[i % loopFrames] += right[loopFrames + i]
            }
        }
        return (l, r)
    }
}
