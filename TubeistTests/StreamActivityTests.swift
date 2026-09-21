import Foundation
import Testing
@testable import Tubeist

struct StreamActivityPolicyTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let preferences = StreamActivityPreferences(detail: .full, alerts: true, recoveryAlerts: true)

    func snapshot(at seconds: Double = 0, phase: StreamActivityPhase = .streaming,
                  problem: Bool = false, healthy: Bool = false, link: StreamActivityLink = .good) -> StreamActivitySnapshot {
        .init(session: .init(id: UUID(), requestedAt: start, startedAt: start, streamsToYouTube: true),
            content: .init(phase: phase, startedAt: start, stoppedAt: phase.isTerminal ? start : nil,
                health: problem ? .error : healthy ? .good : .waiting, healthTracked: true,
                link: link, viewers: nil, bitrateKbps: nil, batteryPercent: nil, thermal: nil, fullDetail: true),
            healthReceivedAt: start.addingTimeInterval(seconds), remoteProblem: problem, remoteHealthy: healthy)
    }

    @Test func oneBadPollNeverBecomesTwoObservations() {
        var policy = StreamActivityPolicy()
        let bad = snapshot(problem: true)
        for elapsed in [0.0, 5, 10, 20, 30, 60, 120, 150] {
            #expect(policy.evaluate(bad, preferences: preferences, now: start.addingTimeInterval(elapsed)).alert == nil)
        }
    }

    @Test func startupWaitingDoesNotAlertAndTwoFreshProblemsDo() {
        var policy = StreamActivityPolicy()
        #expect(policy.evaluate(snapshot(), preferences: preferences, now: start).alert == nil)
        #expect(policy.evaluate(snapshot(at: 10, healthy: true), preferences: preferences, now: start.addingTimeInterval(10)).alert == nil)
        #expect(policy.evaluate(snapshot(at: 30, problem: true), preferences: preferences, now: start.addingTimeInterval(30)).alert == nil)
        #expect(policy.evaluate(snapshot(at: 40, problem: true), preferences: preferences, now: start.addingTimeInterval(40)).alert == .problem)
        #expect(policy.evaluate(snapshot(at: 50, problem: true), preferences: preferences, now: start.addingTimeInterval(50)).alert == nil)
        #expect(policy.evaluate(snapshot(at: 60, healthy: true), preferences: preferences, now: start.addingTimeInterval(60)).alert == .recovered)
    }

    @Test func staleOrFailedHealthChecksResetPendingAlerts() {
        for failed in [false, true] {
            var policy = StreamActivityPolicy()
            let first = snapshot(problem: true)
            _ = policy.evaluate(first, preferences: preferences, now: start)
            _ = policy.evaluate(failed ? snapshot(at: 20) : first, preferences: preferences, now: start.addingTimeInterval(130))
            #expect(policy.evaluate(snapshot(at: 140, problem: true), preferences: preferences, now: start.addingTimeInterval(140)).alert == nil)
            #expect(policy.evaluate(snapshot(at: 150, problem: true), preferences: preferences, now: start.addingTimeInterval(150)).alert == .problem)
        }
    }

    @Test func uploadFailureNeedsPersistenceAndRecoveryCannotHideIt() {
        var policy = StreamActivityPolicy()
        _ = policy.evaluate(snapshot(healthy: true, link: .failed), preferences: preferences, now: start)
        #expect(policy.evaluate(snapshot(at: 10, healthy: true, link: .failed), preferences: preferences, now: start.addingTimeInterval(10)).alert == .problem)
        #expect(policy.evaluate(snapshot(at: 20, healthy: true, link: .failed), preferences: preferences, now: start.addingTimeInterval(20)).alert == nil)
        #expect(policy.evaluate(snapshot(at: 30, healthy: true), preferences: preferences, now: start.addingTimeInterval(30)).alert == .recovered)
    }

    @Test func stoppingNeverRaisesLossOfDataAlert() {
        var policy = StreamActivityPolicy()
        _ = policy.evaluate(snapshot(problem: true), preferences: preferences, now: start)
        #expect(policy.evaluate(snapshot(at: 30, phase: .finishing, problem: true), preferences: preferences, now: start.addingTimeInterval(30)).alert == nil)
    }

    @Test func offAndDisabledAlertsRemainSilent() {
        for detail in LiveActivityDetail.allCases {
            var policy = StreamActivityPolicy()
            let settings = StreamActivityPreferences(detail: detail, alerts: false)
            _ = policy.evaluate(snapshot(problem: true), preferences: settings, now: start)
            let result = policy.evaluate(snapshot(at: 30, problem: true), preferences: settings, now: start.addingTimeInterval(30))
            #expect(result.alert == nil)
            if detail == .off { #expect(result.content == nil) }
        }
    }

    @Test func finalizationBypassesThrottleAndUnchangedStatusGetsHeartbeat() {
        var policy = StreamActivityPolicy()
        let live = snapshot(healthy: true)
        #expect(policy.evaluate(live, preferences: preferences, now: start).content != nil)
        #expect(policy.evaluate(live, preferences: preferences, now: start.addingTimeInterval(30)).content == nil)
        #expect(policy.evaluate(live, preferences: preferences, now: start.addingTimeInterval(60)).content != nil)
        #expect(policy.evaluate(snapshot(phase: .finishing), preferences: preferences, now: start.addingTimeInterval(61)).content?.phase == .finishing)
    }

    @Test func presentationRestartPreservesAlertCooldown() {
        var policy = StreamActivityPolicy()
        _ = policy.evaluate(snapshot(problem: true), preferences: preferences, now: start)
        _ = policy.evaluate(snapshot(at: 10, problem: true), preferences: preferences, now: start.addingTimeInterval(10))
        policy.resetPresentation()
        #expect(policy.evaluate(snapshot(at: 20, problem: true), preferences: preferences, now: start.addingTimeInterval(20)).alert == nil)
    }

    @Test func contentRoundTripsAndFormatsLowBitrates() throws {
        let content = snapshot().content
        #expect(try JSONDecoder().decode(StreamActivityAttributes.ContentState.self, from: JSONEncoder().encode(content)) == content)
        #expect(StreamActivityAttributes.ContentState.bitrateLabel(kbps: 750) == "750 kbps")
        #expect(StreamActivityAttributes.ContentState.bitrateLabel(kbps: 12800) == "12.8 Mbps")
    }
}

