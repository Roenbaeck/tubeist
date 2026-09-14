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

private actor InterruptedCaptureSession: CaptureSessionDriving {
    private(set) var isRunning = false
    private(set) var hasInputs = false
    private(set) var configurations = 0
    private(set) var starts = 0
    private(set) var stops = 0
    private(set) var detachments = 0
    private var failConfiguration = false
    private var failStart = false

    func configure() throws {
        guard !hasInputs else { throw CaptureSetupError.cannotAddVideoInput }
        hasInputs = true
        configurations += 1
        if failConfiguration {
            failConfiguration = false
            throw CaptureSetupError.cannotAddAudioInput
        }
    }

    func startRunning() {
        starts += 1
        isRunning = !failStart && hasInputs
        failStart = false
    }

    func stopRunning() {
        stops += 1
        isRunning = false
    }
    func detach() {
        hasInputs = false
        detachments += 1
    }

    // The OS changes running state without removing the camera configuration.
    func interrupt() { isRunning = false }
    func failNextConfiguration() { failConfiguration = true }
    func failNextStart() { failStart = true }
}

struct CaptureSessionRecoveryTests {
    @Test func unlockingResumesTheExistingInputsWithoutAddingThemAgain() async throws {
        let driver = InterruptedCaptureSession()
        let controller = SessionController(driver: driver)
        try await controller.startSessions()

        // Repeated locks, including an immediate return, keep the same graph.
        for _ in 0..<3 {
            await driver.interrupt()
            #expect(await driver.hasInputs)
            try await controller.startSessions()
            #expect(await driver.isRunning)
        }
        #expect(await driver.configurations == 1)
        #expect(await driver.starts == 4)
        #expect(await driver.detachments == 0)
    }

    @Test func stoppingAnInterruptedSessionRemovesItsInputsBeforeStartingAgain() async throws {
        let driver = InterruptedCaptureSession()
        let controller = SessionController(driver: driver)
        try await controller.startSessions()
        await driver.interrupt()
        await controller.stopSessions()
        #expect(await !driver.hasInputs)
        #expect(await driver.stops == 1)
        #expect(await driver.detachments == 1)
        try await controller.startSessions()
        #expect(await driver.isRunning)
        #expect(await driver.configurations == 2)
    }

    @Test func settingsCanReconfigureAnInterruptedSession() async throws {
        let driver = InterruptedCaptureSession()
        let controller = SessionController(driver: driver)
        try await controller.startSessions()
        await driver.interrupt()
        try await controller.cycleSessions()
        #expect(await driver.isRunning)
        #expect(await driver.configurations == 2)
        #expect(await driver.detachments == 1)
    }

    @Test func partialConfigurationFailureCanBeRetriedWithoutDuplicateInputs() async throws {
        let driver = InterruptedCaptureSession()
        let controller = SessionController(driver: driver)
        await driver.failNextConfiguration()
        await #expect(throws: CaptureSetupError.cannotAddAudioInput) {
            try await controller.startSessions()
        }
        #expect(await !driver.hasInputs)
        try await controller.startSessions()
        #expect(await driver.isRunning)
        #expect(await driver.configurations == 2)
    }

    @Test func failedResumeCleansUpAndAllowsTheNextAttempt() async throws {
        let driver = InterruptedCaptureSession()
        let controller = SessionController(driver: driver)
        try await controller.startSessions()
        await driver.interrupt()
        await driver.failNextStart()
        await #expect(throws: CaptureSetupError.sessionDidNotStart) {
            try await controller.startSessions()
        }
        #expect(await !driver.hasInputs)
        try await controller.startSessions()
        #expect(await driver.isRunning)
        #expect(await driver.configurations == 2)
    }

    @Test func concurrentResumesDoNotConfigureOrStartTwice() async throws {
        let driver = InterruptedCaptureSession()
        let controller = SessionController(driver: driver)
        try await controller.startSessions()
        await driver.interrupt()
        async let first: Void = controller.startSessions()
        async let second: Void = controller.startSessions()
        _ = try await (first, second)
        #expect(await driver.isRunning)
        #expect(await driver.configurations == 1)
        #expect(await driver.starts == 2)
    }
}
