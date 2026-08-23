//
//  BackgroundExecutionLeaseTests.swift
//  TubeistTests
//

import Testing
import UIKit
@testable import Tubeist

enum BackgroundFinalizationStage: String, CaseIterable, Sendable {
    case captureDrain
    case writerFinish
    case fragmentDispatch
    case recordingFinish
    case youTubeFinish
}

@MainActor
private final class FakeBackgroundTaskManager: BackgroundTaskManaging, @unchecked Sendable {
    let taskIdentifier = UIBackgroundTaskIdentifier(rawValue: 42)
    private(set) var beginCount = 0
    private(set) var endedIdentifiers: [UIBackgroundTaskIdentifier] = []
    private var expirationHandler: (@Sendable () -> Void)?

    func beginTask(
        named name: String,
        expirationHandler: @escaping @Sendable () -> Void
    ) -> UIBackgroundTaskIdentifier {
        beginCount += 1
        self.expirationHandler = expirationHandler
        return taskIdentifier
    }

    func endTask(_ identifier: UIBackgroundTaskIdentifier) {
        endedIdentifiers.append(identifier)
    }

    func expire() {
        expirationHandler?()
        expirationHandler = nil
    }
}

private actor BackgroundLeaseProbe {
    private(set) var startedStage: BackgroundFinalizationStage?
    private(set) var cancelledStage: BackgroundFinalizationStage?
    private(set) var completed = false

    func start(_ stage: BackgroundFinalizationStage) {
        startedStage = stage
    }

    func cancel(_ stage: BackgroundFinalizationStage) {
        cancelledStage = stage
    }

    func complete() {
        completed = true
    }
}

struct BackgroundExecutionLeaseTests {
    @Test(arguments: BackgroundFinalizationStage.allCases)
    @MainActor
    func expirationCancelsEveryFinalizationStage(_ stage: BackgroundFinalizationStage) async throws {
        let manager = FakeBackgroundTaskManager()
        let probe = BackgroundLeaseProbe()
        let lease = BackgroundExecutionLease(manager: manager)

        lease.run(name: "test-\(stage.rawValue)") {
            await probe.start(stage)
            do {
                try await Task.sleep(for: .seconds(30))
                await probe.complete()
            } catch {
                await probe.cancel(stage)
            }
        }

        try await waitUntil { await probe.startedStage == stage }
        #expect(lease.isActive)
        manager.expire()
        try await waitUntil { await probe.cancelledStage == stage }
        try await waitUntil { !lease.isActive }

        #expect(manager.beginCount == 1)
        #expect(manager.endedIdentifiers == [manager.taskIdentifier])
        #expect(!(await probe.completed))
    }

    @Test @MainActor
    func normalCompletionEndsTheLeaseExactlyOnce() async throws {
        let manager = FakeBackgroundTaskManager()
        let probe = BackgroundLeaseProbe()
        let lease = BackgroundExecutionLease(manager: manager)

        lease.run(name: "normal-completion") {
            await probe.complete()
        }
        try await waitUntil { await probe.completed }
        try await waitUntil { !lease.isActive }

        #expect(manager.beginCount == 1)
        #expect(manager.endedIdentifiers == [manager.taskIdentifier])
    }

    @Test @MainActor
    func explicitCancellationEndsTheLeaseAndCancelsPendingWork() async throws {
        let manager = FakeBackgroundTaskManager()
        let probe = BackgroundLeaseProbe()
        let lease = BackgroundExecutionLease(manager: manager)

        lease.run(name: "grace-period") {
            await probe.start(.captureDrain)
            do {
                try await Task.sleep(for: .seconds(30))
                await probe.complete()
            } catch {
                await probe.cancel(.captureDrain)
            }
        }

        try await waitUntil { await probe.startedStage == .captureDrain }
        lease.cancel()
        try await waitUntil { await probe.cancelledStage == .captureDrain }

        #expect(!lease.isActive)
        #expect(manager.beginCount == 1)
        #expect(manager.endedIdentifiers == [manager.taskIdentifier])
        #expect(!(await probe.completed))
    }

    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @MainActor @Sendable () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !(await condition()), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await condition())
    }
}