@MainActor
struct StreamActivitySessionTests {
    @Test func sessionIdentityAndClockSurviveFinishingAndRenewAtNextStart() async throws {
        let app = AppState()
        let actor = StreamingActor()
        await actor.setAppState(app)
        try await actor.beginPreparing()
        await actor.setOutputPlan(.init(streamsToYouTube: false, recordsLocally: true))
        let id = app.activitySession?.id
        #expect(app.activitySnapshot(preferences: .init())?.content.phase == .preparing)
        try await actor.markLive()
        let startedAt = app.activitySession?.startedAt
        #expect(startedAt != nil)
        #expect(app.activitySnapshot(preferences: .init())?.content.phase == .recording)
        #expect(await actor.beginStopping())
        let stoppedAt = app.activitySession?.stoppedAt
        #expect(stoppedAt != nil)
        #expect(app.activitySnapshot(preferences: .init())?.content.phase == .finishing)
        await actor.completeStop()
        #expect(app.activitySession?.id == id)
        #expect(app.activitySession?.startedAt == startedAt)
        #expect(app.activitySession?.stoppedAt == stoppedAt)
        #expect(app.activitySnapshot(preferences: .init())?.content.phase == .ended)
        try await actor.beginPreparing()
        #expect(app.activitySession?.id != id)
        #expect(app.activitySession?.startedAt == nil)
        #expect(app.activitySession?.stoppedAt == nil)
    }

    @Test func snapshotUsesExistingReportsAndTreatsNoDataAsUnknown() async {
        let app = AppState()
        app.setStreamSessionState(.preparing)
        app.setStreamSessionState(.live)
        let target = YouTubeHealthTarget(streamID: "stream", broadcastID: "broadcast", authorizationScope: "scope")
        app.youtubeHealth.configure(target)
        app.streamHealth = .pristine
        await app.youtubeHealth.refresh(target: target, fetch: { _ in
            .init(streamStatus: "active", healthStatus: .init(status: "noData", lastUpdateTimeSeconds: nil, configurationIssues: nil))
        }, notice: { _ in })
        let snapshot = app.activitySnapshot(preferences: .init())
        #expect(snapshot?.remoteProblem == false)
        #expect(snapshot?.viewersTarget == target)
        #expect(snapshot?.content.bitrateKbps == nil)
        #expect(snapshot?.content.batteryPercent == nil)
    }

