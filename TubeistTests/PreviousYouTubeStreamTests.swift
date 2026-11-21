//
//  PreviousYouTubeStreamTests.swift
//  TubeistTests
//

import Foundation
import Testing
@testable import Tubeist

@MainActor
private final class StatusRequests {
    private(set) var broadcastIDs: [String] = []
    func record(_ id: String) { broadcastIDs.append(id) }
}

@MainActor
struct PreviousYouTubeStreamTests {
    private func cachedLiveBroadcast(_ status: String? = "live", id: String? = "previous") -> AppState {
        let app = AppState()
        app.youtubeStatus = status
        app.youtubeBroadcastId = id
        return app
    }

    @Test func statusThatDoesNotBlockStartIsNotRechecked() async {
        let app = cachedLiveBroadcast("complete")
        let requests = StatusRequests()
        let active = await PreviousYouTubeStream.isStillActive(appState: app) { id in
            requests.record(id)
            return "live"
        }
        #expect(!active)
        #expect(requests.broadcastIDs.isEmpty)
    }

    @Test func statusWithoutItsBroadcastKeepsRefusing() async {
        let app = cachedLiveBroadcast(id: nil)
        let requests = StatusRequests()
        let active = await PreviousYouTubeStream.isStillActive(appState: app) { id in
            requests.record(id)
            return nil
        }
        #expect(active)
        #expect(requests.broadcastIDs.isEmpty)
    }

    @Test(arguments: ["complete", "ready", "revoked", nil] as [String?])
    func broadcastThatYouTubeEndedNoLongerBlocksStart(current: String?) async {
        let app = cachedLiveBroadcast()
        let requests = StatusRequests()
        let active = await PreviousYouTubeStream.isStillActive(appState: app) { id in
            requests.record(id)
            return current
        }
        #expect(!active)
        #expect(requests.broadcastIDs == ["previous"])
        #expect(app.youtubeStatus == current)
        #expect(app.youtubeBroadcastId == "previous")
    }

    @Test(arguments: ["live", "testing"])
    func broadcastStillOnAirKeepsRefusing(current: String) async {
        let app = cachedLiveBroadcast("testing")
        let active = await PreviousYouTubeStream.isStillActive(appState: app) { _ in current }
        #expect(active)
        #expect(app.youtubeStatus == current)
    }

    @Test func unreachableYouTubeLeavesTheDecisionToStartsPreflight() async {
        let app = cachedLiveBroadcast()
        let active = await PreviousYouTubeStream.isStillActive(appState: app) { _ in
            throw URLError(.notConnectedToInternet)
        }
        #expect(!active)
        #expect(app.youtubeStatus == "live")
    }

    @Test func slowAnswerIsBoundedEvenIfTheRequestIgnoresCancellation() async {
        let app = cachedLiveBroadcast()
        let clock = ContinuousClock()
        let started = clock.now
        let active = await PreviousYouTubeStream.isStillActive(appState: app, timeout: .milliseconds(100)) { _ in
            try? await Task.sleep(for: .seconds(2))
            return "complete"
        }
        #expect(!active)
        #expect(started.duration(to: clock.now) < .seconds(1))
        // A late answer must not overwrite the status afterwards.
        #expect(app.youtubeStatus == "live")
    }

    @Test func newerStatusFromAnotherRefreshIsNotOverwritten() async {
        let app = cachedLiveBroadcast()
        let active = await PreviousYouTubeStream.isStillActive(appState: app) { _ in
            // A poll for a different broadcast finished while this one waited.
            app.youtubeBroadcastId = "next"
            app.youtubeStatus = "ready"
            return "live"
        }
        #expect(!active)
        #expect(app.youtubeBroadcastId == "next")
        #expect(app.youtubeStatus == "ready")
    }
}
