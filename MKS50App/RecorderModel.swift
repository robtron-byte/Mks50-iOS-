import AVFoundation
import SwiftUI

/// Loop recorder front end: arms the engine's bar-accurate recorder, polls
/// its progress and writes finished takes as 24-bit WAV files.
final class RecorderModel: ObservableObject {
    enum Phase: Equatable { case idle, armed, recording, tail, saving }

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
    /// Folder chosen in Settings (iCloud Drive, a USB drive, another app's
    /// folder …), nil = the app's own Recordings folder.
    @Published private(set) var customFolder: URL?

    private let audioUnit: MKS50AudioUnit
    private let synth: SynthViewModel
    private var timer: Timer?
    private var player: AVAudioPlayer?
    /// Bars of the take being recorded (the BARS setting may change meanwhile).
    private var armedBars = 2
    /// Loop pad a new take should go live on (loop pads AUTO), nil = none.
    var liveTarget: (() -> Int?)?
    /// Called after a take was saved: file and the pad it already plays on.
    var onLoopSaved: ((URL, Int) -> Void)?
    /// Called when a recording file was deleted.
    var onDeleted: ((URL) -> Void)?

    private var engine: SynthEngine { audioUnit.engine }
    /// Bar currently being recorded (1-based), for the record button.
    var currentBar: Int { min(Int(progress * Double(armedBars)) + 1, armedBars) }
    var recordingBars: Int { armedBars }

    var bars: Int { RecorderModel.barOptions[min(max(barsIndex, 0), RecorderModel.barOptions.count - 1)] }

    init(audioUnit: MKS50AudioUnit, synth: SynthViewModel) {
        self.audioUnit = audioUnit
        self.synth = synth
        let defaults = UserDefaults.standard
        barsIndex = defaults.object(forKey: "recorderBars") as? Int ?? 1          // 2 bars
        startOnNote = defaults.object(forKey: "recorderStartOnNote") as? Bool ?? true
        wrapTails = defaults.object(forKey: "recorderWrapTails") as? Bool ?? true
        customFolder = RecorderModel.resolveFolderBookmark()
        if let folder = customFolder, !folder.startAccessingSecurityScopedResource() {
            customFolder = nil                  // no longer reachable: back to the default
        }
        refreshRecordings()
    }

    deinit {
        timer?.invalidate()
        customFolder?.stopAccessingSecurityScopedResource()
    }

    // MARK: Recording

    func toggleRecord() {
        switch phase {
        case .idle: arm()
        case .armed, .recording, .tail: cancel()
        case .saving: break
        }
    }

    private func arm() {
        stopPreview()
        let ok = engine.recorder.arm(bars: bars,
                                     tempo: engine.tempoBPM,
                                     sampleRate: engine.currentSampleRate,
                                     startOnNote: startOnNote,
                                     tailSeconds: wrapTails ? 4 : 0,
                                     liveSlot: liveTarget?())
        guard ok else {
            synth.flash("Recorder busy – try again")
            return
        }
        armedBars = bars
        phase = .armed
        progress = 0
        startPolling()
        synth.flash(startOnNote ? "Armed – recording starts with the first note"
                                : "Armed – recording starts on the next bar")
    }

    private func cancel() {
        if phase == .tail {
            // The loop is complete (and maybe already looping): just end the tail.
            engine.recorder.cancel()
            return
        }
        engine.recorder.cancel()
        phase = .idle
        progress = 0
        stopPolling()
        // Frees the loop pad reserved for the take once the audio side let go.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.engine.recorder.cleanUpAfterCancel()
        }
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
            progress = engine.recorder.progress
            phase = engine.recorder.capturingTail ? .tail : .recording
        case .finished:
            finish()
        case .idle:
            engine.recorder.cleanUpAfterCancel()
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
        let name = fileName()
        let url = directory.appendingPathComponent(name)
        let fallback = Self.defaultDirectory.appendingPathComponent(name)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let loop = (left: take.left, right: take.right)
            let write = { (target: URL) in
                try RecorderModel.writeWAV(left: loop.left, right: loop.right,
                                           sampleRate: take.sampleRate, to: target)
            }
            var saved = url
            var result = Result { try write(url) }
            if case .failure = result, url != fallback {
                // Chosen folder not writable (e.g. drive unplugged): keep the take.
                saved = fallback
                result = Result { try write(fallback) }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.phase = .idle
                self.progress = 0
                self.refreshRecordings()
                switch result {
                case .success where saved == url: self.synth.flash("Saved \(name)")
                case .success: self.synth.flash("Folder not available – saved in the app folder")
                case .failure(let error): self.synth.flash("Saving failed: \(error.localizedDescription)")
                }
                if case .success = result, let pad = take.liveSlot {
                    self.onLoopSaved?(saved, pad)
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
        return "MKS50 \(safe) \(bpm)BPM \(armedBars)bar \(formatter.string(from: Date())).wav"
    }

    // MARK: Files

    private static let folderBookmarkKey = "recordingsFolderBookmark"

    /// Documents/Recordings – visible in the Files app under "On My iPhone › MKS-50".
    static var defaultDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Where new recordings go and which folder the list shows.
    var directory: URL { customFolder ?? Self.defaultDirectory }

    /// Name of the save location for Settings.
    var folderName: String { customFolder?.lastPathComponent ?? "MKS50 › Recordings (default)" }

    /// Uses a folder picked in the Files dialog. Its access permission is
    /// stored as a bookmark, so it survives app restarts.
    func setFolder(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        guard let bookmark = try? url.bookmarkData() else {
            if scoped { url.stopAccessingSecurityScopedResource() }
            synth.flash("Could not use \(url.lastPathComponent)")
            return
        }
        customFolder?.stopAccessingSecurityScopedResource()
        UserDefaults.standard.set(bookmark, forKey: Self.folderBookmarkKey)
        customFolder = url                      // stays accessed while in use
        stopPreview()
        refreshRecordings()
        synth.flash("Recordings go to \(url.lastPathComponent)")
    }

    /// Back to the app's own Recordings folder.
    func resetFolder() {
        customFolder?.stopAccessingSecurityScopedResource()
        customFolder = nil
        UserDefaults.standard.removeObject(forKey: Self.folderBookmarkKey)
        stopPreview()
        refreshRecordings()
    }

    private static func resolveFolderBookmark() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: folderBookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale) else { return nil }
        if stale, let fresh = try? url.bookmarkData() {
            UserDefaults.standard.set(fresh, forKey: folderBookmarkKey)
        }
        return url
    }

    func refreshRecordings() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.creationDateKey])) ?? []
        recordings = files
            .filter { $0.pathExtension.lowercased() == "wav" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    func delete(_ url: URL) {
        if playing == url { stopPreview() }
        try? FileManager.default.removeItem(at: url)
        onDeleted?(url)
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
