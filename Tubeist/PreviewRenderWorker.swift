import Foundation

/// A blocking display driver must not occupy the UI or Swift's cooperative
/// executor. Keep one pending frame on a dedicated serial dispatch queue.
final class PreviewRenderWorker<Frame: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.subside.Tubeist.preview-render", qos: .userInitiated)
    private let render: @Sendable (Frame) -> Void
    private var pending: Frame?
    private var running = false
    private var stopped = false

    init(render: @escaping @Sendable (Frame) -> Void) {
        self.render = render
    }

    func submit(_ frame: Frame) {
        let schedule = lock.withLock {
            guard !stopped else { return false }
            pending = frame
            guard !running else { return false }
            running = true
            return true
        }
        if schedule { queue.async { [self] in drain() } }
    }

    /// Does not wait for a drawable or for the GPU. A replacement monitor owns
    /// a new worker, so completion of an old render cannot consume its frames.
    func stop() {
        lock.withLock {
            stopped = true
            pending = nil
        }
    }

    func isStopped() -> Bool { lock.withLock { stopped } }

    private func takeNext() -> Frame? {
        lock.withLock {
            guard !stopped, let frame = pending else {
                running = false
                return nil
            }
            pending = nil
            return frame
        }
    }

    private func drain() {
        while let frame = takeNext() {
            autoreleasepool { render(frame) }
        }
    }
}
