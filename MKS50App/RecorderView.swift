import SwiftUI

/// Recorder strip shown between the panel and the play bar.
struct RecorderStrip: View {
    @ObservedObject var recorder: RecorderModel
    let model: SynthViewModel
    let onShowRecordings: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            recordButton
            barsSelector
            startSelector
            BigButton(title: "TAILS", icon: "arrow.triangle.2.circlepath",
                      active: recorder.wrapTails) { recorder.wrapTails.toggle() }
                .disabled(recorder.phase != .idle)
            BPMControl(param: model.model(.tempo), model: model)
                .disabled(recorder.phase != .idle)
            Spacer(minLength: 0)
            BigButton(title: "\(recorder.recordings.count)", icon: "waveform") { onShowRecordings() }
                .accessibilityLabel("Recordings")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Theme.panel)
        .overlay(alignment: .top) { Rectangle().fill(Theme.panelEdge).frame(height: 1) }
    }

    private var recordButton: some View {
        Button { recorder.toggleRecord() } label: {
            HStack(spacing: 6) {
                Image(systemName: recorder.phase == .idle ? "record.circle" : "stop.circle.fill")
                    .font(.system(size: 18, weight: .bold))
                Text(statusText)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .frame(minWidth: 64, alignment: .leading)
            }
            .foregroundColor(recorder.phase == .idle ? Theme.label : .white)
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(recorder.phase == .idle ? Theme.cell : Theme.accent.opacity(0.45))
                        if recorder.phase == .recording {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Theme.accent)
                                .frame(width: geo.size.width * CGFloat(recorder.progress))
                        }
                    }
                }
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(recorder.phase == .idle ? "Record loop" : "Stop recording")
    }

    private var statusText: String {
        switch recorder.phase {
        case .idle: return "REC"
        case .armed: return recorder.startOnNote ? "PLAY…" : "WAIT…"
        case .recording: return "\(Int(recorder.progress * 100)) %"
        case .saving: return "SAVE…"
        }
    }

    private var barsSelector: some View {
        StepSelector(label: "BARS",
                     options: RecorderModel.barOptions.map { "\($0)" },
                     value: Binding(get: { Float(recorder.barsIndex) },
                                    set: { recorder.barsIndex = Int($0.rounded()) }),
                     cellWidth: 26)
            .disabled(recorder.phase != .idle)
    }

    private var startSelector: some View {
        StepSelector(label: "START",
                     options: ["NOTE", "BAR"],
                     value: Binding(get: { recorder.startOnNote ? 0 : 1 },
                                    set: { recorder.startOnNote = $0 < 0.5 }),
                     cellWidth: 38)
            .disabled(recorder.phase != .idle)
    }
}

/// Tempo with fine ±1 BPM steps (drives LFO/delay sync and recorder length).
private struct BPMControl: View {
    @ObservedObject var param: ParamModel
    let model: SynthViewModel

    var body: some View {
        HStack(spacing: 4) {
            StepButton(symbol: "minus", label: "Tempo down") { step(-1) }
            VStack(spacing: 0) {
                Text("\(Int(param.value.rounded()) + 40)")
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.display)
                Text("BPM")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(Theme.label)
            }
            .frame(minWidth: 44)
            StepButton(symbol: "plus", label: "Tempo up") { step(1) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tempo")
    }

    private func step(_ delta: Float) {
        model.set(.tempo, param.value.rounded() + delta)
    }
}

/// List of saved WAV loops with preview, share and delete.
struct RecordingsSheet: View {
    @ObservedObject var recorder: RecorderModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Group {
                if recorder.recordings.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "waveform").font(.system(size: 36))
                        Text("No recordings yet").font(.headline)
                        Text("Tap REC, then play: the recorder captures exactly the chosen number of bars and saves a seamless WAV loop.")
                            .font(.footnote)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 360)
                    }
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        Section {
                            ForEach(recorder.recordings, id: \.self) { url in
                                row(url)
                            }
                            .onDelete { offsets in
                                offsets.map { recorder.recordings[$0] }.forEach(recorder.delete)
                            }
                        } footer: {
                            Text("Files are also in the Files app: On My iPhone › MKS50 › Recordings.")
                        }
                    }
                }
            }
            .navigationTitle("Recordings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear { recorder.refreshRecordings() }
        .onDisappear { recorder.stopPreview() }
    }

    private func row(_ url: URL) -> some View {
        HStack(spacing: 12) {
            Button { recorder.togglePreview(url) } label: {
                Image(systemName: recorder.playing == url ? "stop.circle.fill" : "play.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(Theme.accent)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(recorder.playing == url ? "Stop preview" : "Play loop")

            VStack(alignment: .leading, spacing: 2) {
                Text(url.deletingPathExtension().lastPathComponent)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Text(RecorderModel.duration(of: url))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            ShareLink(item: url) {
                Image(systemName: "square.and.arrow.up").font(.system(size: 18))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Share")
        }
        .padding(.vertical, 2)
    }
}
