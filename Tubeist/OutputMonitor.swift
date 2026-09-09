import SwiftUI
import Metal
import CoreMedia

@MainActor
struct OutputMonitorView: UIViewControllerRepresentable {
    private static var frameNumber: UInt32 = 0
    static var isBatterySavingOn = false
    private static weak var controller: OutputMonitorController?

    static func enqueue(_ sampleBuffer: CMSampleBuffer) {
        frameNumber = (frameNumber + 1) % 600
        if isBatterySavingOn && frameNumber % 6 != 0 { return }
        controller?.enqueue(sampleBuffer)
    }

    static func stop() {
        controller?.stop()
        controller = nil
    }

    func makeUIViewController(context: Context) -> OutputMonitorController {
        let controller = OutputMonitorController()
        controller.loadViewIfNeeded()
        Self.controller = controller
        return controller
    }

    func updateUIViewController(_ controller: OutputMonitorController, context: Context) {}

    static func dismantleUIViewController(_ controller: OutputMonitorController, coordinator: ()) {
        controller.stop()
        if Self.controller === controller { Self.controller = nil }
    }
}

@MainActor
final class OutputMonitorController: UIViewController {
    private var metalView: MetalOutputView?
    private var errorLabel: UILabel?

    override func loadView() {
        view = UIView()
        view.backgroundColor = .black
        view.isOpaque = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        do {
            guard let device = MTLCreateSystemDefaultDevice() else { throw OutputPreviewError.unavailable }
            let metalView = try MetalOutputView(previewDevice: device)
            metalView.onFailure = { [weak self] error in self?.show(error) }
            view.addSubview(metalView)
            self.metalView = metalView
        } catch {
            show(error)
        }
        view.setNeedsLayout()
        LOG("Created output monitor", level: .debug)
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        metalView?.enqueue(sampleBuffer)
    }

    func stop() {
        metalView?.stop()
        metalView?.removeFromSuperview()
        metalView = nil
        errorLabel?.removeFromSuperview()
        errorLabel = nil
    }

    private func show(_ error: Error) {
        guard errorLabel == nil else { return }
        metalView?.stop()
        let label = UILabel()
        label.text = "\(error.localizedDescription)\nTap Monitor to return to input."
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = .white
        label.backgroundColor = .black
        view.addSubview(label)
        errorLabel = label
        view.setNeedsLayout()
        LOG(error.localizedDescription, level: .error)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        metalView?.frame = view.bounds
        errorLabel?.frame = view.bounds.insetBy(dx: 24, dy: 24)
    }
}
