import CoreMIDI
import Foundation

/// CoreMIDI input/output for the standalone app.
///
/// - Connects to the enabled MIDI sources (USB, network, Bluetooth LE, other
///   apps' virtual outputs); all are enabled until switched off in Settings
/// - Publishes a virtual destination so other apps can play the synth
/// - Optional network MIDI session (Wi-Fi, e.g. from a Mac)
/// - Reassembles SysEx (UMP SysEx7) for MKS-50 tone dumps / parameter changes
/// - Sends tone dumps to a real MKS-50 via all MIDI destinations
final class MIDIManager: ObservableObject {
    struct Endpoint: Identifiable, Hashable {
        let id: MIDIUniqueID
        let name: String
        var enabled: Bool
    }

    @Published private(set) var sources: [Endpoint] = []
    @Published private(set) var destinations: [Endpoint] = []

    private static let disabledInputsKey = "midiDisabledInputs"
    private static let disabledOutputsKey = "midiDisabledOutputs"
    private static let networkKey = "midiNetworkSession"

    /// Inputs / outputs switched off by the user (by unique ID, so they stay
    /// off across reconnects); everything new is on.
    private var disabledInputs: Set<MIDIUniqueID> {
        didSet { UserDefaults.standard.set(Array(disabledInputs), forKey: MIDIManager.disabledInputsKey) }
    }
    private var disabledOutputs: Set<MIDIUniqueID> {
        didSet { UserDefaults.standard.set(Array(disabledOutputs), forKey: MIDIManager.disabledOutputsKey) }
    }

    /// Network MIDI (Wi-Fi) session, visible to Macs in "Audio MIDI Setup".
    @Published var networkEnabled: Bool {
        didSet {
            UserDefaults.standard.set(networkEnabled, forKey: MIDIManager.networkKey)
            applyNetworkSession()
        }
    }

    /// Number of enabled sources that are connected.
    var hasActiveInputs: Bool { sources.contains { $0.enabled } }
    @Published private(set) var lastActivity = Date.distantPast

    /// Called on the CoreMIDI thread for channel voice messages and for MIDI
    /// clock / transport (F8, FA, FB, FC, F2).
    var onChannelMessage: ((UInt8, UInt8, UInt8) -> Void)?
    /// Called on the CoreMIDI thread for every control change (status, CC,
    /// value) before it reaches the synth; returning true consumes it (Grid
    /// PO16 controller, see GridController).
    var onControllerCC: ((UInt8, UInt8, UInt8) -> Bool)?
    /// Called on the CoreMIDI thread with the tempo measured from MIDI clock.
    var onClockTempo: ((Double) -> Void)?
    /// Main thread: tempo and running state of the incoming MIDI clock.
    @Published private(set) var clockTempo: Double = 0
    @Published private(set) var clockRunning = false
    /// Transport state on the MIDI thread (mirrored to `clockRunning`).
    private var clockRunningFlag = false
    /// Stop received: ticks alone do not count as running until Start / Continue.
    private var stoppedBySource = false

    // Clock source lock (CoreMIDI thread): clock and transport are taken
    // from one source at a time. A USB device often sends its clock on
    // several ports (or USB plus Bluetooth / network); doubled ticks would
    // run the beat clock at twice the speed and spoil the tempo measurement.
    private var clockSource: Int = 0
    private var clockSourceTime: UInt64 = 0

    // Diagnostics (Settings › Clock). The MIDI thread only counts; a main
    // thread timer turns the counts into a line once a second, so it also
    // updates when nothing arrives (e.g. Start without clock: 0 ticks/s).
    private var diagTicks = 0          // running totals (MIDI thread)
    private var diagIgnored = 0
    /// Last transport message: 0 none, else 0xFA / 0xFB / 0xFC.
    private var diagLastTransport: UInt8 = 0
    private var diagReadTicks = 0      // totals at the last update (main thread)
    private var diagReadIgnored = 0
    private var diagTimer: Timer?
    /// Main thread: what arrives, e.g. "Digitakt · 48 ticks/s · Start".
    @Published private(set) var clockDiagnostics = ""

