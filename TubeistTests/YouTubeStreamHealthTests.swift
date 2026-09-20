import Foundation
import Testing
@testable import Tubeist

struct YouTubeStreamHealthTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func report(stream: String? = "active", health: String? = "good", timestamp: Double? = nil,
                        severity: String? = nil) -> YouTubeIngestStatus {
        .init(streamStatus: stream, healthStatus: .init(status: health,
            lastUpdateTimeSeconds: timestamp, configurationIssues: severity.map {
                [.init(type: "noAudioStream", severity: $0, reason: "Check audio", description: "Audio is missing")]
            }))
    }

    private func assess(_ report: YouTubeIngestStatus?, elapsed: Double = 70, received: Double? = 70) -> YouTubeHealthAssessment {
        .evaluate(report, startedAt: start, receivedAt: received.map { start.addingTimeInterval($0) },
                  now: start.addingTimeInterval(elapsed))
    }

    @Test func mapsYouTubeStatesWithoutClaimingNoDataMeansNoVideo() {
        #expect(assess(report()).kind == .good)
        #expect(assess(report(health: "ok")).kind == .warning)
        #expect(assess(report(health: "bad")).kind == .error)
        #expect(assess(report(stream: "error")).kind == .error)
        #expect(assess(report(health: "good", severity: "error")).kind == .error)
        #expect(assess(report(severity: "warning")).kind == .warning)
        #expect(assess(report(severity: "new-severity")).kind == .warning)
        #expect(assess(report(severity: "info")).kind == .good)
        #expect(assess(report(health: "noData"), elapsed: 20, received: 20).kind == .waiting)
        #expect(assess(report(health: "noData")).kind == .unknown)
        #expect(assess(report(health: "noData")).message.contains("receiving"))
        #expect(assess(report(stream: "inactive")).kind == .unknown)
        #expect(assess(report(stream: "inactive"), elapsed: 10, received: 10).kind == .waiting)
        #expect(assess(report(health: "future-value")).kind == .unknown)
        #expect(assess(nil, received: nil).kind == .unknown)
    }

    @Test func previousSessionAndStaleReportsCannotTurnTheIndicatorRedOrGreen() {
        for health in ["good", "bad"] {
            #expect(assess(report(health: health, timestamp: start.timeIntervalSince1970 - 20)).kind == .unknown)
            #expect(assess(report(health: health), elapsed: 200, received: 70).kind == .unknown)
            #expect(assess(report(health: health, timestamp: start.timeIntervalSince1970 + 30), elapsed: 170, received: 170).kind == .unknown)
            #expect(assess(report(health: health, timestamp: start.timeIntervalSince1970 + 300)).kind == .unknown)
        }
        #expect(assess(report(health: "bad", timestamp: start.timeIntervalSince1970 + 60)).kind == .error)
    }

    @Test func remoteHealthNeverMasksLocalFailures() {
        for kind in [YouTubeHealthAssessment.Kind.waiting, .unknown, .good, .warning, .error] {
            let assessment = YouTubeHealthAssessment(kind: kind, message: "test")
            #expect(assessment.combining(.unusable) == .unusable)
            #expect(assessment.combining(.silenced) == .silenced)
        }
        #expect(assess(report()).combining(.degraded) == .degraded)
        #expect(assess(report(health: "bad")).combining(.pristine) == .unusable)
        #expect(assess(report(health: "ok")).combining(.pristine) == .degraded)
    }

    @Test @MainActor func logsChangesOnceAndReportsRecovery() async {
        let clock = HealthTestClock(start)
        var logs: [(String, LogLevel)] = []
        var notices: [String] = []
        let monitor = YouTubeStreamHealthMonitor(now: { clock.now }, log: { logs.append(($0, $1)) })
        let target = target()
        monitor.configure(target)
        let bad = report(health: "bad", severity: "error")
        await monitor.refresh(target: target, fetch: { _ in bad }, notice: { notices.append($0) })
        let errors = logs.filter { $0.1 == .error }.count
        #expect(errors == 2)
        await monitor.refresh(target: target, fetch: { _ in bad }, notice: { notices.append($0) })
        #expect(logs.filter { $0.1 == .error }.count == errors)
        #expect(notices.count == 1)
        await monitor.refresh(target: target, fetch: { _ in report() }, notice: { notices.append($0) })
        #expect(monitor.assessment.kind == .good)
        #expect(logs.contains { $0.1 == .info && $0.0.contains("healthy") })
        clock.now = start.addingTimeInterval(130)
        #expect(monitor.assessment.kind == .unknown)
    }

    @Test @MainActor func lookupFailuresAreWarningsAndBackOffWithoutStoppingUploads() async {
        let clock = HealthTestClock(start)
        var logs: [(String, LogLevel)] = []
        let monitor = YouTubeStreamHealthMonitor(now: { clock.now }, log: { logs.append(($0, $1)) })
        let target = target()
        monitor.configure(target)
        #expect(monitor.pollingInterval == 10)
        await monitor.refresh(target: target, fetch: { _ in report() }, notice: { _ in })
        clock.now = start.addingTimeInterval(121)
        await monitor.refresh(target: target, fetch: { _ in report() }, notice: { _ in })
        #expect(monitor.pollingInterval == 60)
        for _ in 0..<5 {
            await monitor.refresh(target: target, fetch: { _ in throw URLError(.timedOut) }, notice: { _ in })
        }
        #expect(monitor.target == target)
        #expect(monitor.assessment.kind == .unknown)
        #expect(monitor.pollingInterval == 300)
        #expect(logs.filter { $0.1 == .warning }.count == 1)
        #expect(!logs.contains { $0.1 == .error })
        await monitor.refresh(target: target, fetch: { _ in report() }, notice: { _ in })
        #expect(monitor.assessment.kind == .good)
        #expect(monitor.pollingInterval == 60)
    }

    @Test @MainActor func lateResponseCannotContaminateANewStream() async {
        let monitor = YouTubeStreamHealthMonitor(log: { _, _ in })
        let old = target()
        monitor.configure(old)
        var pending: CheckedContinuation<YouTubeIngestStatus, any Error>?
        let request = Task {
            await monitor.refresh(target: old, fetch: { _ in
                try await withCheckedThrowingContinuation { pending = $0 }
            }, notice: { _ in Issue.record("Old session must not notify") })
        }
        while pending == nil { await Task.yield() }
        let next = target() // Same stream key, different streaming session.
        monitor.configure(next)
        await monitor.refresh(target: next, fetch: { _ in report() }, notice: { _ in })
        pending?.resume(returning: report(health: "bad", severity: "error"))
        await request.value
        #expect(monitor.target == next)
        #expect(monitor.assessment.kind == .good)
    }

    @Test @MainActor func cancellationDoesNotCreateAWarning() async {
        var logs: [(String, LogLevel)] = []
        let monitor = YouTubeStreamHealthMonitor(log: { logs.append(($0, $1)) })
        let target = target()
        monitor.configure(target)
        await monitor.refresh(target: target, fetch: { _ in throw CancellationError() }, notice: { _ in Issue.record("Unexpected notice") })
        #expect(logs.isEmpty)
    }

    @Test @MainActor func appCombinesHealthAndResetsItAtStop() async {
        let app = AppState()
        app.setStreamSessionState(.preparing)
        let target = target()
        app.youtubeHealth.configure(target)
        app.setStreamSessionState(.live)
        await app.youtubeHealth.refresh(target: target, fetch: { _ in report(health: "bad") }, notice: { _ in })
        app.streamHealth = .pristine // The regular metrics timer must not overwrite YouTube's error.
        #expect(app.streamHealth == .unusable)
        app.setStreamSessionState(.stopping)
        #expect(app.youtubeHealth.target == nil)
        app.setStreamSessionState(.idle)
        #expect(app.streamHealth == .silenced)
        app.setStreamSessionState(.preparing)
        app.setStreamSessionState(.live)
        app.streamHealth = .pristine
        #expect(app.streamHealth == .pristine) // No OAuth/recording-only: retain local health.
    }

    private func target() -> YouTubeHealthTarget {
        .init(streamID: "stream", broadcastID: "broadcast", authorizationScope: "account")
    }
}

@MainActor private final class HealthTestClock {
    var now: Date
    init(_ now: Date) { self.now = now }
}
