#if DEBUG
import CoreMIDI
import Foundation

/// Debug only: virtual MIDI clock sources for testing clock sync without
/// hardware (works in the Simulator). Sends Start + 24 ppqn at 120 BPM in
/// the ways USB devices do:
/// - normal: one source, one tick per packet
/// - double: the same clock on two sources (a device with two ports)
/// - bursts: 4 ticks per packet with one time stamp (USB transfers)
/// - start only: Start, then no ticks (a device sending transport only)
final class ClockSimulator: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case normal = "Normal"
        case double = "Two Sources"
        case bursts = "Bursts"
        case startOnly = "Start Only"
        var id: String { rawValue }
    }

    /// One instance for the app's lifetime (its sources must outlive the
    /// Settings sheet).
    static let shared = ClockSimulator()

    @Published var mode: Mode = .normal
    @Published private(set) var running = false

    private var client = MIDIClientRef()
    private var sourceA = MIDIEndpointRef()
    private var sourceB = MIDIEndpointRef()
    private var thread: Thread?
    private let bpm = 120.0

    init() {
        MIDIClientCreateWithBlock("Clock Simulator" as CFString, &client, nil)
        MIDISourceCreateWithProtocol(client, "Clock Sim A" as CFString, ._1_0, &sourceA)
        MIDISourceCreateWithProtocol(client, "Clock Sim B" as CFString, ._1_0, &sourceB)
    }

    deinit {
        stop()
        MIDIClientDispose(client)
    }

    func start() {
        stop()
        running = true
        let mode = self.mode
        let thread = Thread { [weak self] in self?.run(mode) }
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }

    /// Sends Stop and ends the clock.
    func stop() {
        guard let thread else { return }
        thread.cancel()
        self.thread = nil
        running = false
        send([0xFC], to: [sourceA, sourceB])
    }

    // MARK: Sender thread

    private func run(_ mode: Mode) {
        let sources = mode == .double ? [sourceA, sourceB] : [sourceA]
        send([0xFA], to: sources)
        guard mode != .startOnly else { return }
        let tickSeconds = 60 / bpm / 24
        let perPacket = mode == .bursts ? 4 : 1
        var next = mach_absolute_time()
        let interval = UInt64(tickSeconds * Double(perPacket) * ClockSimulator.ticksPerSecond)
        while !Thread.current.isCancelled {
            send([UInt8](repeating: 0xF8, count: perPacket), to: sources)
            next &+= interval
            mach_wait_until(next)
        }
    }

    /// Sends system real-time bytes in one packet (one time stamp: now).
    private func send(_ statuses: [UInt8], to sources: [MIDIEndpointRef]) {
        var list = MIDIEventList()
        var packet = MIDIEventListInit(&list, ._1_0)
        let time = mach_absolute_time()
        for status in statuses {
            var word = UInt32(0x1) << 28 | UInt32(status) << 16
            packet = MIDIEventListAdd(&list, MemoryLayout<MIDIEventList>.size, packet, time, 1, &word)
        }
        for source in sources { MIDIReceivedEventList(source, &list) }
    }

    // MARK: Automated test (launch argument "-clockSim <mode>")

    /// Starts the given mode 2 s after launch (clock sync switched on) and
    /// logs the recorder label and the diagnostics line every half second.
    func runLaunchTest(midi: MIDIManager, engine: SynthEngine) {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-clockSim"), i + 1 < args.count,
              let mode = Mode.allCases.first(where: { $0.rawValue.replacingOccurrences(of: " ", with: "") == args[i + 1] })
        else { return }
        UserDefaults.standard.set(true, forKey: AudioHost.clockSyncKey)
        engine.clockSyncEnabled = true
        let begin = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            self.mode = mode
            self.start()
        }
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { timer in
            let t = Date().timeIntervalSince(begin)
            print(String(format: "CLOCKTEST %@ t=%.1f label=%@ tempo=%.1f diag=%@", mode.rawValue, t,
                         engine.clockStatusLabel, engine.displayTempo, midi.clockDiagnostics))
            if t > 9 { timer.invalidate() }
        }
    }

    // MARK: PO16 controller test (launch argument "-gridTest")

    /// Sends a control change on the PO16 channel of this app from
    /// "Clock Sim A", like the PO16 profiles do.
    func sendCC(_ cc: UInt8, _ value: UInt8, status: UInt8 = GridController.ccStatus) {
        var list = MIDIEventList()
        let packet = MIDIEventListInit(&list, ._1_0)
        var word = UInt32(0x2) << 28 | UInt32(status) << 16 | UInt32(cc) << 8 | UInt32(value)
        MIDIEventListAdd(&list, MemoryLayout<MIDIEventList>.size, packet, 0, 1, &word)
        MIDIReceivedEventList(sourceA, &list)
    }

    /// Cutoff pot far from the value (no pickup), then at it (pickup) and
    /// moved on; ARP and HOLD pots turned right; logs the results.
    func runGridTest(synth: SynthViewModel) {
        guard ProcessInfo.processInfo.arguments.contains("-gridTest") else { return }
        let steps: [(Double, UInt8, UInt8, Bool)] = [
            (3.0, 32, 40, false),                          // cutoff pot at 40: not picked up yet
            (3.4, 32, 125, false), (3.5, 32, 110, false),         // reaches the value: follows
            (3.6, 32, 0, true),                     // other app's channel: ignored
            (3.7, 48, 100, false),                         // ARP pot right: on
            (3.8, 57, 100, false),                         // HOLD pot right: on
            (3.9, 49, 127, false),                         // ARP RATE pot: picks up only near its value
            (4.0, 46, 69, false), (4.1, 46, 100, false),          // DELAY TIME (synced): note value 1/8. -> 1/4.
        ]
        let otherApp: UInt8 = GridController.ccStatus == 0xBF ? 0xBE : 0xBF
        for (t, cc, v, foreign) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) {
                self.sendCC(cc, v, status: foreign ? otherApp : GridController.ccStatus)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) {
            print("GRIDTEST after pot 40: cutoff=\(synth.value(.vcfCutoff))")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.3) {
            print("GRIDTEST after 125, 110: cutoff=\(synth.value(.vcfCutoff)) arpOn=\(synth.intValue(.arpOn)) hold=\(synth.intValue(.arpHold)) arpRate=\(synth.intValue(.arpRate)) delayDivision=\(DelayDivision.names[synth.intValue(.delayDivision)])")
        }
    }

    // MARK: HOLD / play button test (launch argument "-noteTest")

    /// Sends a note on / off on channel 1 from "Clock Sim A" (an external keyboard).
    func sendNote(_ note: UInt8, on: Bool) {
        var list = MIDIEventList()
        let packet = MIDIEventListInit(&list, ._1_0)
        var word = UInt32(0x2) << 28 | UInt32(on ? 0x90 : 0x80) << 16 | UInt32(note) << 8 | UInt32(on ? 100 : 0)
        MIDIEventListAdd(&list, MemoryLayout<MIDIEventList>.size, packet, 0, 1, &word)
        MIDIReceivedEventList(sourceA, &list)
    }

    /// External C4: the play button follows. HOLD on, C-E-G played and
    /// released: still sounding ("C MAJ"). D played: replaces the chord.
    /// D again: stops. Logs each state.
    func runNoteTest(synth: SynthViewModel) {
        guard ProcessInfo.processInfo.arguments.contains("-noteTest") else { return }
        let engine = synth.audioUnit.engine
        func log(_ label: String) {
            print("NOTETEST \(label): sounding=\(engine.heldKeys) readout=\(synth.liveNoteLabel) padNote=\(synth.padNoteName)")
        }
        let steps: [(Double, () -> Void)] = [
            (3.0, { self.sendNote(60, on: true) }), (3.2, { log("C4 down") }),
            (3.3, { self.sendNote(60, on: false) }), (3.5, { log("C4 up, HOLD off") }),
            (3.6, { synth.padLatch = true }),
            (3.7, { self.sendNote(60, on: true); self.sendNote(64, on: true); self.sendNote(67, on: true) }),
            (3.9, { self.sendNote(60, on: false); self.sendNote(64, on: false); self.sendNote(67, on: false) }),
            (4.1, { log("HOLD, C-E-G up") }),
            (4.2, { self.sendNote(62, on: true) }), (4.3, { self.sendNote(62, on: false) }),
            (4.5, { log("D played") }),
            (4.6, { self.sendNote(62, on: true) }), (4.7, { self.sendNote(62, on: false) }),
            (4.9, { log("D again") }),
            (5.0, { synth.padTouchDown() }), (5.1, { synth.padTouchUp() }),
            (5.3, { log("play button tapped") }),
            (5.4, { synth.padLatch = false }), (5.6, { log("HOLD off") }),
        ]
        for (t, action) in steps { DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: action) }
    }

    private static let ticksPerSecond: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return 1e9 * Double(info.denom) / Double(info.numer)
    }()
}
#endif
