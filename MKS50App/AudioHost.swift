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
            try session.setPreferredIOBufferDuration(0.005)
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
                self.midi.onChannelMessage = { [weak unit] status, d1, d2 in
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
        // Objective-C exception); instantiation is asynchronous.
        guard unitNode != nil, !engine.isRunning else { return }
        do {
            engine.prepare()
            try engine.start()
            errorMessage = nil
        } catch {
            errorMessage = "Audio engine: \(error.localizedDescription)"
        }
    }

    static let backgroundAudioKey = "backgroundAudio"
    static let clockSyncKey = "midiClockSync"
    /// MIDI receive channel (0 = omni), kept across launches.
    static let midiChannelKey = "midiReceiveChannel"

    /// In the background the engine keeps running by default, so other apps
    /// (sequencers, AUM, DAWs) can play the synth through its virtual MIDI
    /// port. With "Run in Background" switched off it only keeps running
    /// while a MIDI input is enabled. Coming back to the foreground restarts it.
    func sceneDidChange(active: Bool) {
        if active {
            restart()
            return
        }
        let keepRunning = UserDefaults.standard.object(forKey: AudioHost.backgroundAudioKey) as? Bool ?? true
        if !keepRunning && !midi.hasActiveInputs && engine.isRunning {
            model?.panic()
            engine.pause()
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