    @Test func viewerDataExpiresRatherThanShowingStaleAudience() {
        let now = Date()
        #expect(StreamActivityCoordinator.freshViewers(42, receivedAt: now.addingTimeInterval(-119), now: now) == 42)
        #expect(StreamActivityCoordinator.freshViewers(42, receivedAt: now.addingTimeInterval(-121), now: now) == nil)
        #expect(StreamActivityCoordinator.freshViewers(nil, receivedAt: now, now: now) == nil)
    }
}

@MainActor
private final class ActivitySinkSpy: StreamActivitySink {
    var events: [String] = []
    var content: StreamActivityAttributes.ContentState?
    var holdPublish = false
    var publishContinuation: CheckedContinuation<Void, Never>?
    func begin(sessionID: UUID?) async { events.append("begin") }
    func publish(_ content: StreamActivityAttributes.ContentState, alert: StreamActivityAlert?, now: Date) async {
        events.append("publish")
        self.content = content
        if holdPublish {
            holdPublish = false
            await withCheckedContinuation { publishContinuation = $0 }
        }
    }
    func finish(_ content: StreamActivityAttributes.ContentState?, now: Date) async {
        events.append(content == nil ? "remove" : "end")
        self.content = content
    }
}

@MainActor
struct StreamActivityCoordinatorTests {
    private func eventually(_ predicate: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !predicate(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(2)) }
        return predicate()
    }
    @Test func newerRunWaitsForCancelledPublishAndTeardown() async {
        let app = AppState()
        app.setStreamSessionState(.preparing)
        let sink = ActivitySinkSpy()
        sink.holdPublish = true
        let coordinator = StreamActivityCoordinator(sink: sink)
        let first = Task { await coordinator.run(preferences: .init(), read: { app.activitySnapshot(preferences: .init()) },
            fetchViewers: { _ in Issue.record("Standard must not fetch viewers"); return nil }, bitrate: { Issue.record("Standard must not fetch bitrate"); return nil }) }
        #expect(await eventually { sink.publishContinuation != nil })
        first.cancel()
        let next = Task { await coordinator.run(preferences: .init(), read: { app.activitySnapshot(preferences: .init()) },
            fetchViewers: { _ in nil }, bitrate: { nil }) }
        sink.publishContinuation?.resume()
        sink.publishContinuation = nil
        #expect(await eventually { sink.events.filter { $0 == "begin" }.count == 2 })
        #expect(Array(sink.events.prefix(4)) == ["begin", "publish", "remove", "begin"])
        next.cancel()
        await next.value
        await first.value
        #expect(sink.content == nil)
    }

    @Test func terminalStateIsPublishedAndEndedWithoutPolling() async {
        let app = AppState()
        app.setStreamSessionState(.preparing)
        app.setStreamSessionState(.live)
        app.setStreamSessionState(.stopping)
        app.setStreamSessionState(.idle)
        let sink = ActivitySinkSpy()
        let coordinator = StreamActivityCoordinator(sink: sink)
        await coordinator.run(preferences: .init(detail: .full), read: { app.activitySnapshot(preferences: .init(detail: .full)) },
            fetchViewers: { _ in Issue.record("Ended session must not fetch"); return nil },
            bitrate: { Issue.record("Ended session must not fetch"); return nil })
        #expect(sink.events == ["begin", "publish", "end"])
        #expect(sink.content?.phase == .ended)
        #expect(sink.content?.stoppedAt != nil)
    }

    @Test func offStartsNoTimerAndMakesNoRequests() async {
        let app = AppState()
        app.setStreamSessionState(.preparing)
        let sink = ActivitySinkSpy()
        let coordinator = StreamActivityCoordinator(sink: sink, sleep: { _ in Issue.record("Off must not tick") })
        await coordinator.run(preferences: .init(detail: .off), read: { app.activitySnapshot(preferences: .init(detail: .off)) },
            fetchViewers: { _ in Issue.record("Off must not fetch"); return nil }, bitrate: { Issue.record("Off must not fetch"); return nil })
        #expect(sink.events == ["begin"])
    }
}

extension StreamActivityPolicyTests {
    @Test func manuallyConfiguredStreamCanRecoverWithoutYouTubeHealth() {
        var policy = StreamActivityPolicy()
        var failing = snapshot(link: .failed)
        failing.content.healthTracked = false
        _ = policy.evaluate(failing, preferences: preferences, now: start)
        #expect(policy.evaluate(failing, preferences: preferences, now: start.addingTimeInterval(10)).alert == .problem)
        var recovered = snapshot()
        recovered.content.healthTracked = false
        _ = policy.evaluate(recovered, preferences: preferences, now: start.addingTimeInterval(15))
        #expect(policy.evaluate(recovered, preferences: preferences, now: start.addingTimeInterval(25)).alert == .recovered)
    }

