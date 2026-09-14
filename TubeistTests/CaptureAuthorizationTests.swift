import AVFoundation
import Testing
@testable import Tubeist

private actor PermissionProbe {
    private var pending: CaptureMedia?
    private var reply: CheckedContinuation<Bool, Never>?
    private var waiter: CheckedContinuation<CaptureMedia, Never>?

    func request(_ media: CaptureMedia) async -> Bool {
        pending = media
        waiter?.resume(returning: media)
        waiter = nil
        return await withCheckedContinuation { reply = $0 }
    }

    func nextRequest() async -> CaptureMedia {
        if let pending { return pending }
        return await withCheckedContinuation { waiter = $0 }
    }

    func answer(_ granted: Bool) {
        pending = nil
        reply?.resume(returning: granted)
        reply = nil
    }
}

struct CaptureAuthorizationTests {
    @Test func waitsForCameraThenMicrophoneBeforeCompleting() async throws {
        let probe = PermissionProbe()
        let task = Task {
            try await CaptureAuthorization.ensureAccess(status: { _ in .notDetermined }, request: { await probe.request($0) })
        }
        #expect(await probe.nextRequest() == .camera)
        await probe.answer(true)
        #expect(await probe.nextRequest() == .microphone)
        await probe.answer(true)
        try await task.value
    }

    @Test(arguments: CaptureMedia.allCases)
    func deniedAccessFailsBeforeCaptureCanStart(_ denied: CaptureMedia) async {
        await #expect(throws: denied.permissionError) {
            try await CaptureAuthorization.ensureAccess(status: { $0 == denied ? .denied : .authorized }, request: { _ in
                Issue.record("An already-decided permission must not be requested again")
                return true
            })
        }
    }

    @Test func cancellationDuringAPermissionPromptPreventsFurtherStartup() async {
        let probe = PermissionProbe()
        let task = Task {
            try await CaptureAuthorization.ensureAccess(status: { _ in .notDetermined }, request: { await probe.request($0) })
        }
        #expect(await probe.nextRequest() == .camera)
        task.cancel()
        await probe.answer(true)
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
