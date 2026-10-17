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

    init() {
        configureSession()
        observeSession()
        loadAudioUnit()
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setPreferredIOBufferDuration(0.005)
            try session.setActive(true)
        } catch {
            errorMessage = "Audio session: \(error.localizedDescription)"
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
            self?.configureSession()
            self?.reconnect()
        })
    }

    private func loadAudioUnit() {
        AUAudioUnit.registerSubclass(MKS50AudioUnit.self,
                                     as: MKS50AudioUnit.componentDescription,
                                     name: MKS50AudioUnit.componentName,
                                     version: 0x0001_0000)

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

    /// Saves battery: in the background the engine only keeps running when
    /// a MIDI source is connected (or another app can reach the virtual port
    /// while we are visible). Coming back to the foreground restarts it.
    func sceneDidChange(active: Bool) {
        if active {
            restart()
        } else if midi.sources.isEmpty && engine.isRunning {
            model?.panic()
            engine.pause()
        }
    }

    private func restart() {
        try? AVAudioSession.sharedInstance().setActive(true)
        start()
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