    @Test func failureAlertIsNotRepeatedWhenTheViewRestarts() {
        var policy = StreamActivityPolicy()
        let failed = snapshot(phase: .failed)
        #expect(policy.evaluate(failed, preferences: preferences, now: start).alert == .stopped)
        policy.resetPresentation()
        #expect(policy.evaluate(failed, preferences: preferences, now: start.addingTimeInterval(60)).alert == nil)
    }
}

extension StreamActivityCoordinatorTests {
    @Test func lateBitrateCannotPublishAfterSessionIdentityChanges() async {
        let app = AppState()
        app.setStreamSessionState(.preparing)
        app.activitySession?.streamsToYouTube = true
        app.setStreamSessionState(.live)
        let sink = ActivitySinkSpy()
        let coordinator = StreamActivityCoordinator(sink: sink)
        var pending: CheckedContinuation<Int?, Never>?
        let full = StreamActivityPreferences(detail: .full)
        let running = Task { await coordinator.run(preferences: full, read: { app.activitySnapshot(preferences: full) },
            fetchViewers: { _ in nil }, bitrate: { await withCheckedContinuation { pending = $0 } }) }
        #expect(await eventually { pending != nil })
        app.setStreamSessionState(.idle)
        app.setStreamSessionState(.preparing)
        app.activitySession?.streamsToYouTube = true
        app.setStreamSessionState(.live)
        pending?.resume(returning: 20_000_000)
        await running.value
        #expect(sink.events == ["begin", "remove"])
        #expect(sink.content == nil)
    }

    @Test func cancelledViewerReplyCannotLeakIntoANewSession() async {
        let app = AppState()
        app.setStreamSessionState(.preparing)
        app.activitySession?.streamsToYouTube = true
        app.setStreamSessionState(.live)
        app.youtubeHealth.configure(.init(streamID: "old", broadcastID: "old", authorizationScope: "scope"))
        let sink = ActivitySinkSpy()
        let coordinator = StreamActivityCoordinator(sink: sink)
        var pending: CheckedContinuation<Int?, Never>?
        let full = StreamActivityPreferences(detail: .full)
        let first = Task { await coordinator.run(preferences: full, read: { app.activitySnapshot(preferences: full) },
            fetchViewers: { _ in await withCheckedContinuation { pending = $0 } }, bitrate: { 1_000_000 }) }
        #expect(await eventually { pending != nil })
        first.cancel()
        await first.value
        app.setStreamSessionState(.idle)
        app.setStreamSessionState(.preparing)
        app.activitySession?.streamsToYouTube = true
        app.setStreamSessionState(.live)
        let second = Task { await coordinator.run(preferences: full, read: { app.activitySnapshot(preferences: full) },
            fetchViewers: { _ in Issue.record("New session has no health target"); return nil }, bitrate: { 2_000_000 }) }
        pending?.resume(returning: 999)
        #expect(await eventually { sink.content?.bitrateKbps == 2000 })
        #expect(sink.content?.viewers == nil)
        second.cancel()
        await second.value
    }
}

extension StreamActivityPolicyTests {
    @Test func activityCannotOutliveHealthFreshnessWhenTheAppIsSuspended() {
        var state = snapshot(healthy: true).content
        state.healthValidUntil = start.addingTimeInterval(30)
        #expect(StreamActivityFreshness.deadline(state, now: start) == start.addingTimeInterval(30))
        state.phase = .finishing
        #expect(StreamActivityFreshness.deadline(state, now: start) == start.addingTimeInterval(90))
    }

    @Test func identicalFreshPollDoesNotTriggerAnExtraWatchUpdate() {
        var policy = StreamActivityPolicy()
        var first = snapshot(healthy: true)
        first.content.healthValidUntil = start.addingTimeInterval(120)
        _ = policy.evaluate(first, preferences: preferences, now: start)
        var next = snapshot(at: 10, healthy: true)
        next.content.healthValidUntil = start.addingTimeInterval(130)
        #expect(policy.evaluate(next, preferences: preferences, now: start.addingTimeInterval(10)).content == nil)
    }
}
