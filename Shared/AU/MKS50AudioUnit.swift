import AudioToolbox
import AVFoundation
import Foundation

extension FourCharCode {
    init(fourCC string: String) {
        var result: FourCharCode = 0
        for scalar in string.unicodeScalars.prefix(4) {
            result = (result << 8) | FourCharCode(scalar.value & 0xFF)
        }
        self = result
    }
}

/// Output buffers used when the host passes `nil` buffer pointers.
private final class RenderBuffers {
    private(set) var left: UnsafeMutablePointer<Float>
    private(set) var right: UnsafeMutablePointer<Float>
    private(set) var capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
        left = .allocate(capacity: capacity)
        right = .allocate(capacity: capacity)
        left.initialize(repeating: 0, count: capacity)
        right.initialize(repeating: 0, count: capacity)
    }

    /// Not real-time safe; only call while render resources are deallocated.
    func ensure(capacity newCapacity: Int) {
        guard newCapacity > capacity else { return }
        left.deallocate()
        right.deallocate()
        capacity = newCapacity
        left = .allocate(capacity: capacity)
        right = .allocate(capacity: capacity)
        left.initialize(repeating: 0, count: capacity)
        right.initialize(repeating: 0, count: capacity)
    }

    deinit {
        left.deallocate()
        right.deallocate()
    }
}

/// Host musical context, captured for the render block (tempo for delay sync).
private final class HostContext {
    var musicalContext: AUHostMusicalContextBlock?
}

/// The MKS-50 synthesizer as an Audio Unit v3 instrument.
///
/// Used both in-process by the standalone app and out-of-process by the
/// AUv3 extension (GarageBand, AUM, Cubasis, Logic for iPad, ...).
final class MKS50AudioUnit: AUAudioUnit {
    static let componentDescription = AudioComponentDescription(
        componentType: kAudioUnitType_MusicDevice,
        componentSubType: FourCharCode(fourCC: "mk50"),
        componentManufacturer: FourCharCode(fourCC: "Rbtn"),
        componentFlags: 0,
        componentFlagsMask: 0)

    static let componentName = "Robtron: MKS50 Synth"
    private static let stateKey = "mks50Tone"

    let engine = SynthEngine()
    private let renderBuffers = RenderBuffers(capacity: 4096)
    private let hostContext = HostContext()
    private var outputBus: AUAudioUnitBus!
    private var outputBusArray: AUAudioUnitBusArray!
    private var tree: AUParameterTree!
    private var presetStorage: AUAudioUnitPreset?
    private var programChangeTimer: DispatchSourceTimer?

    /// Name of the current tone (MKS-50 tone names are 10 characters).
    @objc dynamic var toneName: String = "INIT TONE"

    private lazy var factoryPresetList: [AUAudioUnitPreset] = FactoryPresets.all.enumerated().map { index, tone in
        let preset = AUAudioUnitPreset()
        preset.number = index
        preset.name = tone.name
        return preset
    }

