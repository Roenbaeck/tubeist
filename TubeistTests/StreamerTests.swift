//
//  StreamerTests.swift
//  TubeistTests
//

import Foundation
import CoreMedia
import Testing
@testable import Tubeist

private actor CommandOrderRecorder {
    private(set) var entries: [String] = []

    func append(_ entry: String) {
        entries.append(entry)
    }
}

struct StreamerTests {
    @Test @MainActor
    func completionUpdatesOnlyTheStoppingSessionAndClearsItsTarget() async throws {
        let appState = AppState()
        let actor = StreamingActor()
        await actor.setAppState(appState)
        try await actor.beginPreparing()
        let target = YouTubeBroadcastCompletionTarget(id: "session-broadcast", authorizationScope: "scope")
        await actor.setYouTubeBroadcast(id: target.id, status: "live", completionTarget: target)
        try await actor.markLive()
        await actor.confirmYouTubeCompletion(target)
        #expect(appState.youtubeStatus == "live")
        #expect(await actor.beginStopping())
        await actor.confirmYouTubeCompletion(.init(id: "another-broadcast", authorizationScope: "scope"))
        #expect(appState.youtubeStatus == "live")
        await actor.confirmYouTubeCompletion(target)
        #expect(appState.youtubeStatus == "complete")
        await actor.completeStop()
        #expect(await actor.activeYouTubeCompletionTarget() == nil)
        try await actor.beginPreparing()
        appState.youtubeBroadcastId = "next-broadcast"
        appState.youtubeStatus = "ready"
        await actor.confirmYouTubeCompletion(target)
        #expect(appState.youtubeStatus == "ready")
    }

    @Test @MainActor
    func changingTheDisplayedBroadcastDoesNotRetargetShutdown() async throws {
        let appState = AppState()
        let actor = StreamingActor()
        await actor.setAppState(appState)
        try await actor.beginPreparing()
        let target = YouTubeBroadcastCompletionTarget(id: "session-broadcast", authorizationScope: "scope")
        await actor.setYouTubeBroadcast(id: target.id, status: "live", completionTarget: target)
        #expect(await actor.beginStopping())
        appState.youtubeBroadcastId = "different-selection"
        appState.youtubeStatus = "ready"
        #expect(await actor.activeYouTubeCompletionTarget() == target)
        await actor.confirmYouTubeCompletion(target)
        #expect(appState.youtubeStatus == "ready")
    }

    @Test @MainActor
    func idlePreviewInterruptionDoesNotPresentAFatalAlert() async {
        let appState = AppState()
        let streamer = Streamer()
        await streamer.setAppState(appState)

        await streamer.handleCaptureSessionInterruption()

        #expect(appState.activeAlert == nil)
        #expect(appState.streamSessionState == .idle)
    }

    @Test @MainActor
    func stoppedYouTubeUploadsAreReportedOnceAndNotAgainByStop() async throws {
        let actor = StreamingActor()
        let sessionID = UUID()
        await actor.setAppState(AppState())
        let plan = StreamOutputPlan(streamsToYouTube: true, recordsLocally: true)
        #expect(await actor.noteYouTubeUploadFailure("rejected", sessionID: sessionID) == nil) // no session
        try await actor.beginPreparing(sessionID: sessionID)
        await actor.setOutputPlan(plan)
        try await actor.markLive()
        #expect(await actor.noteYouTubeUploadFailure("rejected", sessionID: sessionID) == plan)
        #expect(await actor.noteYouTubeUploadFailure("rejected again", sessionID: sessionID) == nil)
        #expect(await actor.beginStopping())
        // Stop sees that the failure was already surfaced.
        #expect(await actor.reportedYouTubeUploadFailure() == "rejected")
        await actor.closeMediaIntake()
        await actor.completeStop()
        #expect(await actor.reportedYouTubeUploadFailure() == nil)

        // A rejection first seen while stopping is left for Stop to report.
        try await actor.beginPreparing(sessionID: sessionID)
        await actor.setOutputPlan(StreamOutputPlan(streamsToYouTube: true, recordsLocally: false))
        try await actor.markLive()
        #expect(await actor.beginStopping())
        #expect(await actor.noteYouTubeUploadFailure("rejected during stop", sessionID: sessionID) == nil)
        #expect(await actor.reportedYouTubeUploadFailure() == nil)
        await actor.completeStop()

        // Recording-only sessions have no YouTube uploads to report.
        try await actor.beginPreparing(sessionID: sessionID)
        await actor.setOutputPlan(StreamOutputPlan(streamsToYouTube: false, recordsLocally: true))
        try await actor.markLive()
        #expect(await actor.noteYouTubeUploadFailure("stale", sessionID: sessionID) == nil)
    }

