import Foundation
import os

/// Plays recorded loops in time with the beat clock (app only): 4 slots,
/// any number of them at once. The play position is derived from the beat
/// (position = (beat − anchor) mod loop length), so a loop stays locked to
/// the tempo, the sequencer and the recorder bars; at a different tempo
/// than it was recorded at it plays faster or slower (varispeed). While
/// the MIDI clock source is stopped the beat stands still and loops pause.
///
/// Buffers are loaded and freed on the main thread under a lock; the audio
/// thread only try-locks, so it never waits.
///
/// Live looping: `prepareLive` reserves a slot and hands its new (empty)
/// buffer to the loop recorder, which records straight into it and calls
/// `startLive` on the frame the bars are complete; the slot then switches
/// to the new loop at once (the previous loop of that slot, if any, plays
/// until then). While reserved, the slot cannot be loaded or cleared.
final class LoopPlayer {
    static let slotCount = 4

    private struct Slot {
        var left: UnsafeMutablePointer<Float>? = nil
        var right: UnsafeMutablePointer<Float>? = nil
        var frames = 0
        var beats: Double = 8
        /// Beat at which the loop's first frame plays (nan: start on the next bar).
        var anchor: Double = 0
        var playing = false
        var gain: Float = 0
        // Live take (see `prepareLive`).
        var reserved = false
        var liveLeft: UnsafeMutablePointer<Float>? = nil
        var liveRight: UnsafeMutablePointer<Float>? = nil
        var liveFrames = 0
        var liveBeats: Double = 8
        /// Set by the recorder (audio thread) when the take is complete.
        var liveAnchor: Double = .nan
        /// Buffers replaced by a live take, freed by the main thread.
        var retiredLeft: UnsafeMutablePointer<Float>? = nil
        var retiredRight: UnsafeMutablePointer<Float>? = nil
    }

    private let slots: UnsafeMutablePointer<Slot>
    /// Level per slot (0...1, set by the main thread, e.g. from a controller)
    /// and its smoothed value on the audio thread, so turning it never zips.
    private let levels: UnsafeMutablePointer<Float>
    private let smoothedLevels: UnsafeMutablePointer<Float>
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    /// Bit i set while slot i sounds (racy read for the UI).
    private(set) var soundingMask: Int = 0
    /// Bit i set while slot i waits for its first bar (racy read for the UI).
    private(set) var pendingMask: Int = 0

    init() {
        levels = .allocate(capacity: LoopPlayer.slotCount)
        levels.initialize(repeating: 1, count: LoopPlayer.slotCount)
        smoothedLevels = .allocate(capacity: LoopPlayer.slotCount)
        smoothedLevels.initialize(repeating: 1, count: LoopPlayer.slotCount)
        slots = .allocate(capacity: LoopPlayer.slotCount)
        slots.initialize(repeating: Slot(), count: LoopPlayer.slotCount)
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        for i in 0..<LoopPlayer.slotCount {
            slots[i].left?.deallocate()
            slots[i].right?.deallocate()
            slots[i].liveLeft?.deallocate()
            slots[i].liveRight?.deallocate()
            slots[i].retiredLeft?.deallocate()
            slots[i].retiredRight?.deallocate()
        }
        slots.deallocate()
        levels.deallocate()
        smoothedLevels.deallocate()
        lock.deallocate()
    }

    /// A live take is about to start (audio thread).
    private var liveStartMask = 0

    /// Any slot playing, fading out or about to start a live take.
    var active: Bool { soundingMask != 0 || pendingMask != 0 || liveStartMask != 0 }

    /// True while a live take records into the slot.
    func isReserved(_ slot: Int) -> Bool {
        (0..<LoopPlayer.slotCount).contains(slot) && slots[slot].reserved
    }

    // MARK: Main thread

    /// Loads a loop of `beats` beats into a slot (stopped).
    func load(_ slot: Int, left: [Float], right: [Float], beats: Double) {
        guard (0..<LoopPlayer.slotCount).contains(slot), !left.isEmpty, !slots[slot].reserved else { return }
        let frames = min(left.count, right.count)
        let l = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        let r = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        left.withUnsafeBufferPointer { l.initialize(from: $0.baseAddress!, count: frames) }
        right.withUnsafeBufferPointer { r.initialize(from: $0.baseAddress!, count: frames) }
        os_unfair_lock_lock(lock)
        guard !slots[slot].reserved else {
            os_unfair_lock_unlock(lock)
            l.deallocate()
            r.deallocate()
            return
        }
        let oldL = slots[slot].left, oldR = slots[slot].right
        slots[slot] = Slot(left: l, right: r, frames: frames, beats: max(beats, 1))
        os_unfair_lock_unlock(lock)
        oldL?.deallocate()                      // the audio thread is not inside: we held the lock
        oldR?.deallocate()
    }

