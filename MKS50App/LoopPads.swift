import AVFoundation
import SwiftUI

/// 4 loop pads: recordings assigned to them play in time with the beat
/// clock (see LoopPlayer). With AUTO, a finished recording goes straight
/// onto a pad and keeps playing, so you can play over it with another sound.
final class LoopPadsModel: ObservableObject {
    static let padCount = LoopPlayer.slotCount
    private static let padsKey = "loopPads"
    private static let autoKey = "loopAutoPlay"

    /// Assigned file per pad.
    @Published private(set) var pads: [URL?]
    @Published var autoPlay: Bool {
        didSet { UserDefaults.standard.set(autoPlay, forKey: LoopPadsModel.autoKey) }
    }

    private let engine: SynthEngine
    private let synth: SynthViewModel

    init(engine: SynthEngine, synth: SynthViewModel) {
        self.engine = engine
        self.synth = synth
        autoPlay = UserDefaults.standard.object(forKey: LoopPadsModel.autoKey) as? Bool ?? true
        let stored = UserDefaults.standard.stringArray(forKey: LoopPadsModel.padsKey) ?? []
        pads = (0..<LoopPadsModel.padCount).map { i in
            guard i < stored.count, !stored[i].isEmpty,
                  FileManager.default.fileExists(atPath: stored[i]) else { return nil }
            return URL(fileURLWithPath: stored[i])
        }
        for (i, url) in pads.enumerated() {
            if let url { loadFile(url, into: i, thenPlay: false) }
        }
    }

    // MARK: Pads

    func isEmpty(_ pad: Int) -> Bool { pads[pad] == nil }

    /// Tap: start (on the next bar) or stop.
    func toggle(_ pad: Int) {
        guard pads[pad] != nil else { return }
        if engine.loops.isPlaying(pad) {
            engine.loops.stop(pad)
        } else {
            engine.loops.play(pad)
        }
        objectWillChange.send()
    }

    func stopAll() {
        for i in 0..<LoopPadsModel.padCount { engine.loops.stop(i) }
        objectWillChange.send()
    }

    func assign(_ url: URL, to pad: Int) {
        let wasPlaying = engine.loops.isPlaying(pad)
        pads[pad] = url
        persist()
        loadFile(url, into: pad, thenPlay: wasPlaying)
    }

    func clear(_ pad: Int) {
        engine.loops.unload(pad)
        pads[pad] = nil
        persist()
    }

    /// Short label: bars and BPM from the file name ("2bar", "120BPM").
    func label(_ pad: Int) -> String? {
        guard let url = pads[pad] else { return nil }
        let name = url.deletingPathExtension().lastPathComponent
        let bars = LoopPadsModel.number(before: "bar", in: name).map { "\($0)B" } ?? ""
        let bpm = LoopPadsModel.number(before: "BPM", in: name).map { "\($0)" } ?? ""
        let text = [bars, bpm].filter { !$0.isEmpty }.joined(separator: " ")
        return text.isEmpty ? String(name.prefix(6)) : text
    }

    /// A recording was just saved: with AUTO it goes onto the first empty
    /// pad (or the last one) and plays on at once, in time with the bar it
    /// was recorded in.
    func recordingSaved(_ url: URL, left: [Float], right: [Float], beats: Double, startBeat: Double) {
        guard autoPlay else { return }
        let pad = pads.firstIndex(where: { $0 == nil }) ?? LoopPadsModel.padCount - 1
        pads[pad] = url
        persist()
        engine.loops.load(pad, left: left, right: right, beats: beats)
        engine.loops.play(pad, anchor: startBeat)
        synth.flash("Loop on pad \(pad + 1)")
    }

    /// A recording was deleted: free the pads that used it.
    func fileDeleted(_ url: URL) {
        for i in pads.indices where pads[i]?.standardizedFileURL == url.standardizedFileURL { clear(i) }
    }

    // MARK: Private

    private func persist() {
        UserDefaults.standard.set(pads.map { $0?.path ?? "" }, forKey: LoopPadsModel.padsKey)
    }