    @Test @MainActor
    func idleSessionIgnoresAStaleYouTubeUploadFailure() async {
        let appState = AppState()
        let streamer = Streamer()
        await streamer.setAppState(appState)
        await streamer.handleYouTubeUploadFailure(YouTubeHLSUploadError.rejected(statusCode: 401), sessionID: UUID())
        #expect(appState.activeAlert == nil)
        #expect(appState.streamSessionState == .idle)
    }

    @Test func delayedUploadFailureCannotStopTheNextSession() async throws {
        let actor = StreamingActor()
        let oldSession = UUID()
        let newSession = UUID()
        let plan = StreamOutputPlan(streamsToYouTube: true, recordsLocally: false)
        try await actor.beginPreparing(sessionID: oldSession)
        await actor.setOutputPlan(plan)
        try await actor.markLive()
        #expect(await actor.beginStopping())
        await actor.completeStop()
        try await actor.beginPreparing(sessionID: newSession)
        await actor.setOutputPlan(plan)
        // Deliver the old callback after the next Start, both before and
        // after it goes live. It must neither stop nor poison the new session.
        #expect(await actor.noteYouTubeUploadFailure("old rejection", sessionID: oldSession) == nil)
        try await actor.markLive()
        #expect(await actor.noteYouTubeUploadFailure("old rejection", sessionID: oldSession) == nil)
        #expect(await actor.reportedYouTubeUploadFailure() == nil)
        #expect(await actor.sessionState() == .live)
        #expect(await actor.noteYouTubeUploadFailure("new rejection", sessionID: newSession) == plan)
    }

