import CoreAudioKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: SynthViewModel
    @ObservedObject var midi: MIDIManager
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AudioHost.backgroundAudioKey) private var backgroundAudio = true

    private func endpointRow(_ endpoint: MIDIManager.Endpoint, toggle: @escaping (Bool) -> Void) -> some View {
        Button { toggle(!endpoint.enabled) } label: {
            HStack {
                Text(endpoint.name).foregroundColor(.primary)
                Spacer()
                Image(systemName: endpoint.enabled ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(endpoint.enabled ? .accentColor : .secondary)
            }
            .contentShape(Rectangle())
        }
        .accessibilityValue(endpoint.enabled ? "On" : "Off")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("MIDI") {
                    Picker("Receive Channel", selection: Binding(
                        get: { model.intValue(.midiChannel) },
                        set: { model.set(.midiChannel, Float($0)) })) {
                        ForEach(0...16, id: \.self) { ch in
                            Text(ch == 0 ? "Omni" : "Channel \(ch)").tag(ch)
                        }
                    }
                    NavigationLink("Bluetooth MIDI Devices") {
                        BluetoothMIDIView()
                            .navigationTitle("Bluetooth MIDI")
                            .navigationBarTitleDisplayMode(.inline)
                    }
                    Button("Rescan MIDI Ports") { midi.refreshConnections() }
                }

                Section {
                    if midi.sources.isEmpty {
                        Text("No MIDI inputs found").foregroundColor(.secondary)
                    }
                    ForEach(midi.sources) { source in
                        endpointRow(source) { midi.setInput(source.id, enabled: $0) }
                    }
                    HStack {
                        Label("MKS50 Synth (virtual input)", systemImage: "app.connected.to.app.below.fill")
                        Spacer()
                        Image(systemName: "checkmark").foregroundColor(.accentColor)
                    }
                } header: {
                    Text("Inputs")
                } footer: {
                    Text("Tap an input to switch it on or off. Other apps (sequencers, AUM, DAWs) can always play the synth through its virtual input \"MKS50 Synth\" – choose it as MIDI output in the other app.")
                }

                Section {
                    if midi.destinations.isEmpty {
                        Text("No MIDI outputs found").foregroundColor(.secondary)
                    }
                    ForEach(midi.destinations) { dest in
                        endpointRow(dest) { midi.setOutput(dest.id, enabled: $0) }
                    }
                } header: {
                    Text("Outputs (SysEx to hardware MKS-50)")
                } footer: {
                    Text("The paper-plane button sends the current tone to every switched-on output.")
                }

                Section {
                    Toggle("Network MIDI (Wi-Fi)", isOn: $midi.networkEnabled)
                    Toggle("Run in Background", isOn: $backgroundAudio)
                } header: {
                    Text("Connectivity")
                } footer: {
                    Text("Network MIDI makes the iPhone visible to a Mac (Audio MIDI Setup › Network). \"Run in Background\" keeps the synth playing while you use another app, e.g. a sequencer that sends to \"MKS50 Synth\".")
                }

                Section("MIDI CC Assignments") {
                    let mapped = Param.allCases.compactMap { p in model.ccNumber(for: p).map { (p, $0) } }
                    if mapped.isEmpty {
                        Text("None yet – use the slider button in the toolbar to learn.")
                            .foregroundColor(.secondary)
                    }
                    ForEach(mapped.indices, id: \.self) { i in
                        let param = mapped[i].0
                        let cc = mapped[i].1
                        HStack {
                            Text(param.displayName)
                            Spacer()
                            Text("CC \(cc)").foregroundColor(.secondary).monospacedDigit()
                            Button(role: .destructive) { model.removeCC(for: param) } label: {
                                Image(systemName: "minus.circle.fill")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    if !mapped.isEmpty {
                        Button("Remove All", role: .destructive) { model.removeAllCCs() }
                    }
                }

                Section("SysEx") {
                    Text("Incoming MKS-50 / Alpha Juno tone dumps (APR) and parameter changes (IPR), e.g. from a PG-300 or an editor, are applied live. The paper-plane button sends the current tone to every MIDI output.")
                        .font(.footnote)
                }

                Section("About") {
                    LabeledContent("Voices", value: "\(SynthEngine.maxVoices)")
                    LabeledContent("Engine", value: "DCO · HPF · 24 dB VCF · VCA · Chorus")
                    Text("An independent software synthesizer modelled on the Roland MKS-50 / Alpha Juno architecture. Not affiliated with Roland Corporation.")
                        .font(.footnote).foregroundColor(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear { midi.refreshConnections() }
    }
}

/// Apple's built-in Bluetooth LE MIDI pairing UI.
struct BluetoothMIDIView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> CABTMIDICentralViewController {
        CABTMIDICentralViewController()
    }

    func updateUIViewController(_ controller: CABTMIDICentralViewController, context: Context) {}
}