    override init(componentDescription: AudioComponentDescription,
                  options: AudioComponentInstantiationOptions = []) throws {
        try super.init(componentDescription: componentDescription, options: options)

        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_FormatNotSupported))
        }
        outputBus = try AUAudioUnitBus(format: format)
        outputBus.maximumChannelCount = 2
        outputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outputBus])

        tree = MKS50AudioUnit.makeParameterTree()
        let engine = self.engine
        tree.implementorValueObserver = { param, value in
            engine.setParameter(param.address, value)
        }
        tree.implementorValueProvider = { param in
            engine.parameter(param.address)
        }
        tree.implementorStringFromValueCallback = { param, valuePointer in
            let value = valuePointer?.pointee ?? param.value
            return Param(rawValue: Int(param.address))?.string(for: value) ?? "\(Int(value))"
        }

        maximumFramesToRender = 4096
        loadCCMap()
        currentPreset = factoryPresetList.first
        startProgramChangeWatcher()
    }

    deinit {
        programChangeTimer?.cancel()
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
    }

    // MARK: AUAudioUnit overrides

    override var outputBusses: AUAudioUnitBusArray { outputBusArray }

    override var parameterTree: AUParameterTree? {
        get { tree }
        set { /* fixed parameter tree */ }
    }

    override var channelCapabilities: [NSNumber]? { [0, 2] }

    override var audioUnitShortName: String? { "MKS50" }

    override var factoryPresets: [AUAudioUnitPreset]? { factoryPresetList }

    override var supportsUserPresets: Bool { true }

    // MARK: User presets

    /// In-process (the standalone app) the system's user preset store stays
    /// empty, so the app keeps its own: one JSON file per preset in
    /// Application Support. The AUv3 extension keeps the system store, so
    /// presets saved in hosts are unaffected.
    private static let usesOwnPresetStore = Bundle.main.bundleURL.pathExtension != "appex"

    private struct StoredPreset: Codable {
        var number: Int
        var name: String
        var tone: ToneData
    }

    private static var presetDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("UserPresets", isDirectory: true)
    }

    private static func presetFile(_ number: Int) -> URL? {
        presetDirectory?.appendingPathComponent("preset\(-number).json")
    }

    private func storedPresets() -> [StoredPreset] {
        guard let dir = MKS50AudioUnit.presetDirectory,
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return [] }
        return files.filter { $0.pathExtension == "json" }.compactMap {
            guard let data = try? Data(contentsOf: $0) else { return nil }
            return try? JSONDecoder().decode(StoredPreset.self, from: data)
        }
    }

    override var userPresets: [AUAudioUnitPreset] {
        guard MKS50AudioUnit.usesOwnPresetStore else { return super.userPresets }
        return storedPresets()
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { stored in
                let preset = AUAudioUnitPreset()
                preset.number = stored.number
                preset.name = stored.name
                return preset
            }
    }

    override func saveUserPreset(_ userPreset: AUAudioUnitPreset) throws {
        guard MKS50AudioUnit.usesOwnPresetStore else { return try super.saveUserPreset(userPreset) }
        guard userPreset.number < 0, let dir = MKS50AudioUnit.presetDirectory,
              let file = MKS50AudioUnit.presetFile(userPreset.number) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_InvalidPropertyValue))
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stored = StoredPreset(number: userPreset.number, name: userPreset.name, tone: currentToneData)
        willChangeValue(forKey: "userPresets")
        defer { didChangeValue(forKey: "userPresets") }
        try JSONEncoder().encode(stored).write(to: file, options: .atomic)
    }

    override func deleteUserPreset(_ userPreset: AUAudioUnitPreset) throws {
        guard MKS50AudioUnit.usesOwnPresetStore else { return try super.deleteUserPreset(userPreset) }
        guard let file = MKS50AudioUnit.presetFile(userPreset.number) else { return }
        willChangeValue(forKey: "userPresets")
        defer { didChangeValue(forKey: "userPresets") }
        try FileManager.default.removeItem(at: file)
    }

    override func presetState(for userPreset: AUAudioUnitPreset) throws -> [String: Any] {
        guard MKS50AudioUnit.usesOwnPresetStore else { return try super.presetState(for: userPreset) }
        guard let file = MKS50AudioUnit.presetFile(userPreset.number) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_InvalidPropertyValue))
        }
        let stored = try JSONDecoder().decode(StoredPreset.self, from: Data(contentsOf: file))
        var state = fullState ?? [:]
        state[MKS50AudioUnit.stateKey] = try JSONEncoder().encode(stored.tone)
        return state
    }

    override var currentPreset: AUAudioUnitPreset? {
        get { presetStorage }
        set {
            guard let preset = newValue else {
                presetStorage = nil
                return
            }
            if preset.number >= 0 {
                guard preset.number < FactoryPresets.all.count else { return }
                apply(FactoryPresets.all[preset.number])
                presetStorage = preset
            } else if let state = try? presetState(for: preset) {
                fullState = state
                presetStorage = preset
            }
        }
    }

    override var fullState: [String: Any]? {
        get {
            var state = super.fullState ?? [:]
            if let data = try? JSONEncoder().encode(currentToneData) {
                state[MKS50AudioUnit.stateKey] = data
            }
            return state
        }
        set {
            super.fullState = newValue
            if let data = newValue?[MKS50AudioUnit.stateKey] as? Data,
               let tone = try? JSONDecoder().decode(ToneData.self, from: data) {
                apply(tone)
            }
        }
    }

    override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        guard outputBus.format.channelCount <= 2 else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_FormatNotSupported))
        }
        renderBuffers.ensure(capacity: Int(maximumFramesToRender))
        hostContext.musicalContext = musicalContextBlock
        engine.prepare(sampleRate: outputBus.format.sampleRate, maximumFrames: Int(maximumFramesToRender))
    }

    override var internalRenderBlock: AUInternalRenderBlock {
        let engine = self.engine
        let buffers = self.renderBuffers
        let context = self.hostContext

        return { actionFlags, timestamp, frameCount, _, outputData, realtimeEventListHead, _ in
            let abl = UnsafeMutableAudioBufferListPointer(outputData)
            guard abl.count > 0 else { return kAudioUnitErr_FormatNotSupported }
            guard Int(frameCount) <= buffers.capacity else { return kAudioUnitErr_TooManyFramesToProcess }

            for i in 0..<abl.count where abl[i].mData == nil {
                abl[i].mData = UnsafeMutableRawPointer(i % 2 == 0 ? buffers.left : buffers.right)
                abl[i].mDataByteSize = frameCount * UInt32(MemoryLayout<Float>.size)
            }
            let left = abl[0].mData!.assumingMemoryBound(to: Float.self)
            let right = abl.count > 1 ? abl[1].mData!.assumingMemoryBound(to: Float.self) : buffers.right

            engine.drainMIDIQueue()

            // Host tempo / song position for synced delay and LFO.
            var tempo: Double = 0
            var beat: Double = 0
            if let musicalContext = context.musicalContext,
               musicalContext(&tempo, nil, nil, &beat, nil, nil), tempo > 0 {
                engine.beginRenderCycle(tempo: tempo, beatPosition: beat)
            } else {
                engine.beginRenderCycle(tempo: 0, beatPosition: -1)
            }

            // Sample-accurate event handling: render up to each event, apply it.
            let start = AUEventSampleTime(timestamp.pointee.mSampleTime)
            var event = realtimeEventListHead
            var done: AUAudioFrameCount = 0
            var silent = true
            while done < frameCount {
                while let e = event, e.pointee.head.eventSampleTime - start <= AUEventSampleTime(done) {
                    MKS50AudioUnit.handle(e, engine)
                    event = UnsafePointer(e.pointee.head.next)
                }
                var end = frameCount
                if let e = event {
                    end = AUAudioFrameCount(clamping: min(AUEventSampleTime(frameCount), e.pointee.head.eventSampleTime - start))
                }
                let segmentSilent = engine.render(frames: Int(end - done), left: left + Int(done), right: right + Int(done))
                silent = silent && segmentSilent
                done = end
            }
            while let e = event {
                MKS50AudioUnit.handle(e, engine)
                event = UnsafePointer(e.pointee.head.next)
            }
            if silent {
                // Lets hosts skip downstream processing while the synth is idle.
                actionFlags.pointee.insert(.unitRenderAction_OutputIsSilence)
            }
            return noErr
        }
    }

    private static func handle(_ event: UnsafePointer<AURenderEvent>, _ engine: SynthEngine) {
        switch event.pointee.head.eventType {
        case .parameter, .parameterRamp:
            let p = event.pointee.parameter
            engine.setParameter(p.parameterAddress, p.value)
        case .MIDI:
            let m = event.pointee.MIDI
            engine.handleMIDI(m.data.0, m.length > 1 ? m.data.1 : 0, m.length > 2 ? m.data.2 : 0)
        default:
            break
        }
    }

    // MARK: Sound handling

    /// Thread-safe MIDI input for the on-screen keyboard and CoreMIDI.
    func sendMIDI(_ status: UInt8, _ data1: UInt8, _ data2: UInt8) {
        engine.enqueueMIDI(status, data1, data2)
    }

    func value(_ p: Param) -> Int {
        Int(engine.parameter(p.address).rounded())
    }

    func setValue(_ p: Param, _ value: Int) {
        tree.parameter(withAddress: p.address)?.value = AUValue(max(0, min(p.maxValue, value)))
    }

    var currentToneData: ToneData {
        let tone = Param.toneParams.map { value($0) }
        var patch: [Int: Int] = [:]
        for p in Param.patchParams where !p.isDeviceSetting { patch[p.rawValue] = value(p) }
        let chords = (0..<ChordMemory.slots).map { engine.chord($0) }
        return ToneData(name: toneName, tone: tone, patch: patch, chords: chords)
    }

    /// Loads a sound. `includePatch == false` keeps the performance settings
    /// (used for incoming tone SysEx, which carries no patch data).
    func apply(_ tone: ToneData, includePatch: Bool = true) {
        guard tone.tone.count == Param.toneParameterCount else { return }
        for p in Param.toneParams { setValue(p, tone.tone[p.rawValue]) }
        if includePatch {
            // A running arp / sequencer keeps playing its pattern.
            let keepPerformance = value(.arpOn) == 1 || value(.seqOn) == 1
            func applies(_ p: Param) -> Bool {
                !p.isDeviceSetting && !(keepPerformance && p.isPerformance)
            }
            for (key, value) in tone.patch {
                if let p = Param(rawValue: key), applies(p) { setValue(p, value) }
            }
            // Sounds saved before a parameter existed get its default.
            if !tone.patch.isEmpty {
                for p in Param.patchParams where applies(p) && tone.patch[p.rawValue] == nil {
                    setValue(p, p.defaultValue)
                }
            }
        }
        if let chords = tone.chords {
            for (i, chord) in chords.enumerated() { engine.setChord(i, chord) }
        }
        toneName = tone.name
    }

    // MARK: MIDI CC learn

    private static let ccMapKey = "mks50.midiCCMap"

    /// Parameter (raw value) → MIDI CC. A device setting, independent of presets.
    private(set) var ccMap: [Int: Int] = [:]

    func cc(for p: Param) -> Int? { ccMap[p.rawValue] }

    /// One CC controls one parameter and vice versa. The receive channel is
    /// not learnable (a CC on it would cut off its own controller).
    func assignCC(_ cc: Int, to p: Param) {
        guard (0..<120).contains(cc), p != .midiChannel else { return }
        reloadCCMap()
        ccMap = ccMap.filter { $0.value != cc && $0.key != p.rawValue }
        ccMap[p.rawValue] = cc
        applyCCMap()
    }

    func removeCC(for p: Param) {
        reloadCCMap()
        ccMap.removeValue(forKey: p.rawValue)
        applyCCMap()
    }

    func removeAllCCs() {
        ccMap.removeAll()
        applyCCMap()
    }

    private var defaultsObserver: NSObjectProtocol?

    private func loadCCMap() {
        reloadCCMap()
        applyCCMap(save: false)
        // Other instances in the same process (app + plug-in, two plug-ins)
        // share these settings; pick up their changes.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            let before = self.ccMap
            self.reloadCCMap()
            if self.ccMap != before { self.applyCCMap(save: false) }
        }
    }

    private func reloadCCMap() {
        let stored = UserDefaults.standard.dictionary(forKey: MKS50AudioUnit.ccMapKey) as? [String: Int] ?? [:]
        var map: [Int: Int] = [:]
        for (key, cc) in stored {
            if let raw = Int(key), let p = Param(rawValue: raw), p != .midiChannel, (0..<120).contains(cc) {
                map[raw] = cc
            }
        }
        ccMap = map
    }

    /// Mirrors CC-driven parameter changes into the parameter tree so host
    /// automation recording and generic host UIs see them.
    private func publishCCParameterChanges() {
        guard engine.ccParametersDirty else { return }
        engine.ccParametersDirty = false
        for raw in ccMap.keys {
            guard let parameter = tree.parameter(withAddress: AUParameterAddress(raw)) else { continue }
            let value = engine.parameter(AUParameterAddress(raw))
            if parameter.value != value { parameter.setValue(value, originator: nil) }
        }
    }

    private func applyCCMap(save: Bool = true) {
        for cc in 0..<120 { engine.setCCTarget(cc, nil) }
        for (raw, cc) in ccMap { engine.setCCTarget(cc, Param(rawValue: raw)) }
        if save {
            let stored = Dictionary(uniqueKeysWithValues: ccMap.map { (String($0.key), $0.value) })
            UserDefaults.standard.set(stored, forKey: MKS50AudioUnit.ccMapKey)
        }
    }

    private func startProgramChangeWatcher() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.publishCCParameterChanges()
            let program = Int(self.engine.pendingProgramChange)
            guard program >= 0 else { return }
            self.engine.pendingProgramChange = -1
            let presets = self.factoryPresetList
            self.currentPreset = presets[program % presets.count]
        }
        timer.resume()
        programChangeTimer = timer
    }

    // MARK: Parameter tree

    static let sections: [(id: String, name: String, params: [Param])] = [
        ("dco", "DCO", [.dcoRange, .dcoPulse, .dcoSaw, .dcoSub, .dcoSubLevel, .dcoNoiseLevel,
                        .dcoEnvMode, .dcoLfoDepth, .dcoEnvDepth, .dcoAfterDepth, .dcoPwDepth, .dcoPwmRate]),
        ("hpf", "HPF", [.hpfCutoff, .hpfFreq]),
        ("vcf", "VCF", [.vcfEnvMode, .vcfCutoff, .vcfResonance, .vcfLfoDepth, .vcfEnvDepth,
                        .vcfKeyFollow, .vcfAfterDepth]),
        ("vca", "VCA", [.vcaEnvMode, .vcaLevel, .vcaAfterDepth]),
        ("lfo", "LFO", [.lfoRate, .lfoDelay, .lfoWave, .lfoSync, .lfoDivision, .lfoKeySync]),
        ("env", "ENV", [.envT1, .envL1, .envT2, .envL2, .envT3, .envL3, .envT4, .envKeyFollow, .envRetrigger, .envSnap]),
        ("chorus", "Chorus", [.chorus, .chorusRate]),
        ("control", "Control", [.benderRange, .keyMode, .chordIndex, .portaSwitch, .portaTime,
                                .modSensitivity, .volume, .keyShift, .midiChannel]),
        ("extra", "Extra", [.pulseDetune, .pulseSync, .pulseEnvMod, .voiceDrift, .unisonDetune]),
        ("fx", "Effects", [.distMode, .distDrive, .distTone, .distLevel, .distMix, .delayMix, .delayTime, .delayFeedback, .delaySync, .delayDivision, .delayTone,
                           .delayPingPong, .delayMod, .reverbMix, .reverbSize, .reverbDecay, .reverbDamp,
                           .reverbMod, .tempo]),
        ("arp", "Arpeggiator", [.arpOn, .arpMode, .arpRate, .arpOctaves, .arpGate, .arpHold]),
        ("seq", "Sequencer", sequencerParams),
    ]

    private static let sequencerParams: [Param] =
        [.seqOn, .seqStyle, .seqRate, .seqLength, .seqGate, .seqGateVar]
            + (0..<StepSequencer.maxSteps).map { Param.seqStep($0) }

    static func makeParameterTree() -> AUParameterTree {
        let groups = sections.map { section -> AUParameterGroup in
            let children = section.params.map { p -> AUParameter in
                let parameter = AUParameterTree.createParameter(
                    withIdentifier: p.identifier,
                    name: p.displayName,
                    address: p.address,
                    min: 0,
                    max: AUValue(p.maxValue),
                    unit: p.isDiscrete ? .indexed : .generic,
                    unitName: nil,
                    flags: [.flag_IsReadable, .flag_IsWritable],
                    valueStrings: p.valueStrings,
                    dependentParameters: nil)
                parameter.value = AUValue(p.defaultValue)
                return parameter
            }
            return AUParameterTree.createGroup(withIdentifier: section.id, name: section.name, children: children)
        }
        return AUParameterTree.createTree(withChildren: groups)
    }
}
