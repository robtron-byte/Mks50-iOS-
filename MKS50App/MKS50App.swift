import SwiftUI
import UniformTypeIdentifiers

@main
struct MKS50App: App {
    @StateObject private var host = AudioHost()

    var body: some Scene {
        WindowGroup {
            RootView(host: host)
                .preferredColorScheme(.dark)
                .statusBarHidden()
                .persistentSystemOverlays(.hidden)
        }
    }
}

struct RootView: View {
    @ObservedObject var host: AudioHost
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        content
            .onChangeCompat(of: scenePhase) { phase in
                switch phase {
                case .active: host.sceneDidChange(active: true)
                case .background: host.sceneDidChange(active: false)
                default: break
                }
            }
    }

    @ViewBuilder private var content: some View {
        if let model = host.model {
            AppMainView(model: model, midi: host.midi)
        } else {
            VStack(spacing: 12) {
                Text("MKS-50")
                    .font(.system(size: 34, weight: .black, design: .rounded))
                    .foregroundColor(Theme.accent)
                if let error = host.errorMessage {
                    Text(error).foregroundColor(Theme.label).multilineTextAlignment(.center)
                } else {
                    ProgressView().tint(Theme.accent)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background.ignoresSafeArea())
        }
    }
}

/// .syx file wrapper for import / export of MKS-50 tone dumps.
struct SysExDocument: FileDocument {
    static let syxType = UTType(filenameExtension: "syx", conformingTo: .data) ?? .data
    static var readableContentTypes: [UTType] { [syxType, .data] }
    static var writableContentTypes: [UTType] { [syxType] }

    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct AppMainView: View {
    let model: SynthViewModel
    @ObservedObject var midi: MIDIManager

    @State private var showSettings = false
    @State private var showImporter = false
    @State private var showExporter = false
    @State private var showSave = false
    @State private var saveName = ""
    @State private var exportDocument = SysExDocument(data: Data())

    private var sysexChannel: Int { max(0, model.intValue(.midiChannel) - 1) }

    var body: some View {
        SynthMainView(model: model) { toolbar }
            .sheet(isPresented: $showSettings) {
                SettingsView(model: model, midi: midi)
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: SysExDocument.readableContentTypes) { result in
                guard case .success(let url) = result else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url) {
                    model.importSysEx(data)
                } else {
                    model.flash("Could not read \(url.lastPathComponent)")
                }
            }
            .fileExporter(isPresented: $showExporter, document: exportDocument,
                          contentType: SysExDocument.syxType,
                          defaultFilename: model.toneName.isEmpty ? "MKS50 Tone" : model.toneName) { result in
                if case .success = result { model.flash("Exported .syx") }
            }
            .alert("Save User Preset", isPresented: $showSave) {
                TextField("Name (max. 10)", text: $saveName)
                Button("Save") { model.saveUserPreset(named: saveName) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Stores the current sound including patch settings and chord memory.")
            }
    }

    private var toolbar: some View {
        AppToolbar(model: model, midi: midi,
                   onSave: {
                       saveName = model.toneName.capitalized
                       showSave = true
                   },
                   onImport: { showImporter = true },
                   onExport: {
                       exportDocument = SysExDocument(data: model.exportSysEx(channel: sysexChannel))
                       showExporter = true
                   },
                   onSend: {
                       midi.sendSysEx([UInt8](model.exportSysEx(channel: sysexChannel)))
                       model.flash("Tone sent to MIDI out")
                   },
                   onSettings: { showSettings = true })
    }
}

/// Top bar of the standalone app. Observes the model on its own so preset /
/// pad changes only redraw this bar, not the whole screen.
struct AppToolbar: View {
    @ObservedObject var model: SynthViewModel
    @ObservedObject var midi: MIDIManager
    let onSave: () -> Void
    let onImport: () -> Void
    let onExport: () -> Void
    let onSend: () -> Void
    let onSettings: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            BrandMark()
            StepButton(symbol: "chevron.left", label: "Previous preset") { model.stepFactoryPreset(-1) }
            presetMenu
            StepButton(symbol: "chevron.right", label: "Next preset") { model.stepFactoryPreset(1) }
            MIDIActivityLED(lastActivity: midi.lastActivity)
            Spacer()
            trailingButtons
        }
        .font(.system(size: 16, weight: .semibold))
        .foregroundColor(Theme.label)
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .background(Theme.panel)
    }

    private func iconButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(minWidth: 36, minHeight: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(label)
    }

    /// Separate builder: a single ViewBuilder block may hold at most 10 views on iOS 16.
    private var trailingButtons: some View {
        HStack(spacing: 6) {
            iconButton("square.and.arrow.down", "Save preset", action: onSave)
            iconButton("folder", "Import SysEx", action: onImport)
            iconButton("square.and.arrow.up", "Export SysEx", action: onExport)
            iconButton("paperplane", "Send tone to hardware", action: onSend)
            CCLearnToggle(learn: model.learn, model: model)
            iconButton("exclamationmark.octagon", "All notes off") { model.panic() }
            iconButton("gearshape", "Settings", action: onSettings)
        }
    }

    private var presetMenu: some View {
        Menu {
            Section("Factory") {
                ForEach(model.factoryPresets, id: \.number) { preset in
                    Button(preset.name) { model.select(preset) }
                }
            }
            if !model.userPresets.isEmpty {
                Section("User") {
                    ForEach(model.userPresets, id: \.number) { preset in
                        Button(preset.name) { model.select(preset) }
                    }
                }
                Menu("Delete User Preset") {
                    ForEach(model.userPresets, id: \.number) { preset in
                        Button(preset.name, role: .destructive) { model.deleteUserPreset(preset) }
                    }
                }
            }
        } label: {
            ToneDisplay(number: presetNumber, name: model.toneName)
        }
    }

    private var presetNumber: String {
        guard let n = model.currentPreset?.number else { return "--" }
        return n >= 0 ? String(format: "%02d", n + 1) : "U"
    }
}

struct MIDIActivityLED: View {
    let lastActivity: Date
    @State private var lit = false

    var body: some View {
        Circle()
            .fill(lit ? Theme.led : Theme.knobBody)
            .frame(width: 8, height: 8)
            .overlay(Circle().stroke(Theme.panelEdge, lineWidth: 1))
            .onChangeCompat(of: lastActivity) { _ in
                lit = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { lit = false }
            }
            .accessibilityHidden(true)
    }
}
