import Foundation
import Testing
@testable import Tubeist

@MainActor
struct StreamKeySetupTests {
    @Test func progressAndDuplicateGuardLastUntilConfirmation() async throws {
        let setup = StreamKeySetup()
        let gate = KeySetupGate()
        var starts = 0
        let taskPending = setup.begin(title: "Planned stream", operation: {
            await gate.wait()
        }, start: {
            #expect(!setup.isActive)
            starts += 1
        }, failure: { _ in Issue.record("Unexpected setup failure") })
        let task = try #require(taskPending)
        #expect(setup.isActive) // Reserved synchronously, before the task runs.
        await gate.waitUntilEntered()
        for _ in 0..<20 { await Task.yield() }
        #expect(setup.title == "Planned stream")
        #expect(starts == 0)
        #expect(setup.begin(title: "Duplicate", operation: {
            Issue.record("Duplicate move must not run")
        }, start: {}, failure: { _ in }) == nil)
        await gate.release()
        await task.value
        #expect(!setup.isActive)
        #expect(starts == 1)
    }

    @Test func failureClearsProgressAndAllowsRetryWithoutStarting() async throws {
        let setup = StreamKeySetup()
        var failures = 0
        var starts = 0
        let taskPending = setup.begin(title: "Planned stream", operation: {
            throw YouTubeError.keyMoveUnconfirmed("Planned stream")
        }, start: { starts += 1 }, failure: { error in
            #expect(!setup.isActive)
            #expect(error as? YouTubeError == .keyMoveUnconfirmed("Planned stream"))
            failures += 1
        })
        let task = try #require(taskPending)
        await task.value
        #expect(!setup.isActive)
        #expect(failures == 1)
        #expect(starts == 0)
        let retryPending = setup.begin(title: "Retry", operation: {},
            start: { starts += 1 }, failure: { _ in Issue.record("Unexpected retry failure") })
        let retry = try #require(retryPending)
        await retry.value
        #expect(starts == 1)
    }

    @Test func cancelledCompletionCannotStartOrClearANewerSetup() async throws {
        let setup = StreamKeySetup()
        let oldGate = KeySetupGate(), newGate = KeySetupGate()
        var starts = 0
        let oldPending = setup.begin(title: "Old", operation: { await oldGate.wait() },
            start: { Issue.record("Cancelled setup must not start") },
            failure: { _ in Issue.record("Cancellation must stay quiet") })
        let old = try #require(oldPending)
        await oldGate.waitUntilEntered()
        setup.cancel()
        #expect(!setup.isActive)
        let currentPending = setup.begin(title: "Current", operation: { await newGate.wait() },
            start: { starts += 1 }, failure: { _ in Issue.record("Unexpected failure") })
        let current = try #require(currentPending)
        await newGate.waitUntilEntered()
        await oldGate.release() // Deliberately completes despite cancellation.
        await old.value
        #expect(setup.title == "Current")
        #expect(starts == 0)
        await newGate.release()
        await current.value
        #expect(starts == 1)
        #expect(!setup.isActive)
    }

    @Test func pendingSetupRejectsPhoneAndWatchStartsBeforePreparingMedia() async throws {
        let app = AppState()
        app.isAppInitialization = false
        let actor = StreamingActor()
        await actor.setAppState(app)
        let gate = KeySetupGate()
        let taskPending = app.streamKeySetup.begin(title: "Planned stream",
            operation: { await gate.wait() }, start: {}, failure: { _ in })
        let task = try #require(taskPending)
        await gate.waitUntilEntered()
        await #expect(throws: StreamStartError.keySetupInProgress) { try await actor.beginPreparing() }
        #expect(await actor.sessionState() == .idle)
        #expect(app.activitySession == nil)
        let manager = WatchSessionManager(isAppActive: { true }, startStream: { _ in
            Issue.record("Watch must not bypass a pending key setup")
        })
        manager.appState = app
        #expect(!manager.currentSnapshot(appState: app).isAppActive)
        let reply = await manager.handle(rawCommand: WatchCommand.start.rawValue)
        #expect(!reply.success)
        #expect(reply.message == StreamStartError.keySetupInProgress.localizedDescription)
        await gate.release()
        await task.value
        #expect(manager.currentSnapshot(appState: app).isAppActive)
        try await actor.beginPreparing()
        #expect(await actor.sessionState() == .preparing)
    }
}

private actor KeySetupGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var entered = false
    private var entryWaiter: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            entered = true
            entryWaiter?.resume()
            entryWaiter = nil
        }
    }

    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { entryWaiter = $0 } }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
