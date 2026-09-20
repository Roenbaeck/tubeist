//
//  StreamActivityLifecycleTests.swift
//  TubeistTests
//
//  Covers the session clock the Live Activity's elapsed timer runs from, and the
//  coordinator's start/stop ordering: nothing may reach the Live Activity after a
//  stop, and the activity must only be ended once the tick loop is out.
//

import Foundation
import Testing
@testable import Tubeist

@MainActor
struct StreamStartedAtTests {
    @Test("Going live stamps the session start")
    func stampsSessionStart() {
        let appState = AppState()
        #expect(appState.streamStartedAt == nil)
        appState.setStreamSessionState(.preparing)
        #expect(appState.streamStartedAt == nil)
        appState.setStreamSessionState(.live)
        #expect(appState.streamStartedAt != nil)
    }

    @Test("Re-entering live keeps the original session start")
    func keepsOriginalSessionStart() {
        let appState = AppState()
        appState.setStreamSessionState(.live)
        let first = appState.streamStartedAt
        appState.setStreamSessionState(.stopping)
        appState.setStreamSessionState(.live)
        #expect(appState.streamStartedAt == first)
    }

    @Test("Ending or failing the session clears the start")
    func clearsSessionStart() {
        let idle = AppState()
        idle.setStreamSessionState(.live)
        idle.setStreamSessionState(.idle)
        #expect(idle.streamStartedAt == nil)

        let failed = AppState()
        failed.setStreamSessionState(.live)
        failed.setStreamSessionState(.failed("boom"))
        #expect(failed.streamStartedAt == nil)
        #expect(failed.streamHealth == .unusable)
        #expect(failed.activeAlert == "boom")
    }
}

/// Records what the coordinator asks of the Live Activity, in order, and models the
/// bit of the real controller that matters here: `apply` may (re)create the activity,
/// `end` tears it down. An apply that lands after an end therefore leaves an activity
/// behind that nothing will ever end — the defect this guards against.
@MainActor
private final class SinkSpy: StreamActivitySink {
    enum Event: Equatable { case apply, end }

    private(set) var events: [Event] = []
    private(set) var hasActivity = false
    private(set) var applyStarted = false
    /// Holds `apply` open so a `stop()` can land while the loop is mid-iteration.
    /// Deliberately not `Task.sleep`, which cancellation would cut short.
    var applyStall: Int?

    func apply(_ decision: StreamActivityPolicy.Decision, streamStartedAt: Date, now: Date) async {
        applyStarted = true
        if let applyStall {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(applyStall)) {
                    continuation.resume()
                }
            }
        }
        events.append(.apply)
        hasActivity = true
    }

    func end() async {
        events.append(.end)
        hasActivity = false
    }
}

@MainActor
@Suite(.serialized)
struct StreamActivityCoordinatorLifecycleTests {
    /// Runs `body` with the Live Activity settings the loop needs, restoring them after.
    /// `alertOnBadHealth` stays off so the loop never asks for notification permission.
    private func withLiveActivitySettings(_ body: () async -> Void) async {
        let detail = Settings.liveActivityDetail
        let onBad = Settings.alertOnBadHealth
        let onRecovery = Settings.alertOnRecovery
        Settings.liveActivityDetail = .standard
        Settings.alertOnBadHealth = false
        Settings.alertOnRecovery = false
        await body()
        Settings.liveActivityDetail = detail
        Settings.alertOnBadHealth = onBad
        Settings.alertOnRecovery = onRecovery
    }

    /// Spins the main actor until `condition` holds, or gives up after ~2 s.
    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func liveAppState() -> AppState {
        let appState = AppState()
        appState.setStreamSessionState(.live)
        return appState
    }

    @Test("A stop during an in-flight update still ends last, leaving no activity behind")
    func stopEndsAfterTheLoopAndNothingFollows() async {
        await withLiveActivitySettings {
            let spy = SinkSpy()
            spy.applyStall = 50
            let coordinator = StreamActivityCoordinator(controller: spy)
            coordinator.start(appState: liveAppState(), youtubeService: YouTubeService(tokenStore: NoTokenStore()))

            // Stop while the loop is parked inside apply, which is where a cancelled
            // poll used to let an update slip past the teardown.
            #expect(await waitUntil { spy.applyStarted })
            coordinator.stop()

            #expect(await waitUntil { spy.events.last == .end })
            let afterEnd = spy.events
            // Give a loop that ignored cancellation time to push one more update.
            try? await Task.sleep(for: .milliseconds(100))
            #expect(spy.events == afterEnd)
            #expect(spy.events == [.apply, .end])
            #expect(spy.hasActivity == false)
        }
    }

    @Test("Stop is idempotent and ends the Live Activity only once")
    func stopIsIdempotent() async {
        await withLiveActivitySettings {
            let spy = SinkSpy()
            let coordinator = StreamActivityCoordinator(controller: spy)
            coordinator.start(appState: liveAppState(), youtubeService: YouTubeService(tokenStore: NoTokenStore()))

            #expect(await waitUntil { spy.events.contains(.apply) })
            coordinator.stop()
            coordinator.stop()
            coordinator.stop()

            #expect(await waitUntil { spy.events.last == .end })
            try? await Task.sleep(for: .milliseconds(100))
            #expect(spy.events.filter { $0 == .end }.count == 1)
            #expect(spy.hasActivity == false)
        }
    }

    @Test("A restart runs after the previous teardown, never before it")
    func restartWaitsForThePreviousTeardown() async {
        await withLiveActivitySettings {
            let spy = SinkSpy()
            let coordinator = StreamActivityCoordinator(controller: spy)
            let appState = liveAppState()
            let service = YouTubeService(tokenStore: NoTokenStore())
            coordinator.start(appState: appState, youtubeService: service)

            #expect(await waitUntil { spy.events.contains(.apply) })
            coordinator.stop()
            coordinator.start(appState: appState, youtubeService: service)

            // The restarted loop must push again, and only after the end.
            #expect(await waitUntil { spy.events.last == .apply && spy.events.contains(.end) })
            let endIndex = spy.events.firstIndex(of: .end)
            #expect(endIndex != nil)
            #expect(spy.events[(endIndex ?? 0)...].contains(.apply))

            coordinator.stop()
            _ = await waitUntil { spy.events.last == .end }
        }
    }

    @Test("Live Activity off with alerts off starts no loop at all")
    func detailOffWithoutAlertsDoesNothing() async {
        let detail = Settings.liveActivityDetail
        let onBad = Settings.alertOnBadHealth
        Settings.liveActivityDetail = .off
        Settings.alertOnBadHealth = false

        let spy = SinkSpy()
        let coordinator = StreamActivityCoordinator(controller: spy)
        coordinator.start(appState: liveAppState(), youtubeService: YouTubeService(tokenStore: NoTokenStore()))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(spy.events.isEmpty)

        Settings.liveActivityDetail = detail
        Settings.alertOnBadHealth = onBad
    }
}

/// A token store that never reaches the keychain; the coordinator tests never poll.
private struct NoTokenStore: YouTubeTokenStoring {
    var accessToken: String? { nil }
    var refreshToken: String? { nil }
    var expiry: Date? {
        get { nil }
        set { }
    }

    func setAccessToken(_ value: String?) throws {}
    func setRefreshToken(_ value: String?) throws {}
    func clearAuthorization() throws {}
}
