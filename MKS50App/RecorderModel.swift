import AVFoundation
import SwiftUI

/// Loop recorder front end: arms the engine's bar-accurate recorder, polls
/// its progress and writes finished takes as 24-bit WAV files.
final class RecorderModel: ObservableObject {
    enum Phase: Equatable { case idle, armed, recording, saving }

    static let barOptions = [1, 2, 4, 8]

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var progress: Double = 0
    @Published private(set) var recordings: [URL] = []
    @Published var barsIndex: Int {
        didSet { UserDefaults.standard.set(barsIndex, forKey: "recorderBars") }
    }
    @Published var startOnNote: Bool {
        didSet { UserDefaults.standard.set(startOnNote, forKey: "recorderStartOnNote") }
    }
    @Published var wrapTails: Bool {
        didSet { UserDefaults.standard.set(wrapTails, forKey: "recorderWrapTails") }
    }
    /// File currently previewed (looped) in the recordings list.
    @Published private(set) var playing: URL?

    private let audioUnit: MKS50AudioUnit
    private let synth: SynthViewModel
    private var timer: Timer?
    private var player: AVAudioPlayer?

    private var engine: SynthEngine { audioUnit.engine }
    var bars: Int { RecorderModel.barOptions[min(max(barsIndex, 0), RecorderModel.barOptions.count - 1)] }

    init(audioUnit: MKS50AudioUnit, synth: SynthViewModel) {
        self.audioUnit = audioUnit
        self.synth = synth
        let defaults = UserDefaults.standard
        barsIndex = defaults.object(forKey: "recorderBars") as? Int ?? 1          // 2 bars
        startOnNote = defaults.object(forKey: "recorderStartOnNote") as? Bool ?? true
        wrapTails = defaults.object(forKey: "recorderWrapTails") as? Bool ?? true
        refreshRecordings()
    }

    deinit { timer?.invalidate() }

    // MARK: Recording

    func toggleRecord() {
        switch phase {
        case .idle: arm()
        case .armed, .recording: cancel()
        case .saving: break
        }
    }

    private func arm() {
        stopPreview()
        let ok = engine.recorder.arm(bars: bars,
                                     tempo: engine.tempoBPM,
                                     sampleRate: engine.currentSampleRate,
                                     startOnNote: startOnNote,
                                     tailSeconds: wrapTails ? 4 : 0)
        guard ok else {
            synth.flash("Recorder busy – try again")
            return
        }
        phase = .armed
        progress = 0
        startPolling()
        synth.flash(startOnNote ? "Armed – recording starts with the first note"
                                : "Armed – recording starts on the next bar")
    }

    private func cancel() {
        engine.recorder.cancel()
        phase = .idle
        progress = 0
        stopPolling()
        synth.flash("Recording cancelled")
    }

    private func startPolling() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        switch engine.recorder.state {
        case .armed:
            phase = .armed
        case .recording:
            phase = .recording
            progress = engine.recorder.progress
        case .finished:
            finish()
        case .idle:
            if phase != .saving {
                phase = .idle
                stopPolling()
            }
        }
    }

    private func finish() {
        guard let take = engine.recorder.takeRecording() else { return }
        stopPolling()
        phase = .saving
        progress = 1
        let wrap = wrapTails
        let url = Self.directory.appendingPathComponent(fileName())
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let loop = take.seamlessLoop(wrapTail: wrap)
            let result = Result { try RecorderModel.writeWAV(left: loop.left, right: loop.right,
                                                             sampleRate: take.sampleRate, to: url) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.phase = .idle
                self.progress = 0
                self.refreshRecordings()
                switch result {
                case .success: self.synth.flash("Saved \(url.lastPathComponent)")
                case .failure(let error): self.synth.flash("Saving failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func fileName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let tone = synth.toneName.isEmpty ? "MKS50" : synth.toneName
        let safe = tone.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let bpm = Int(engine.tempoBPM.rounded())
        return "MKS50 \(safe) \(bpm)BPM \(bars)bar \(formatter.string(from: Date())).wav"
    }

    // MARK: Files

    /// Documents/Recordings – visible in the Files app under "On My iPhone › MKS-50".
    static var directory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func refreshRecordings() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: Self.directory, includingPropertiesForKeys: [.creationDateKey])) ?? []
        recordings = files
            .filter { $0.pathExtension.lowercased() == "wav" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    func delete(_ url: URL) {
        if playing == url { stopPreview() }
        try? FileManager.default.removeItem(at: url)
        refreshRecordings()
    }

    /// Plays a recording in a loop (to check the loop point), or stops it.
    func togglePreview(_ url: URL) {
        if playing == url {
            stopPreview()
            return
        }
        stopPreview()
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return }
        player.numberOfLoops = -1
        player.play()
        self.player = player
        playing = url
    }

    func stopPreview() {
        player?.stop()
        player = nil
        playing = nil
    }

    static func duration(of url: URL) -> String {
        guard let file = try? AVAudioFile(forReading: url) else { return "" }
        let seconds = Double(file.length) / file.fileFormat.sampleRate
        return String(format: "%.1f s", seconds)
    }

    /// Writes a 24-bit PCM stereo WAV.
    static func writeWAV(left: [Float], right: [Float], sampleRate: Double, to url: URL) throws {
        let frames = AVAudioFrameCount(min(left.count, right.count))
        guard frames > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channels = buffer.floatChannelData else {
            throw NSError(domain: "MKS50Recorder", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Empty recording"])
        }
        buffer.frameLength = frames
        left.withUnsafeBufferPointer { channels[0].update(from: $0.baseAddress!, count: Int(frames)) }
        right.withUnsafeBufferPointer { channels[1].update(from: $0.baseAddress!, count: Int(frames)) }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }
}
