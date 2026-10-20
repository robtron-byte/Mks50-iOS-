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
    }

    private let slots: UnsafeMutablePointer<Slot>
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    /// Bit i set while slot i sounds (racy read for the UI).
    private(set) var soundingMask: Int = 0
    /// Bit i set while slot i waits for its first bar (racy read for the UI).
    private(set) var pendingMask: Int = 0

    init() {
        slots = .allocate(capacity: LoopPlayer.slotCount)
        slots.initialize(repeating: Slot(), count: LoopPlayer.slotCount)
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        for i in 0..<LoopPlayer.slotCount {
            slots[i].left?.deallocate()
            slots[i].right?.deallocate()
        }
        slots.deallocate()
        lock.deallocate()
    }

    /// Any slot playing or fading out.
    var active: Bool { soundingMask != 0 || pendingMask != 0 }

    // MARK: Main thread

    /// Loads a loop of `beats` beats into a slot (stopped).
    func load(_ slot: Int, left: [Float], right: [Float], beats: Double) {
        guard (0..<LoopPlayer.slotCount).contains(slot), !left.isEmpty else { return }
        let frames = min(left.count, right.count)
        let l = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        let r = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        left.withUnsafeBufferPointer { l.initialize(from: $0.baseAddress!, count: frames) }
        right.withUnsafeBufferPointer { r.initialize(from: $0.baseAddress!, count: frames) }
        os_unfair_lock_lock(lock)
        let oldL = slots[slot].left, oldR = slots[slot].right
        slots[slot] = Slot(left: l, right: r, frames: frames, beats: max(beats, 1))
        os_unfair_lock_unlock(lock)
        oldL?.deallocate()                      // the audio thread is not inside: we held the lock
        oldR?.deallocate()
    }

    func unload(_ slot: Int) {
        guard (0..<LoopPlayer.slotCount).contains(slot) else { return }
        os_unfair_lock_lock(lock)
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
            var waiting = false
            for n in 0..<frames {
                let beat = beatStart + Double(n) * beatsPerFrame
                if beat < anchor {
                    waiting = true
                    continue
                }
                gain += max(-fade, min(fade, target - gain))
                if gain <= 0 { break }
                var pos = (beat - anchor) / beats
                pos -= pos.rounded(.down)
                let x = pos * Double(count)
                let i0 = min(Int(x), count - 1)
                let i1 = i0 + 1 < count ? i0 + 1 : 0
                let t = Float(x - Double(i0))
                left[n] += (l[i0] + (l[i1] - l[i0]) * t) * gain
                right[n] += (r[i0] + (r[i1] - r[i0]) * t) * gain
            }
            slots[i].gain = gain
            if slots[i].playing && waiting && gain <= 0 { pending |= 1 << i }
            if gain > 0 { sounding |= 1 << i }
            if slots[i].playing && !waiting { sounding |= 1 << i }
        }
        soundingMask = sounding
        pendingMask = pending
    }
}
