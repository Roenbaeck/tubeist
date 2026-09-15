import SwiftUI
import Metal
import CoreMedia

// Capture reads this before dispatching a frame to the main actor. The view
// owns the gate, so a removed preview never keeps scheduling display work.
final class OutputPreviewGate: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = false
    private var pendingFrame: SendableSampleBuffer?
    private var drainScheduled = false

    func setEnabled(_ enabled: Bool) {
        lock.withLock {
            self.enabled = enabled
            if !enabled { pendingFrame = nil }
        }
    }
    func isEnabled() -> Bool { lock.withLock { enabled } }

    /// A slow UI retains only the newest frame and schedules only one drain.
    /// Capture must never await drawing or accumulate tasks on the main actor.
    func submit(_ frame: SendableSampleBuffer) -> Bool {
        lock.withLock {
            guard enabled else { return false }
            pendingFrame = frame
            guard !drainScheduled else { return false }
            drainScheduled = true
            return true
        }
    }

    func takeLatestFrame() -> SendableSampleBuffer? {
        lock.withLock {
            guard enabled, let frame = pendingFrame else {
                pendingFrame = nil
                drainScheduled = false
                return nil
            }
            pendingFrame = nil
            return frame
        }
    }
}

@MainActor
struct OutputMonitorView: UIViewControllerRepresentable {
    nonisolated static let frameGate = OutputPreviewGate()
    private static weak var controller: OutputMonitorController?

    nonisolated static func enqueue(_ sampleBuffer: SendableSampleBuffer) {
        guard frameGate.submit(sampleBuffer) else { return }
        Task { @MainActor in
            while let frame = frameGate.takeLatestFrame() {
                controller?.enqueue(frame.value)
                await Task.yield()
            }
        }
    }

    static func stop() {
        frameGate.setEnabled(false)
        controller?.stop()
        controller = nil
    }

    func makeUIViewController(context: Context) -> OutputMonitorController {
        let controller = OutputMonitorController()
        controller.loadViewIfNeeded()
        Self.controller = controller
        Self.frameGate.setEnabled(true)
        return controller
    }

    func updateUIViewController(_ controller: OutputMonitorController, context: Context) {}

    static func dismantleUIViewController(_ controller: OutputMonitorController, coordinator: ()) {
        controller.stop()
        if Self.controller === controller {
            Self.frameGate.setEnabled(false)
            Self.controller = nil
        }
    }
}

@MainActor
final class OutputMonitorController: UIViewController {
    private var metalView: MetalOutputView?
    private var errorLabel: UILabel?
    private var preparation: Task<Void, Never>?

    override func loadView() {
        view = UIView()
        view.backgroundColor = .black
        view.isOpaque = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        preparation = Task { [weak self] in
            do {
                let pipeline = try await MetalOutputPipeline.makeForPreview { elapsed in
                    LOG(String(format: "Output preview preparation took %.2f seconds (background queue)", elapsed), level: .warning)
                }
                guard !Task.isCancelled, let self else { return }
                let metalView = MetalOutputView(outputPipeline: pipeline)
                metalView.onFailure = { [weak self] error in self?.show(error) }
                view.addSubview(metalView)
                self.metalView = metalView
                view.setNeedsLayout()
                LOG("Created output monitor", level: .debug)
            } catch {
                guard !Task.isCancelled else { return }
                self?.show(error)
            }
            self?.preparation = nil
        }
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        metalView?.enqueue(sampleBuffer)
    }

    func stop() {
        preparation?.cancel()
        preparation = nil
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