    // Clock tempo measurement (CoreMIDI thread only).
    // Single ticks jitter by a millisecond or more (USB, Bluetooth, app
    // timing), so the tempo is measured over the last 4 beats, smoothed,
    // and only published when it really moves (hysteresis).
    private var lastTickTime: UInt64 = 0
    private var tickTimes = [UInt64](repeating: 0, count: 97)   // 96 ticks = 4 beats
    private var tickIndex = 0
    private var tickCount = 0
    private var smoothedTempo: Double = 0
    /// Ticks in a row whose short-term tempo is far from the smoothed one.
    private var tempoChangeTicks = 0
    private var lastPublishedTempo: Double = 0
    private static let ticksPerSecond: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return 1e9 * Double(info.denom) / Double(info.numer)
    }()
    /// Called on the main thread with complete F0...F7 messages.
    var onSysEx: (([UInt8]) -> Void)?

    private var client = MIDIClientRef()
    private var inputPort = MIDIPortRef()
    private var outputPort = MIDIPortRef()
    private var virtualDestination = MIDIEndpointRef()
    private var connected: [MIDIEndpointRef] = []
    /// One reassembly buffer per input (hardware ports / virtual port), so
    /// interleaved SysEx from different callbacks never mixes.
    private var sysexBuffers: [[UInt8]] = [[], []]
    private let sysexLimit = 65536
    private var activityPending = false

    init() {
        let defaults = UserDefaults.standard
        disabledInputs = Set((defaults.array(forKey: MIDIManager.disabledInputsKey) as? [Int] ?? []).map { MIDIUniqueID($0) })
        disabledOutputs = Set((defaults.array(forKey: MIDIManager.disabledOutputsKey) as? [Int] ?? []).map { MIDIUniqueID($0) })
        networkEnabled = defaults.bool(forKey: MIDIManager.networkKey)
        applyNetworkSession()

        let status = MIDIClientCreateWithBlock("MKS50 Synth" as CFString, &client) { [weak self] notification in
            guard notification.pointee.messageID == .msgSetupChanged else { return }
            DispatchQueue.main.async { self?.refreshConnections() }
        }
        guard status == noErr else { return }

        MIDIInputPortCreateWithProtocol(client, "Input" as CFString, ._1_0, &inputPort) { [weak self] list, refCon in
            // The connection refCon carries the source's unique ID.
            self?.receive(list, input: 0, source: Int(bitPattern: refCon))
        }
        MIDIOutputPortCreate(client, "Output" as CFString, &outputPort)
        MIDIDestinationCreateWithProtocol(client, "MKS50 Synth" as CFString, ._1_0, &virtualDestination) { [weak self] list, _ in
            self?.receive(list, input: 1, source: MIDIManager.virtualSourceID)
        }
        refreshConnections()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.updateDiagnostics() }
        RunLoop.main.add(timer, forMode: .common)
        diagTimer = timer
    }

    deinit {
        diagTimer?.invalidate()
        MIDIClientDispose(client)
    }

    // MARK: Connections

    func refreshConnections() {
        for source in connected { MIDIPortDisconnectSource(inputPort, source) }
        connected.removeAll()

        var foundSources: [Endpoint] = []
        for i in 0..<MIDIGetNumberOfSources() {
            let source = MIDIGetSource(i)
            guard source != 0 else { continue }
            let id = uniqueID(source)
            let enabled = !disabledInputs.contains(id)
            // refCon: the unique ID (never 0 for a real endpoint, so it is
            // told apart from the virtual input).
            let refCon = UnsafeMutableRawPointer(bitPattern: Int(id) == 0 ? -2 : Int(id))
            if enabled, MIDIPortConnectSource(inputPort, source, refCon) == noErr {
                connected.append(source)
            }
            foundSources.append(Endpoint(id: id, name: displayName(source), enabled: enabled))
        }
        var foundDestinations: [Endpoint] = []
        for i in 0..<MIDIGetNumberOfDestinations() {
            let dest = MIDIGetDestination(i)
            guard dest != 0, dest != virtualDestination else { continue }
            let id = uniqueID(dest)
            foundDestinations.append(Endpoint(id: id, name: displayName(dest), enabled: !disabledOutputs.contains(id)))
        }
        sources = foundSources
        destinations = foundDestinations
    }

    /// Settings: switch an input on / off.
    func setInput(_ id: MIDIUniqueID, enabled: Bool) {
        if enabled { disabledInputs.remove(id) } else { disabledInputs.insert(id) }
        refreshConnections()
    }

    /// Settings: switch an output (SysEx to hardware) on / off.
    func setOutput(_ id: MIDIUniqueID, enabled: Bool) {
        if enabled { disabledOutputs.remove(id) } else { disabledOutputs.insert(id) }
        refreshConnections()
    }

    private func applyNetworkSession() {
        let session = MIDINetworkSession.default()
        session.isEnabled = networkEnabled
        session.connectionPolicy = networkEnabled ? .anyone : .noOne
    }

    private func displayName(_ endpoint: MIDIEndpointRef) -> String {
        var name: Unmanaged<CFString>?
        if MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &name) == noErr, let name {
            return name.takeRetainedValue() as String
        }
        return "MIDI Device"
    }

    private func uniqueID(_ endpoint: MIDIEndpointRef) -> MIDIUniqueID {
        var id: MIDIUniqueID = 0
        MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &id)
        return id
    }

    // MARK: Input (CoreMIDI thread)

    /// Pseudo source ID of the virtual input (other apps sending to "MKS50 Synth").
    private static let virtualSourceID = -1

    private func receive(_ list: UnsafePointer<MIDIEventList>, input: Int, source: Int) {
        for packet in list.unsafeSequence() {
            let count = min(Int(packet.pointee.wordCount), 64)
            // Read only the valid words in place (the last packet of a list is
            // shorter than the full 64-word tuple).
            guard let wordsOffset = MemoryLayout<MIDIEventPacket>.offset(of: \.words) else { continue }
            let base = UnsafeRawPointer(packet).advanced(by: wordsOffset)
            let words = base.assumingMemoryBound(to: UInt32.self)
            do {
                var i = 0
                while i < count {
                    let word = words[i]
                    let type = word >> 28
                    switch type {
                    case 0x2:
                        // MIDI 1.0 channel voice message
                        let status = UInt8((word >> 16) & 0xFF)
                        let d1 = UInt8((word >> 8) & 0x7F), d2 = UInt8(word & 0x7F)
                        if status & 0xF0 == 0xB0, onControllerCC?(status, d1, d2) == true {
                            noteActivity()
                            break
                        }
                        onChannelMessage?(status, d1, d2)
                        noteActivity()
                    case 0x1:
                        // System real time / common: MIDI clock and transport.
                        let status = UInt8((word >> 16) & 0xFF)
                        handleSystem(status, UInt8((word >> 8) & 0x7F), UInt8(word & 0x7F),
                                     time: packet.pointee.timeStamp, source: source)
                    case 0x3 where i + 1 < count:
                        handleSysEx7(word, words[i + 1], input: input)
                    default:
                        break
                    }
                    i += MIDIManager.wordCount(forMessageType: type)
                }
            }
        }
    }

    /// Tempo of the last `ticks` clock ticks (BPM), 0 if not enough ticks.
    private func tempo(overTicks ticks: Int) -> Double {
        let n = min(ticks, tickCount - 1)
        guard n >= 1 else { return 0 }
        let newest = tickTimes[(tickIndex + tickTimes.count - 1) % tickTimes.count]
        let oldest = tickTimes[(tickIndex + tickTimes.count - 1 - n) % tickTimes.count]
        guard newest > oldest else { return 0 }
        let seconds = Double(newest - oldest) / MIDIManager.ticksPerSecond
        return 60 * Double(n) / (24 * seconds)
    }

    private func measureTempo(tick now: UInt64) {
        tickTimes[tickIndex] = now
        tickIndex = (tickIndex + 1) % tickTimes.count
        tickCount = min(tickCount + 1, tickTimes.count)

        guard tickCount > 12 else { return }        // wait for half a beat
        let long = tempo(overTicks: tickTimes.count - 1)
        let short = tempo(overTicks: 12)            // half a beat
        guard long > 20 && long < 400 else { return }

        if smoothedTempo <= 0 {
            smoothedTempo = long
        } else if abs(short - smoothedTempo) / smoothedTempo > 0.04 {
            // A real tempo change: after half a beat, follow it at once.
            tempoChangeTicks += 1
            if tempoChangeTicks >= 12 {
                let keep = min(tickCount, 13)
                tickCount = keep                    // forget the old tempo
                smoothedTempo = tempo(overTicks: keep - 1)
                tempoChangeTicks = 0
            }
        } else {
            tempoChangeTicks = 0
            smoothedTempo += 0.08 * (long - smoothedTempo)
        }

        // Most clocks run at whole BPM values: snap to them, else 0.1 BPM,
        // and only move the shown tempo when it changes clearly.
        let nearest = smoothedTempo.rounded()
        let shown = abs(smoothedTempo - nearest) < 0.12 ? nearest : (smoothedTempo * 10).rounded() / 10
        guard lastPublishedTempo == 0 || abs(smoothedTempo - lastPublishedTempo) > 0.08,
              shown != lastPublishedTempo else { return }
        lastPublishedTempo = shown
        onClockTempo?(shown)
        DispatchQueue.main.async { [weak self] in self?.clockTempo = shown }
    }

    private func handleSystem(_ status: UInt8, _ d1: UInt8, _ d2: UInt8, time: MIDITimeStamp, source: Int) {
        guard status == 0xF8 || status == 0xFA || status == 0xFB || status == 0xFC || status == 0xF2 else {
            return                          // other system messages are not used
        }
        // One clock source at a time: a second source is ignored while the
        // current one sent anything within the last half second.
        let arrival = mach_absolute_time()
        if source != clockSource {
            let stale = clockSourceTime == 0
                || Double(arrival &- clockSourceTime) / MIDIManager.ticksPerSecond > 0.5
            guard stale else {
                diagIgnored += 1
                return
            }
            clockSource = source
        }
        clockSourceTime = arrival

        switch status {
        case 0xF8:
            diagTicks += 1
            // Packet time stamp of the device (USB / Bluetooth), else now.
            // Ticks from one USB transfer can share a time stamp; only a
            // real gap or a jump backwards restarts the measurement.
            var now = time != 0 ? time : arrival
            if lastTickTime != 0 {
                let back = now < lastTickTime ? Double(lastTickTime - now) / MIDIManager.ticksPerSecond : 0
                let gap = now > lastTickTime ? Double(now - lastTickTime) / MIDIManager.ticksPerSecond : 0
                if back > 0.005 || gap > 0.25 {
                    tickCount = 0               // clock restarted
                    lastPublishedTempo = 0      // publish the new measurement
                } else if now <= lastTickTime {
                    now = lastTickTime &+ 1     // same transfer: keep the order
                }
            }
            lastTickTime = now
            measureTempo(tick: now)
            if !clockRunningFlag && !stoppedBySource {
                // Ticks without Start (source already playing): running.
                clockRunningFlag = true
                DispatchQueue.main.async { [weak self] in self?.clockRunning = true }
            }
        case 0xFA, 0xFB:
            diagLastTransport = status
            clockRunningFlag = true
            stoppedBySource = false
            DispatchQueue.main.async { [weak self] in self?.clockRunning = true }
        case 0xFC:
            diagLastTransport = status
            lastTickTime = 0
            tickCount = 0
            tempoChangeTicks = 0
            lastPublishedTempo = 0
            clockRunningFlag = false
            stoppedBySource = true
            DispatchQueue.main.async { [weak self] in self?.clockRunning = false }
        default:
            break                           // F2 song position
        }
        onChannelMessage?(status, d1, d2)
    }

    /// Main thread, once a second: clock source name, ticks per second (24
    /// per beat: 48/s at 120 BPM) and the last transport message. Empty
    /// until the first clock / transport message arrives.
    private func updateDiagnostics() {
        // Racy reads of the MIDI thread's counters are fine for a display.
        let ticks = diagTicks, ignoredTotal = diagIgnored
        let rate = ticks - diagReadTicks
        let ignored = ignoredTotal - diagReadIgnored
        diagReadTicks = ticks
        diagReadIgnored = ignoredTotal
        let source = clockSource
        guard source != 0 else { return }                   // nothing received yet
        let name = source == MIDIManager.virtualSourceID
            ? "MKS50 Synth (virtual)"
            : sources.first { Int($0.id) == source }?.name ?? "MIDI"
        let transport: String
        switch diagLastTransport {
        case 0xFA: transport = "Start"
        case 0xFB: transport = "Continue"
        case 0xFC: transport = "Stop"
        default: transport = "no Start / Stop yet"
        }
        var text = "\(name) · \(rate) ticks/s · \(transport)"
        if ignored > 0 { text += " · \(ignored) from other inputs ignored" }
        if clockDiagnostics != text { clockDiagnostics = text }
    }

    private static func wordCount(forMessageType type: UInt32) -> Int {
        switch type {
        case 0x0, 0x1, 0x2, 0x6, 0x7: return 1
        case 0x3, 0x4, 0x8, 0x9, 0xA: return 2
        case 0xB, 0xC: return 3
        default: return 4
        }
    }

    private func handleSysEx7(_ w0: UInt32, _ w1: UInt32, input: Int) {
        let status = (w0 >> 20) & 0xF
        let length = Int((w0 >> 16) & 0xF)
        let all: [UInt8] = [UInt8((w0 >> 8) & 0xFF), UInt8(w0 & 0xFF),
                            UInt8((w1 >> 24) & 0xFF), UInt8((w1 >> 16) & 0xFF),
                            UInt8((w1 >> 8) & 0xFF), UInt8(w1 & 0xFF)]
        let bytes = all.prefix(min(length, 6))

        switch status {
        case 0x0: // complete in one packet
            var message: [UInt8] = [0xF0]
            message.append(contentsOf: bytes)
            message.append(0xF7)
            emitSysEx(message)
        case 0x1: // start
            sysexBuffers[input] = [0xF0]
            sysexBuffers[input].append(contentsOf: bytes)
        case 0x2: // continue
            if !sysexBuffers[input].isEmpty, sysexBuffers[input].count < sysexLimit { sysexBuffers[input].append(contentsOf: bytes) }
        case 0x3: // end
            if !sysexBuffers[input].isEmpty {
                sysexBuffers[input].append(contentsOf: bytes)
                sysexBuffers[input].append(0xF7)
                emitSysEx(sysexBuffers[input])
            }
            sysexBuffers[input].removeAll(keepingCapacity: true)
        default:
            break
        }
    }

    private func emitSysEx(_ message: [UInt8]) {
        DispatchQueue.main.async { [weak self] in self?.onSysEx?(message) }
        noteActivity()
    }

    /// Called from CoreMIDI threads; all state is touched on main only.
    private func noteActivity() {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.activityPending else { return }
            self.activityPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.activityPending = false
                self?.lastActivity = Date()
            }
        }
    }

    // MARK: Output

    /// Sends a complete F0 ... F7 message to all destinations.
    func sendSysEx(_ message: [UInt8]) {
        guard message.count >= 2, message.first == 0xF0, message.last == 0xF7 else { return }
        let payload = Array(message.dropFirst().dropLast())

        var words: [UInt32] = []
        var offset = 0
        repeat {
            let chunk = Array(payload[offset..<min(offset + 6, payload.count)])
            let isFirst = offset == 0
            let isLast = offset + 6 >= payload.count
            let status: UInt32 = isFirst && isLast ? 0x0 : isFirst ? 0x1 : isLast ? 0x3 : 0x2
            var b = chunk.map { UInt32($0) }
            while b.count < 6 { b.append(0) }
            words.append(0x3000_0000 | status << 20 | UInt32(chunk.count) << 16 | b[0] << 8 | b[1])
            words.append(b[2] << 24 | b[3] << 16 | b[4] << 8 | b[5])
            offset += 6
        } while offset < payload.count

        let byteCount = MemoryLayout<MIDIEventList>.size + words.count * 4 + 256
        let raw = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 8)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: MIDIEventList.self, capacity: 1)
        var packet: UnsafeMutablePointer<MIDIEventPacket>? = MIDIEventListInit(list, ._1_0)
        for i in stride(from: 0, to: words.count, by: 2) {
            guard let current = packet else { return }
            let pair = [words[i], words[i + 1]]
            packet = pair.withUnsafeBufferPointer {
                MIDIEventListAdd(list, byteCount, current, 0, 2, $0.baseAddress!)
            }
        }

        for i in 0..<MIDIGetNumberOfDestinations() {
            let dest = MIDIGetDestination(i)
            guard dest != 0, dest != virtualDestination, !disabledOutputs.contains(uniqueID(dest)) else { continue }
            MIDISendEventList(outputPort, dest, list)
        }
    }
}
