import AVFoundation
import Testing
@testable import Tubeist

@MainActor
private final class PreviewSessionProbe {
    private var reply: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?

    func pause() async {
        await withCheckedContinuation { continuation in
            reply = continuation
            waiter?.resume()
            waiter = nil
        }
    }

    func waitUntilRequested() async {
        if reply != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func resume() {
        reply?.resume()
        reply = nil
    }
}

@Suite(.serialized) @MainActor
struct CameraPreviewStartupTests {
    @Test func backgroundingInvalidatesAPendingPreviewCreation() async {
        CameraMonitorView.deletePreviewLayer()
        let probe = PreviewSessionProbe()
        let task = Task {
            await CameraMonitorView.createPreviewLayer {
                await probe.pause()
                return AVCaptureSession()
            }
        }
        await probe.waitUntilRequested()
        CameraMonitorView.deletePreviewLayer()
        probe.resume()
        await task.value
        #expect(CameraMonitorView.previewLayer == nil)
    }

    @Test func concurrentCreationDoesNotReplaceTheFirstAttachedLayer() async {
        CameraMonitorView.deletePreviewLayer()
        defer { CameraMonitorView.deletePreviewLayer() }
        let probe = PreviewSessionProbe()
        let task = Task {
            await CameraMonitorView.createPreviewLayer {
                await probe.pause()
                return AVCaptureSession()
            }
        }
        await probe.waitUntilRequested()
        await CameraMonitorView.createPreviewLayer { AVCaptureSession() }
        let first = CameraMonitorView.previewLayer
        probe.resume()
        await task.value
        #expect(first != nil)
        #expect(CameraMonitorView.previewLayer === first)
    }
}