    private func loadFile(_ url: URL, into pad: Int, thenPlay: Bool) {
        let tempo = engine.tempoBPM
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let loop = LoopPadsModel.read(url, tempo: tempo) else {
                DispatchQueue.main.async { self?.synth.flash("Could not load \(url.lastPathComponent)") }
                return
            }
            DispatchQueue.main.async {
                guard let self, self.pads[pad] == url else { return }
                self.engine.loops.load(pad, left: loop.left, right: loop.right, beats: loop.beats)
                if thenPlay { self.engine.loops.play(pad) }
                self.objectWillChange.send()
            }
        }
    }

    /// Reads a WAV as float samples. Length in beats from "<n>bar" in the
    /// name, else from the duration at the current tempo (whole bars).
    private static func read(_ url: URL, tempo: Double) -> (left: [Float], right: [Float], beats: Double)? {
        guard let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil,
              let data = buffer.floatChannelData, buffer.frameLength > 0 else { return nil }
        let frames = Int(buffer.frameLength)
        let left = Array(UnsafeBufferPointer(start: data[0], count: frames))
        let right = buffer.format.channelCount > 1
            ? Array(UnsafeBufferPointer(start: data[1], count: frames)) : left
        let name = url.deletingPathExtension().lastPathComponent
        let beats: Double
        if let bars = number(before: "bar", in: name), bars > 0 {
            beats = Double(bars * 4)
        } else {
            let seconds = Double(frames) / file.processingFormat.sampleRate
            beats = max(4, (seconds * tempo / 60 / 4).rounded() * 4)
        }
        return (left, right, beats)
    }

    /// The number directly in front of `suffix` ("120BPM" → 120).
    private static func number(before suffix: String, in text: String) -> Int? {
        guard let range = text.range(of: suffix, options: .backwards) else { return nil }
        let digits = text[..<range.lowerBound].reversed().prefix { $0.isNumber }
        return Int(String(digits.reversed()))
    }
}

/// LOOPS row of the recorder strip: 4 pads and AUTO.
/// Empty pad: tap to pick a recording. Filled pad: tap to play / stop
/// (starts on the next bar), hold for assign / clear.
struct LoopPadsRow: View {
    @ObservedObject var pads: LoopPadsModel
    @ObservedObject var recorder: RecorderModel
    let engine: SynthEngine

    var body: some View {
        HStack(spacing: 6) {
            Text("LOOPS")
                .font(Theme.pixel(9, .bold))
                .foregroundColor(Theme.dimLabel)
            HStack(spacing: 4) {
                ForEach(0..<LoopPadsModel.padCount, id: \.self) { i in pad(i) }
            }
            BigButton(title: "AUTO", icon: "repeat", active: pads.autoPlay) { pads.autoPlay.toggle() }
                .accessibilityHint("Play each new recording on a pad right away")
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private func pad(_ i: Int) -> some View {
        let label = LoopPadFace(index: i, title: pads.label(i), engine: engine)

        if pads.isEmpty(i) {
            Menu { assignItems(i) } label: { label }
                .accessibilityLabel("Loop pad \(i + 1), empty")
        } else {
            Menu {
                Menu("Assign Recording") { assignItems(i) }
                Button("Clear Pad", role: .destructive) { pads.clear(i) }
            } label: { label } primaryAction: {
                pads.toggle(i)
            }
            .accessibilityLabel("Loop pad \(i + 1)")
        }
    }

    @ViewBuilder private func assignItems(_ i: Int) -> some View {
        if recorder.recordings.isEmpty {
            Text("No recordings yet")
        }
        ForEach(recorder.recordings.prefix(30), id: \.self) { url in
            Button(url.deletingPathExtension().lastPathComponent) { pads.assign(url, to: i) }
        }
    }
}

/// Pad surface: lit while the loop sounds, blinking while it waits for
/// the next bar. Only this part redraws with the timeline.
private struct LoopPadFace: View {
    let index: Int
    let title: String?
    let engine: SynthEngine

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.125)) { context in
            let blink = Int(context.date.timeIntervalSinceReferenceDate * 4) % 2 == 0
            let bit = 1 << index
            let lit = engine.loops.soundingMask & bit != 0 || (engine.loops.pendingMask & bit != 0 && blink)
            let empty = title == nil
            VStack(spacing: 0) {
                Text("\(index + 1)").font(Theme.pixel(12, .bold))
                Text(title ?? "+")
                    .font(Theme.pixel(8, .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundColor(lit ? Theme.ink : (empty ? Theme.dimLabel : Theme.label))
            .frame(width: 50, height: 40)
            .background(RoundedRectangle(cornerRadius: Theme.corner)
                .fill(lit ? Theme.violet : (empty ? Theme.cell.opacity(0.4) : Theme.cell)))
            .overlay(RoundedRectangle(cornerRadius: Theme.corner)
                .stroke(empty ? Theme.hairline : .clear, lineWidth: 1))
        }
    }
}
