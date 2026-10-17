import CoreAudioKit
import SwiftUI

/// Principal class of the AUv3 extension: creates the audio unit for the host
/// and provides its user interface.
public class AudioUnitViewController: AUViewController, AUAudioUnitFactory {
    private var audioUnit: MKS50AudioUnit?
    private var hostingController: UIHostingController<AnyView>?

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.08, green: 0.08, blue: 0.09, alpha: 1)
        preferredContentSize = CGSize(width: 1024, height: 420)
        attachUserInterface()
    }

    public func createAudioUnit(with componentDescription: AudioComponentDescription) throws -> AUAudioUnit {
        let unit = try MKS50AudioUnit(componentDescription: componentDescription, options: [])
        audioUnit = unit
        DispatchQueue.main.async { [weak self] in self?.attachUserInterface() }
        return unit
    }

    private func attachUserInterface() {
        guard let unit = audioUnit, isViewLoaded, hostingController == nil else { return }
        let model = SynthViewModel(audioUnit: unit)
        let root = SynthMainView(model: model) { PluginToolbar(model: model) }
            .preferredColorScheme(.dark)
        let host = UIHostingController(rootView: AnyView(root))
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.backgroundColor = .clear
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
        hostingController = host
    }
}
