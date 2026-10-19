import SwiftUI

/// One stored sequencer pattern: the 16 steps plus length, rate and gates.
struct SeqPattern: Codable, Equatable {
    var steps: [Int]
    var length: Int
    var rate: Int
    var gate: Int
    var gateVar: Int
}

/// 8 pattern slots for live use: save the current sequence with one tap,
/// trigger a slot to switch. While the sequencer runs, the switch happens
/// at the end of the current pattern (on the last step), so the new pattern
/// starts on its first step in time; otherwise it switches at once.
/// Stored on the device (not in sounds), like a pattern memory.
final class PatternBank: ObservableObject {
    static let slotCount = 8
    private static let storageKey = "seqPatternSlots"

    @Published private(set) var slots: [SeqPattern?]
    @Published private(set) var activeSlot: Int?
    @Published private(set) var pendingSlot: Int?
    /// SAVE armed: the next slot tap stores the current pattern.
    @Published var saveArmed = false

    private unowned let model: SynthViewModel
    private var timer: Timer?

    init(model: SynthViewModel) {
        self.model = model
        if let data = UserDefaults.standard.data(forKey: PatternBank.storageKey),
           let stored = try? JSONDecoder().decode([SeqPattern?].self, from: data) {
            slots = Array((stored + Array(repeating: nil, count: PatternBank.slotCount)).prefix(PatternBank.slotCount))
        } else {
            slots = Array(repeating: nil, count: PatternBank.slotCount)
        }
    }

    deinit { timer?.invalidate() }

    /// Slot tap: save when armed (or the slot is empty), else trigger.
    func tap(_ i: Int) {
        if saveArmed || slots[i] == nil {
            save(to: i)
        } else {
            trigger(i)
        }
    }

    func save(to i: Int) {
        slots[i] = currentPattern()
        activeSlot = i
        saveArmed = false
        persist()
        model.flash("Pattern saved to slot \(i + 1)")
    }

    func clear(_ i: Int) {
        slots[i] = nil
        if activeSlot == i { activeSlot = nil }
        if pendingSlot == i { cancelPending() }
        persist()
    }

    func trigger(_ i: Int) {
        guard slots[i] != nil else { return }
        if model.audioUnit.engine.sequencerStep < 0 {
            // Sequencer idle: switch now.
            apply(i)
        } else {
            pendingSlot = i
            startWatching()
        }
    }

    // MARK: Private

    private func currentPattern() -> SeqPattern {
        SeqPattern(steps: model.sequencerSteps(),
                   length: model.intValue(.seqLength),
                   rate: model.intValue(.seqRate),
                   gate: model.intValue(.seqGate),
                   gateVar: model.intValue(.seqGateVar))
    }

    private func apply(_ i: Int) {
        guard let p = slots[i] else { return }
        for (k, v) in p.steps.prefix(StepSequencer.maxSteps).enumerated() {
            model.set(Param.seqStep(k), Float(v))
        }
        model.set(.seqLength, Float(p.length))
        model.set(.seqRate, Float(p.rate))
        model.set(.seqGate, Float(p.gate))
        model.set(.seqGateVar, Float(p.gateVar))
        activeSlot = i
    }

    /// Polls the playing step (about 120 times a second) and swaps the
    /// pattern while the last step plays.
    private func startWatching() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in self?.watch() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func watch() {
        guard let pending = pendingSlot else { return cancelPending() }
        let step = model.audioUnit.engine.sequencerStep
        let last = model.intValue(.seqLength)            // value = length - 1
        if step < 0 || step >= last {
            apply(pending)
            cancelPending()
        }
    }

    private func cancelPending() {
        pendingSlot = nil
        timer?.invalidate()
        timer = nil
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(slots) {
            UserDefaults.standard.set(data, forKey: PatternBank.storageKey)
        }
    }
}

/// SEQ page section: SAVE + 8 slot buttons. Tap a filled slot to trigger it
/// (it blinks until it takes over), an empty one to save into it; holding a
/// slot opens save / clear.
struct PatternBankView: View {
    @ObservedObject var bank: PatternBank

    var body: some View {
        PanelSection(title: "BANK") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    BigButton(title: bank.saveArmed ? "TAP SLOT" : "SAVE", icon: "square.and.arrow.down",
                              active: bank.saveArmed) { bank.saveArmed.toggle() }
                    Text(bank.saveArmed ? "tap a slot to store" : "tap: play · hold: save / clear")
                        .font(Theme.pixel(9, .regular))
                        .foregroundColor(Theme.dimLabel)
                }
                TimelineView(.periodic(from: .now, by: 0.25)) { context in
                    let blink = Int(context.date.timeIntervalSinceReferenceDate * 4) % 2 == 0
                    HStack(spacing: 4) {
                        ForEach(0..<PatternBank.slotCount, id: \.self) { i in
                            slot(i, blink: blink)
                        }
                    }
                }
            }
        }
    }

    private func slot(_ i: Int, blink: Bool) -> some View {
        let filled = bank.slots[i] != nil
        let active = bank.activeSlot == i
        let pending = bank.pendingSlot == i
        let lit = active || (pending && blink)
        return Text("\(i + 1)")
            .font(Theme.pixel(14, .bold))
            .foregroundColor(lit ? Theme.ink : (filled ? Theme.label : Theme.dimLabel))
            .frame(width: 38, height: 40)
            .background(RoundedRectangle(cornerRadius: Theme.corner)
                .fill(lit ? Theme.blue : (filled ? Theme.cell : Theme.cell.opacity(0.4))))
            .overlay(RoundedRectangle(cornerRadius: Theme.corner)
                .stroke(bank.saveArmed ? Theme.red : (filled ? Theme.hairline : .clear), lineWidth: 1))
            .contentShape(Rectangle())
            .onTapGesture { bank.tap(i) }
            .contextMenu {
                Button("Save Current Pattern Here") { bank.save(to: i) }
                if filled {
                    Button("Clear Slot", role: .destructive) { bank.clear(i) }
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Pattern slot \(i + 1)")
            .accessibilityValue(filled ? (active ? "playing" : "stored") : "empty")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { bank.tap(i) }
    }
}