    func unload(_ slot: Int) {
        guard (0..<LoopPlayer.slotCount).contains(slot) else { return }
        os_unfair_lock_lock(lock)
        guard !slots[slot].reserved else { os_unfair_lock_unlock(lock); return }
        let oldL = slots[slot].left, oldR = slots[slot].right
        slots[slot] = Slot()
        soundingMask &= ~(1 << slot)
        pendingMask &= ~(1 << slot)
        os_unfair_lock_unlock(lock)
        oldL?.deallocate()
        oldR?.deallocate()
    }

    /// Starts a slot. `anchor`: beat of the loop's first frame (it plays
    /// on from there at once); nil starts it on the next bar line.
    func play(_ slot: Int, anchor: Double? = nil) {
        guard (0..<LoopPlayer.slotCount).contains(slot) else { return }
        os_unfair_lock_lock(lock)
        if slots[slot].frames > 0 {
            slots[slot].anchor = anchor ?? .nan
            slots[slot].playing = true
            pendingMask |= 1 << slot
        }
        os_unfair_lock_unlock(lock)
    }

    func stop(_ slot: Int) {
        guard (0..<LoopPlayer.slotCount).contains(slot) else { return }
        os_unfair_lock_lock(lock)
        slots[slot].playing = false
        os_unfair_lock_unlock(lock)
    }

    /// Reserves a slot for a live take of `frames` frames / `beats` beats
    /// and returns its zeroed buffers (the recorder writes into them until
    /// `releaseLive`). nil if the slot is already reserved.
    func prepareLive(_ slot: Int, frames: Int, beats: Double)
        -> (UnsafeMutablePointer<Float>, UnsafeMutablePointer<Float>)? {
        guard (0..<LoopPlayer.slotCount).contains(slot), frames > 0 else { return nil }
        let l = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        let r = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        l.initialize(repeating: 0, count: frames)
        r.initialize(repeating: 0, count: frames)
        os_unfair_lock_lock(lock)
        guard !slots[slot].reserved else {
            os_unfair_lock_unlock(lock)
            l.deallocate()
            r.deallocate()
            return nil
        }
        slots[slot].reserved = true
        slots[slot].liveLeft = l
        slots[slot].liveRight = r
        slots[slot].liveFrames = frames
        slots[slot].liveBeats = max(beats, 1)
        slots[slot].liveAnchor = .nan
        os_unfair_lock_unlock(lock)
        return (l, r)
    }

    /// Ends the reservation once the recorder no longer writes. `started`:
    /// the take went live; otherwise (cancelled) its buffers are dropped and
    /// the slot keeps what it had.
    func releaseLive(_ slot: Int, started: Bool) {
        guard (0..<LoopPlayer.slotCount).contains(slot) else { return }
        os_unfair_lock_lock(lock)
        var free: [UnsafeMutablePointer<Float>?] = [slots[slot].retiredLeft, slots[slot].retiredRight]
        slots[slot].retiredLeft = nil
        slots[slot].retiredRight = nil
        if started, !slots[slot].liveAnchor.isNaN, let ll = slots[slot].liveLeft, let lr = slots[slot].liveRight {
            // Complete but not switched yet (e.g. transport halted): switch here.
            free += [slots[slot].left, slots[slot].right]
            slots[slot].left = ll
            slots[slot].right = lr
            slots[slot].frames = slots[slot].liveFrames
            slots[slot].beats = slots[slot].liveBeats
            slots[slot].anchor = slots[slot].liveAnchor
            slots[slot].playing = true
            slots[slot].gain = 1
            slots[slot].liveLeft = nil
            slots[slot].liveRight = nil
            slots[slot].liveAnchor = .nan
            liveStartMask &= ~(1 << slot)
            pendingMask |= 1 << slot
        } else if slots[slot].liveLeft != nil {
            // Cancelled before the bars were complete: drop the live buffers.
            free += [slots[slot].liveLeft, slots[slot].liveRight]
            slots[slot].liveLeft = nil
            slots[slot].liveRight = nil
            slots[slot].liveAnchor = .nan
            liveStartMask &= ~(1 << slot)
        }
        slots[slot].reserved = false
        os_unfair_lock_unlock(lock)
        for p in free { p?.deallocate() }
    }

