import Foundation
import Testing
@testable import Tubeist

@MainActor
struct YouTubeShutdownMonitorTests {
    private let target = YouTubeHealthTarget(streamID: "stream", broadcastID: "broadcast", authorizationScope: "account")

    private func health(_ status: String = "noData") -> YouTubeIngestStatus {
        .init(streamStatus: "inactive", healthStatus: .init(status: status,
            lastUpdateTimeSeconds: nil, configurationIssues: []))
    }

    @Test func noDataAndInactiveAreObservationsNotCompletionOrStreamFailures() async {
        let clock = ShutdownObservationClock()
        var logs: [(String, LogLevel)] = []
        let monitor = YouTubeShutdownMonitor(stoppedAt: clock.instant, now: { clock.instant },
            log: { logs.append(($0, $1)) })
        clock.advance(10)
        monitor.endListAcknowledged()
        clock.advance(5)
        await monitor.refresh(target: target, fetchHealth: { _ in health() }, fetchBroadcast: { _ in "live" })
        #expect(!monitor.observedCompletion)
        #expect(logs.contains { $0.0.contains("Stop +15.0s; ENDLIST +5.0s") && $0.0.contains("health=noData") })
        #expect(logs.contains { $0.0.contains("broadcast=live") })
        #expect(!logs.contains { $0.1 == .warning || $0.1 == .error })
    }

    @Test func keepsPollingAfterNaturalCompletionAndPreservesEachObservation() async {
        let clock = ShutdownObservationClock()
        var logs: [(String, LogLevel)] = []
        let monitor = YouTubeShutdownMonitor(stoppedAt: clock.instant, now: { clock.instant },
            log: { logs.append(($0, $1)) })
        var intervals: [Duration] = []
        var healthTargets: [YouTubeHealthTarget] = []
        var broadcastTargets: [YouTubeHealthTarget] = []
        monitor.endListAcknowledged()
        await monitor.run(target: target, fetchHealth: {
            healthTargets.append($0)
            return health()
        }, fetchBroadcast: {
            broadcastTargets.append($0)
            return "complete"
        }, sleep: {
            intervals.append($0)
            if intervals.count == 3 { throw CancellationError() }
            clock.advance(5)
        })
        #expect(monitor.observedCompletion)
        #expect(intervals == Array(repeating: .seconds(5), count: 3))
        #expect(healthTargets == Array(repeating: target, count: 3))
        #expect(broadcastTargets == healthTargets)
        #expect(logs.filter { $0.0.contains("without a Tubeist completion request") }.count == 1)
        let observations = logs.filter { $0.0.contains("health=noData") }.map(\.0)
        #expect(observations.count == 3)
        #expect(Set(observations).count == 3)
    }

    @Test func healthFailureStillAllowsBroadcastObservation() async {
        var logs: [(String, LogLevel)] = []
        let monitor = YouTubeShutdownMonitor(stoppedAt: .now, log: { logs.append(($0, $1)) })
        await monitor.refresh(target: target, fetchHealth: { _ in throw URLError(.timedOut) },
                              fetchBroadcast: { _ in "complete" })
        #expect(monitor.observedCompletion)
        #expect(logs.contains { $0.1 == .warning && $0.0.contains("Health lookup unavailable") })
        #expect(!logs.contains { $0.1 == .error })
    }

    @Test func cancelledObservationCannotLogOrStartAnotherLookup() async {
        var logs: [(String, LogLevel)] = []
        var pending: CheckedContinuation<YouTubeIngestStatus, Never>?
        let monitor = YouTubeShutdownMonitor(stoppedAt: .now, log: { logs.append(($0, $1)) })
        let observation = Task {
            await monitor.refresh(target: target, fetchHealth: { _ in
                await withCheckedContinuation { pending = $0 }
            }, fetchBroadcast: { _ in
                Issue.record("Cancelled observation must not start a broadcast lookup")
                return "complete"
            })
        }
        while pending == nil { await Task.yield() }
        observation.cancel()
        pending?.resume(returning: health())
        await observation.value
        #expect(logs.isEmpty)
        #expect(!monitor.observedCompletion)
    }
}

@MainActor private final class ShutdownObservationClock {
    var instant = ContinuousClock.now
    func advance(_ seconds: Int) { instant = instant.advanced(by: .seconds(seconds)) }
}
