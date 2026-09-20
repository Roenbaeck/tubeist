//
//  StreamActivityCoordinatorTests.swift
//  TubeistTests
//

import Foundation
import Testing
@testable import Tubeist

@MainActor
struct StreamActivityCoordinatorTests {
    private func snapshot(
        session: StreamSessionState = .live,
        health: StreamHealth = .pristine,
        youtube: YouTubeStreamHealth = .good,
        healthUpdatedAt: Date? = nil,
        viewers: Int? = nil,
        bitrateKbps: Int? = nil,
        streamId: String? = "stream-1"
    ) -> StreamSnapshot {
        let appState = AppState()
        appState.streamSessionState = session
        appState.streamHealth = health
        appState.youtubeStreamId = streamId
        return StreamActivityCoordinator.snapshot(
            appState: appState,
            health: youtube,
            healthUpdatedAt: healthUpdatedAt,
            viewers: viewers,
            bitrateKbps: bitrateKbps
        )
    }

    @Test("Session state maps onto the Live Activity phase")
    func phaseMapping() {
        #expect(snapshot(session: .preparing).phase == .connecting)
        #expect(snapshot(session: .live).phase == .live)
        #expect(snapshot(session: .stopping).phase == .stopping)
        #expect(snapshot(session: .idle).phase == .ended)
        #expect(snapshot(session: .failed("boom")).phase == .ended)
    }

    @Test("Upload health maps onto link quality and the warning line")
    func linkMapping() {
        let pristine = snapshot(health: .pristine)
        #expect(pristine.link == .good)
        #expect(pristine.warning == nil)

        let degraded = snapshot(health: .degraded)
        #expect(degraded.link == .degraded)
        #expect(degraded.warning == "Upload degraded")

        let unusable = snapshot(health: .unusable)
        #expect(unusable.link == .poor)
        #expect(unusable.warning == "Upload problem")

        for health in [StreamHealth.awaiting, .silenced] {
            let unknown = snapshot(health: health)
            #expect(unknown.link == .unknown)
            #expect(unknown.warning == nil)
        }
    }

    @Test("YouTube health, poll timestamp and full-detail values are carried through")
    func passesThroughPolledValues() {
        let polledAt = Date(timeIntervalSince1970: 1_000_000)
        let result = snapshot(
            youtube: .noData,
            healthUpdatedAt: polledAt,
            viewers: 42,
            bitrateKbps: 4500
        )
        #expect(result.youtubeHealth == .noData)
        #expect(result.healthUpdatedAt == polledAt)
        #expect(result.viewers == 42)
        #expect(result.bitrateKbps == 4500)
    }

    @Test("Health counts as tracked only while a YouTube stream id is bound")
    func healthTrackingFollowsTheBoundStream() {
        // Manual stream key, or not signed in to YouTube: nothing polls health, so
        // the Live Activity must not report it as missing or stale.
        #expect(snapshot(streamId: nil).healthTracked == false)
        #expect(snapshot(streamId: "stream-1").healthTracked == true)
    }

    @Test("The snapshot always carries a thermal reading")
    func reportsThermalState() {
        let expected: ThermalLevel = switch ProcessInfo.processInfo.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .nominal
        }
        #expect(snapshot().thermal == expected)
    }

    @Test("An unavailable battery level is reported as no reading at all")
    func batteryLevelMapping() {
        #expect(StreamActivityCoordinator.batteryPercent(from: -1) == nil)
        #expect(StreamActivityCoordinator.batteryPercent(from: 0) == 0)
        #expect(StreamActivityCoordinator.batteryPercent(from: 0.5) == 50)
        #expect(StreamActivityCoordinator.batteryPercent(from: 1) == 100)
    }

    @Test("Quota rejections back off far longer than ordinary failures")
    func quotaBackoff() {
        #expect(StreamActivityCoordinator.backoff(after: YouTubeError.apiError(403, "quota")) == 300)
        #expect(StreamActivityCoordinator.backoff(after: YouTubeError.apiError(500, "oops")) == 30)
        #expect(StreamActivityCoordinator.backoff(after: YouTubeError.invalidResponse) == 30)
        #expect(StreamActivityCoordinator.backoff(after: URLError(.timedOut)) == 30)
    }
}