    // MARK: Audio thread (recorder)

    /// The live take in `slot` is complete with `frames` frames: it plays
    /// from `anchor` on (the beat right after its last frame).
    func startLive(_ slot: Int, anchor: Double, frames: Int) {
        guard (0..<LoopPlayer.slotCount).contains(slot), slots[slot].reserved, frames > 0 else { return }
        slots[slot].liveFrames = min(frames, slots[slot].liveFrames)
        slots[slot].liveAnchor = anchor
        liveStartMask |= 1 << slot
    }

    // MARK: Queries

    /// Level of a slot, 0...1 (main thread).
    func setLevel(_ slot: Int, _ level: Float) {
        guard (0..<LoopPlayer.slotCount).contains(slot) else { return }
        levels[slot] = min(max(level, 0), 1)
    }

    func level(_ slot: Int) -> Float {
        (0..<LoopPlayer.slotCount).contains(slot) ? levels[slot] : 1
    }

    func isPlaying(_ slot: Int) -> Bool {
        (0..<LoopPlayer.slotCount).contains(slot) && slots[slot].playing
    }

    // MARK: Audio thread

    /// Adds the playing loops to the output.
    /// - Parameters:
    ///   - beatStart: beat-clock position at the first frame
    ///   - beatsPerFrame: beat-clock speed (0: transport halted → pause)
    func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int,
                beatStart: Double, beatsPerFrame: Double, sampleRate: Double) {
        guard active, beatsPerFrame > 0, os_unfair_lock_trylock(lock) else { return }
        defer { os_unfair_lock_unlock(lock) }
        // About 5 ms fades for start / stop.
        let fade = Float(1 / max(0.005 * sampleRate, 1))
        var sounding = 0
        var pending = 0
        for i in 0..<LoopPlayer.slotCount {
            if !slots[i].liveAnchor.isNaN, let ll = slots[i].liveLeft, let lr = slots[i].liveRight {
                // Live take complete: switch to it on the spot, full level.
                slots[i].retiredLeft = slots[i].left
                slots[i].retiredRight = slots[i].right
                slots[i].left = ll
                slots[i].right = lr
                slots[i].frames = slots[i].liveFrames
                slots[i].beats = slots[i].liveBeats
                slots[i].anchor = slots[i].liveAnchor
                slots[i].playing = true
                slots[i].gain = 1
                slots[i].liveLeft = nil
                slots[i].liveRight = nil
                slots[i].liveAnchor = .nan
                liveStartMask &= ~(1 << i)
            }
            guard slots[i].frames > 0, let l = slots[i].left, let r = slots[i].right else { continue }
            // Start on the next bar line (4/4, or this one if we are right on
            // it); also when the beat jumped back (MIDI Start resets it to 0),
            // so the loop restarts with the song instead of waiting.
            if slots[i].playing && (slots[i].anchor.isNaN || slots[i].anchor - beatStart > 4) {
                slots[i].anchor = (beatStart / 4 - 1e-9).rounded(.up) * 4
            }
            if !slots[i].playing && slots[i].gain <= 0 { continue }
            let count = slots[i].frames
            let beats = slots[i].beats
            let anchor = slots[i].anchor
            let target: Float = slots[i].playing ? 1 : 0
            var gain = slots[i].gain
            var level = smoothedLevels[i]
            let levelTarget = levels[i]
            var waiting = false
            for n in 0..<frames {
                let beat = beatStart + Double(n) * beatsPerFrame
                if beat < anchor {
                    waiting = true
                    continue
                }
                gain += max(-fade, min(fade, target - gain))
                if gain <= 0 { break }
                level += (levelTarget - level) * 0.002     // ~10 ms
                var pos = (beat - anchor) / beats
                pos -= pos.rounded(.down)
                let x = pos * Double(count)
                let i0 = min(Int(x), count - 1)
                let i1 = i0 + 1 < count ? i0 + 1 : 0
                let t = Float(x - Double(i0))
                left[n] += (l[i0] + (l[i1] - l[i0]) * t) * gain * level
                right[n] += (r[i0] + (r[i1] - r[i0]) * t) * gain * level
            }
            smoothedLevels[i] = level
            slots[i].gain = gain
            if slots[i].playing && waiting && gain <= 0 { pending |= 1 << i }
            if gain > 0 { sounding |= 1 << i }
            if slots[i].playing && !waiting { sounding |= 1 << i }
        }
        soundingMask = sounding
        pendingMask = pending
    }
}
