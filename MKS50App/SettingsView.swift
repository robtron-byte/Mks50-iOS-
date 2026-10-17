import CoreAudioKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: SynthViewModel
    @ObservedObject var midi: MIDIManager
    @Environment(\.dismiss) private var dismiss

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

                Section("Inputs") {
                    if midi.sources.isEmpty {
                        Text("No MIDI inputs found").foregroundColor(.secondary)
                    }
                    ForEach(midi.sources) { Text($0.name) }
                    Text("Other apps can also send to the virtual port \"MKS50 Synth\".")
                        .font(.footnote).foregroundColor(.secondary)
                }

                Section("Outputs (SysEx to hardware MKS-50)") {
                    if midi.destinations.isEmpty {
                        Text("No MIDI outputs found").foregroundColor(.secondary)
                    }
                    ForEach(midi.destinations) { Text($0.name) }
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