    @Test func stabilizedVideoMustReachTheStopTimestamp() {
        let stop = CMTime(value: 900_000, timescale: 90_000)

        #expect(!CaptureTailAlignment.videoHasReached(
            stopTimestamp: stop,
            videoTimestamp: nil
        ))
        #expect(!CaptureTailAlignment.videoHasReached(
            stopTimestamp: stop,
            videoTimestamp: CMTime(value: 899_999, timescale: 90_000)
        ))
        #expect(CaptureTailAlignment.videoHasReached(
            stopTimestamp: stop,
            videoTimestamp: CMTime(value: 10, timescale: 1)
        ))
        #expect(CaptureTailAlignment.videoHasReached(
            stopTimestamp: stop,
            videoTimestamp: CMTime(value: 10_001, timescale: 1_000)
        ))
        #expect(!CaptureTailAlignment.videoHasReached(
            stopTimestamp: .invalid,
            videoTimestamp: stop
        ))
    }

    @Test @MainActor
    func streamStateTransitionsCompleteBeforeTheCallerContinues() async throws {
        let appState = AppState()
        let actor = StreamingActor()
        await actor.setAppState(appState)

        try await actor.beginPreparing()
        #expect(await actor.sessionState() == .preparing)
        #expect(appState.streamSessionState == .preparing)
        #expect(!(await actor.isStreaming()))

        try await actor.markLive()
        #expect(await actor.isStreaming())
        #expect(appState.isStreamActive)
        #expect(appState.streamHealth == .awaiting)

        #expect(await actor.beginStopping())
        #expect(await actor.isStreaming())
        #expect(appState.streamSessionState == .stopping)
        await actor.closeMediaIntake()
        #expect(!(await actor.isStreaming()))
        await actor.completeStop()
        #expect(!appState.isStreamActive)
        #expect(appState.streamSessionState == .idle)
        #expect(appState.streamHealth == .silenced)
    }

    @Test @MainActor
    func youtubePreflightPublishesTheBroadcastUsedByTheSession() async {
        let appState = AppState()
        let actor = StreamingActor()
        await actor.setAppState(appState)

        await actor.setYouTubeBroadcast(
            id: "next-broadcast",
            status: "ready"
        )

        #expect(appState.youtubeBroadcastId == "next-broadcast")
        #expect(appState.youtubeStatus == "ready")
        await actor.completeStop()
        #expect(appState.youtubeBroadcastId == "next-broadcast")
    }

    @Test @MainActor
    func duplicateStartIsRejectedBySessionState() async throws {
        let actor = StreamingActor()
        await actor.setAppState(AppState())
        try await actor.beginPreparing()

        do {
            try await actor.beginPreparing()
            Issue.record("Expected a second prepare to fail")
        } catch let error as StreamSessionError {
            #expect(error == .sessionBusy(.preparing))
        }
    }

    @Test @MainActor
    func stopWhilePreparingOwnsAndFinalizesThePartialSession() async throws {
        let actor = StreamingActor()
        await actor.setAppState(AppState())
        try await actor.beginPreparing()

        #expect(await actor.beginStopping())
        #expect(await actor.sessionState() == .stopping)
        await actor.closeMediaIntake()
        await actor.completeStop()
        #expect(await actor.sessionState() == .idle)
    }

    @Test @MainActor
    func stopAndRestartTransitionsAreIdempotent() async throws {
        let actor = StreamingActor()
        await actor.setAppState(AppState())

        #expect(!(await actor.beginStopping()))
        try await actor.beginPreparing()
        try await actor.markLive()
        #expect(await actor.beginStopping())
        #expect(!(await actor.beginStopping()))

        do {
            try await actor.beginPreparing()
            Issue.record("Expected Start while stopping to fail")
        } catch let error as StreamSessionError {
            #expect(error == .sessionBusy(.stopping))
        }

        await actor.closeMediaIntake()
        await actor.completeStop()
        try await actor.beginPreparing()
        #expect(await actor.sessionState() == .preparing)
    }

    @Test func sessionCommandsDoNotInterleaveAcrossSuspensionPoints() async throws {
        let queue = StreamCommandQueue()
        let recorder = CommandOrderRecorder()
        let first = Task {
            try await queue.run {
                await recorder.append("first-start")
                try await Task.sleep(for: .milliseconds(20))
                await recorder.append("first-end")
                return 1
            }
        }

        while await recorder.entries.isEmpty {
            await Task.yield()
        }

        let second = Task {
            try await queue.run {
                await recorder.append("second-start")
                await recorder.append("second-end")
                return 2
            }
        }

        #expect(try await first.value == 1)
        #expect(try await second.value == 2)
        #expect(await recorder.entries == [
            "first-start",
            "first-end",
            "second-start",
            "second-end",
        ])
    }

    @Test func outputPlanCoversTheYouTubeOnlyRegressionMatrix() throws {
        let cases: [(StreamOutputPlan, Bool, Bool)] = [
            (StreamOutputPlan(streamsToYouTube: false, recordsLocally: true), false, true),
            (StreamOutputPlan(streamsToYouTube: true, recordsLocally: false), true, false),
            (StreamOutputPlan(streamsToYouTube: true, recordsLocally: true), true, true),
        ]

        for (expected, stream, record) in cases {
            let plan = try StreamOutputPlan.resolve(
                stream: stream,
                record: record
            )
            #expect(plan == expected)
            #expect(plan.routesEncodedFragments == stream)
            #expect(plan.remuxesToTransportStream == stream)
        }
    }

    @Test func startingWithoutAnyOutputIsRejected() {
        do {
            _ = try StreamOutputPlan.resolve(
                stream: false,
                record: false
            )
            Issue.record("Expected an empty output plan to fail")
        } catch let error as StreamStartError {
            #expect(error == .noOutputSelected)
        } catch {
            Issue.record("Unexpected output-plan error: \(error)")
        }
    }

    @Test func sameSecondStreamRestartsHaveDistinctSafeIdentifiers() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let firstUUID = try #require(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        let secondUUID = try #require(UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
        let first = Streamer.makeStreamID(
            at: date,
            uuid: firstUUID
        )
        let second = Streamer.makeStreamID(
            at: date,
            uuid: secondUUID
        )

        #expect(first != second)
        #expect(first.hasSuffix("_111111111111"))
        #expect(second.hasSuffix("_222222222222"))
        #expect(first.utf8.allSatisfy {
            ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x5f
        })
    }
}
