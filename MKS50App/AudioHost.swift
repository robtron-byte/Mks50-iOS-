import AVFoundation
import Foundation

/// Hosts the MKS50 audio unit in-process inside an AVAudioEngine and wires
/// CoreMIDI to it.
final class AudioHost: ObservableObject {
    @Published private(set) var model: SynthViewModel?
    @Published private(set) var errorMessage: String?

    let midi = MIDIManager()
    private let engine = AVAudioEngine()
    private var unitNode: AVAudioUnit?
    private var observers: [NSObjectProtocol] = []
    /// AVAudioSession activation can block for a while; never do it on main.
    private let sessionQueue = DispatchQueue(label: "mks50.audiosession", qos: .userInitiated)

    init() {
        observeSession()
        sessionQueue.async { [weak self] in
            self?.configureSession()
            DispatchQueue.main.async { self?.loadAudioUnit() }
        }
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    /// Runs on `sessionQueue`.
    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setPreferredIOBufferDuration(AudioHost.preferredBufferDuration(session))
            try session.setActive(true)
        } catch {
            let message = "Audio session: \(error.localizedDescription)"
            DispatchQueue.main.async { [weak self] in self?.errorMessage = message }
        }
    }

    private func observeSession() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                            object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            self?.restart()
        })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange,
                                            object: engine, queue: .main) { [weak self] _ in
            self?.reconnect()
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            self?.sessionQueue.async {
                self?.configureSession()
                DispatchQueue.main.async { self?.reconnect() }
            }
        })
    }

    private func loadAudioUnit() {
        AUAudioUnit.registerSubclass(MKS50AudioUnit.self,
                                     as: MKS50AudioUnit.componentDescription,
                                     name: MKS50AudioUnit.componentName,
                                     version: 0xFFFF_FFFF)

        AVAudioUnit.instantiate(with: MKS50AudioUnit.componentDescription, options: []) { [weak self] node, error in
            DispatchQueue.main.async {
                guard let self else { return }
                guard let node, let unit = node.auAudioUnit as? MKS50AudioUnit else {
                    self.errorMessage = "Could not load synth: \(error?.localizedDescription ?? "unknown error")"
                    return
                }
                self.unitNode = node
                self.engine.attach(node)
                self.connect()
                self.start()

                let model = SynthViewModel(audioUnit: unit)
                self.midi.onChannelMessage = { [weak self, weak unit] status, d1, d2 in
                    self?.noteMIDIActivity(status)
                    unit?.sendMIDI(status, d1, d2)
                }
                self.midi.onClockTempo = { [weak unit] bpm in
                    unit?.engine.clockTempo = bpm
                }
                unit.engine.clockSyncEnabled = UserDefaults.standard.bool(forKey: AudioHost.clockSyncKey)
                model.set(.midiChannel, Float(UserDefaults.standard.integer(forKey: AudioHost.midiChannelKey)))
                self.midi.onSysEx = { [weak model] message in
                    model?.handleSysEx(message)
                }
                self.model = model
                #if DEBUG
                ClockSimulator.shared.runLaunchTest(midi: self.midi, engine: unit.engine)
                #endif
            }
        }
    }

    private func connect() {
        guard let node = unitNode else { return }
        let sampleRate = AVAudioSession.sharedInstance().sampleRate
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate > 0 ? sampleRate : 48000, channels: 2)
        engine.connect(node, to: engine.mainMixerNode, format: format)
    }

    private func start() {
        // Never start an engine without the synth attached (that raises an
        // Objective-C exception); instantiation is asynchronous. Asleep, only
        // coming back to the foreground starts it again.
        guard unitNode != nil, !engine.isRunning, !sleeping else { return }
        do {
            engine.prepare()
            try engine.start()
            errorMessage = nil
        } catch {
            errorMessage = "Audio engine: \(error.localizedDescription)"
        }
    }

    static let backgroundAudioKey = "backgroundAudio"
    /// Audio buffer in frames: smaller = less latency, larger = more
    /// headroom against crackles when the device is busy.
    static let bufferFramesKey = "audioBufferFrames"
    static let bufferOptions = [128, 256, 512, 1024]

    static func preferredBufferDuration(_ session: AVAudioSession) -> TimeInterval {
        let frames = UserDefaults.standard.object(forKey: bufferFramesKey) as? Int ?? 256
        let rate = session.sampleRate > 0 ? session.sampleRate : 48000
        return Double(frames) / rate
    }

    /// Applies a new buffer size (from Settings).
    static func applyBufferSize() {
        DispatchQueue.global(qos: .userInitiated).async {
            let session = AVAudioSession.sharedInstance()
            try? session.setPreferredIOBufferDuration(AudioHost.preferredBufferDuration(session))
        }
    }

    /// Buffer iOS actually granted: frames and milliseconds.
    static var bufferStatus: (frames: Int, milliseconds: Double) {
        let session = AVAudioSession.sharedInstance()
        return (Int((session.ioBufferDuration * session.sampleRate).rounded()), session.ioBufferDuration * 1000)
    }
    /// Minutes of silence in the background before the app goes to sleep
    /// (0 = never).
    static let sleepMinutesKey = "sleepAfterMinutes"
    static let sleepOptions = [0, 5, 10, 30, 60]
    static let clockSyncKey = "midiClockSync"
    /// MIDI receive channel (0 = omni), kept across launches.
    static let midiChannelKey = "midiReceiveChannel"

    /// In the background the engine keeps running by default, so other apps
    /// (sequencers, AUM, DAWs) can play the synth through its virtual MIDI
    /// port. With "Run in Background" switched off it only keeps running
    /// while a MIDI input is enabled. Coming back to the foreground restarts it.
    func sceneDidChange(active: Bool) {
        if active {
            inBackground = false
            sleepTimer?.invalidate()
            sleepTimer = nil
            if sleeping { sleeping = false }
            restart()
            return
        }
        inBackground = true
        let keepRunning = UserDefaults.standard.object(forKey: AudioHost.backgroundAudioKey) as? Bool ?? true
        if !keepRunning && !midi.hasActiveInputs && engine.isRunning {
            model?.panic()
            engine.pause()
        } else {
            startSleepTimer()
        }
    }

    // MARK: Sleep

    private var inBackground = false
    /// Engine paused and audio session released after the idle time; the
    /// app wakes up when it comes back to the foreground.
    private var sleeping = false
    private var sleepTimer: Timer?
    /// System uptime of the last MIDI message other than clock (written by
    /// the CoreMIDI thread).
    private var lastMIDIActivity = ProcessInfo.processInfo.systemUptime
    /// Uptime when the synth was last heard (checked by the timer).
    private var lastSound = ProcessInfo.processInfo.systemUptime

    private var sleepMinutes: Int {
        UserDefaults.standard.object(forKey: AudioHost.sleepMinutesKey) as? Int ?? 10
    }

    private func noteMIDIActivity(_ status: UInt8) {
        // Clock and active sensing keep arriving from idle gear: not activity.
        if status >= 0xF8 && status != 0xFA && status != 0xFB { return }
        lastMIDIActivity = ProcessInfo.processInfo.systemUptime
    }

    private func startSleepTimer() {
        sleepTimer?.invalidate()
        lastSound = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in self?.checkSleep() }
        RunLoop.main.add(timer, forMode: .common)
        sleepTimer = timer
    }

    /// In the background: nothing heard and no MIDI for the set time → sleep.
    private func checkSleep() {
        guard inBackground, !sleeping, engine.isRunning else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let unit = unitNode?.auAudioUnit as? MKS50AudioUnit, !unit.engine.silent { lastSound = now }
        let minutes = sleepMinutes
        guard minutes > 0 else { return }
        let idle = now - max(lastSound, lastMIDIActivity)
        guard idle >= Double(minutes * 60) else { return }
        sleeping = true
        sleepTimer?.invalidate()
        sleepTimer = nil
        model?.panic()
        engine.pause()
        // Releasing the session lets iOS suspend the app (saves battery).
        sessionQueue.async {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func restart() {
        sessionQueue.async { [weak self] in
            try? AVAudioSession.sharedInstance().setActive(true)
            DispatchQueue.main.async { self?.start() }
        }
    }

    /// Route / sample-rate changes stop the engine; rebuild the connection.
    private func reconnect() {
        engine.stop()
        if let node = unitNode {
            engine.disconnectNodeOutput(node)
            connect()
        }
        start()
    }
}
