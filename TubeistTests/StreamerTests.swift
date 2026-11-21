//
//  StreamerTests.swift
//  TubeistTests
//

import Foundation
import AVFoundation
import Testing
@testable import Tubeist

private actor CommandOrderRecorder {
    private(set) var entries: [String] = []

    func append(_ entry: String) {
        entries.append(entry)
    }
}

/// Holds a Start preflight or a queued command until the test releases it.
@MainActor
private final class StepGate {
    private var entered = false
    private var released = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func enter() {
        entered = true
        enteredWaiters.forEach { $0.resume() }
        enteredWaiters.removeAll()
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func waitForRelease() async {
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

private actor CaptureStartCounter {
    private(set) var count = 0
    func record() { count += 1 }
}

struct StreamerTests {
    @Test @MainActor
    func settingsRejectsQueuedStartBeforePreparingAnyMedia() async throws {
        let app = AppState()
        let actor = StreamingActor()
        let streamer = Streamer(streamingActor: actor)
        await streamer.setAppState(app)
        app.isSettingsPresented = true
        await #expect(throws: StreamStartError.settingsPresented) {
            try await streamer.startStream(streamID: "settings-test")
        }
        await #expect(throws: StreamStartError.settingsPresented) {
            try await actor.beginPreparing()
        }
        await #expect(throws: CancellationError.self) {
            try await streamer.startSessions()
        }
        #expect(await actor.sessionState() == .idle)
        #expect(app.activitySession == nil)
        app.isSettingsPresented = false
        try await actor.beginPreparing()
        #expect(app.isStreamSessionRunning)
    }

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
    func temporaryCameraInterruptionsDoNotStopAPreparingOrLiveStream() async throws {
        let app = AppState()
        let actor = StreamingActor()
        let streamer = Streamer(streamingActor: actor)
        await streamer.setAppState(app)
        try await actor.beginPreparing()
        await streamer.handleCaptureSessionInterruption(reason: 1)
        #expect(await actor.sessionState() == .preparing)
        try await actor.markLive()
        // Delivery can be delayed until the app is active again. The OS reason
        // must still be treated as a temporary pause, never a fatal failure.
        for reason in [1, 2, 3, 4, 5] {
            await streamer.handleCaptureSessionInterruption(reason: reason)
            #expect(await actor.sessionState() == .live)
            #expect(app.activeAlert == nil)
        }
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

    @Test @MainActor func delayedCaptureTimeoutCannotStopTheNextSession() async throws {
        let actor = StreamingActor()
        let streamer = Streamer(streamingActor: actor)
        let appState = AppState()
        await streamer.setAppState(appState)

        let oldSessionID = UUID()
        try await actor.beginPreparing(sessionID: oldSessionID)
        try await actor.markLive()
        #expect(await actor.beginStopping())
        await actor.completeStop()

        try await actor.beginPreparing(sessionID: UUID())
        try await actor.markLive()
        await streamer.handleRuntimeFailure(CaptureContinuityError.stalled, sessionID: oldSessionID)

        #expect(appState.streamSessionState == .live)
        #expect(appState.activeAlert == nil)
    }

    @Test @MainActor func captureSamplesKeepTheirOwnerThroughStopAndRestart() async throws {
        let actor = StreamingActor()
        let streamer = Streamer(streamingActor: actor)
        let appState = AppState()
        await streamer.setAppState(appState)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let pcm = try AACTestAudio.pcm(format, frames: 1024, pts: 100) { _, _ in 0 }
        func capture() -> SendableSampleBuffer { SendableSampleBuffer(capturing: pcm, from: streamer) }

        let first = UUID(), second = UUID()
        try await actor.beginPreparing(sessionID: first)
        let preview = capture()
        #expect(preview.sessionID == nil)
        try await actor.markLive()
        let queued = capture()
        #expect(await actor.beginStopping())
        #expect(capture().sessionID == first)
        await actor.closeMediaIntake()
        #expect(capture().sessionID == nil)
        await actor.completeStop()
        try await actor.beginPreparing(sessionID: second)
        try await actor.markLive()
        #expect(capture().sessionID == second)
        #expect(preview.sessionID == nil)
        let failedOwner = try #require(queued.sessionID)
        #expect(failedOwner == first)
        await streamer.handleRuntimeFailure(CaptureContinuityError.invalidTiming, sessionID: failedOwner)
        #expect(appState.streamSessionState == .live)
        #expect(appState.activeAlert == nil)
    }

    // Independent of the simulator's saved Stream and Record settings.
    private static let recordingOnly = StreamOutputPlan(streamsToYouTube: false, recordsLocally: true)

    @Test(.timeLimit(.minutes(1))) @MainActor func stopDuringPreflightCancelsStartBeforeItGoesLive() async throws {
        let app = AppState()
        let actor = StreamingActor()
        let gate = StepGate()
        let streamer = Streamer(streamingActor: actor, outputPlan: { Self.recordingOnly }, outputPreflight: { _, _, _ in
            await gate.enter()
            // A slow YouTube setup. Stop must cancel it rather than wait.
            try await Task.sleep(for: .seconds(60))
            return ("unused", nil)
        })
        await streamer.setAppState(app)
        let start = Task { try await streamer.startStream(streamID: "stop-during-preflight") }
        await gate.waitUntilEntered()
        #expect(app.streamSessionState == .preparing)

        let stop = try await streamer.endStream()
        // Start cleaned up; the queued Stop found nothing left to stop.
        #expect(stop.outcome == .alreadyIdle)
        await #expect(throws: StreamStartError.stoppedDuringPreparation) { try await start.value }
        #expect(await actor.sessionState() == .idle)
        #expect(app.streamSessionState == .idle)
        #expect(app.activitySession?.startedAt == nil)
        #expect(app.activeAlert == nil)

        // The request belonged to that session only.
        try await actor.beginPreparing()
        try await actor.markLive()
        #expect(app.streamSessionState == .live)
    }

    @Test(.timeLimit(.minutes(1))) @MainActor func preflightFinishingAfterStopDoesNotGoLive() async throws {
        let app = AppState()
        let actor = StreamingActor()
        let gate = StepGate()
        let streamer = Streamer(streamingActor: actor, outputPlan: { Self.recordingOnly }, outputPreflight: { _, _, _ in
            await gate.enter()
            await gate.waitForRelease() // Ignores cancellation.
            return ("unused", nil)
        })
        await streamer.setAppState(app)
        let start = Task { try await streamer.startStream(streamID: "preflight-after-stop") }
        await gate.waitUntilEntered()
        let stop = Task { try await streamer.endStream() }
        while await !actor.wasStopRequestedDuringPreparation() { await Task.yield() }
        gate.release()

        await #expect(throws: StreamStartError.stoppedDuringPreparation) { try await start.value }
        #expect(try await stop.value.outcome == .alreadyIdle)
        #expect(app.streamSessionState == .idle)
        #expect(app.activitySession?.startedAt == nil)
        #expect(app.activeAlert == nil)
    }

    @Test(.timeLimit(.minutes(1))) @MainActor func streamOnlyStopWithoutDeliveredMediaReportsAFailure() async throws {
        let app = AppState()
        let actor = StreamingActor()
        let streamer = Streamer(streamingActor: actor)
        await streamer.setAppState(app)
        try await actor.beginPreparing()
        await actor.setOutputPlan(StreamOutputPlan(streamsToYouTube: true, recordsLocally: false))
        try await actor.markLive()
        // Nothing reached YouTube, as when Stop comes before the first microphone
        // sample: the encoders and uploader finish cleanly with zero segments.
        do {
            _ = try await streamer.endStream(resumePreviewAfterStop: false, shutdownTimeout: 5)
            Issue.record("A stream that delivered no media must not stop successfully")
        } catch let error as StreamShutdownError {
            #expect(error.report.outcome == .stopped)
            #expect(error.report.youTubeUpload == .failed(ShutdownComponentStatus.noYouTubeMediaDelivered))
        }
        guard case .failed(let message) = app.streamSessionState else {
            Issue.record("Expected a failed session, found \(app.streamSessionState)")
            return
        }
        #expect(message.contains(ShutdownComponentStatus.noYouTubeMediaDelivered))
    }

    @Test @MainActor func stopRequestedWhilePreparingPreventsLive() async throws {
        let app = AppState()
        let actor = StreamingActor()
        await actor.setAppState(app)
        try await actor.beginPreparing()
        await actor.requestStop()
        await #expect(throws: StreamStartError.stoppedDuringPreparation) { try await actor.markLive() }
        #expect(await actor.sessionState() == .preparing)
        #expect(actor.captureSessionID == nil)

        // A preflight registered after the request is cancelled at once.
        let cancelled = CaptureStartCounter()
        await actor.setPreflightCancellation { Task { await cancelled.record() } }
        while await cancelled.count == 0 { await Task.yield() }

        // Once live, the request is left to the queued Stop.
        await actor.completeStop()
        try await actor.beginPreparing()
        try await actor.markLive()
        await actor.requestStop()
        #expect(await actor.sessionState() == .live)
        #expect(await !actor.wasStopRequestedDuringPreparation())
    }

    @Test(.timeLimit(.minutes(1))) @MainActor func foregroundCaptureResumesWhileStopDrainsUploads() async throws {
        let app = AppState()
        let actor = StreamingActor()
        let queue = StreamCommandQueue()
        let starts = CaptureStartCounter()
        let streamer = Streamer(streamingActor: actor, commandQueue: queue,
                                startCapture: { await starts.record() })
        await streamer.setAppState(app)
        #expect(StreamSessionState.preparing.keepsCaptureRunning)
        #expect(StreamSessionState.live.keepsCaptureRunning)
        #expect(!StreamSessionState.stopping.keepsCaptureRunning)
        #expect(!StreamSessionState.idle.keepsCaptureRunning)

        // Stop holds the command queue while uploads drain, after it suspended
        // capture in the background. Returning to the app restarts capture
        // before reporting the camera ready, without waiting for that drain.
        try await actor.beginPreparing()
        try await actor.markLive()
        #expect(await actor.beginStopping())
        let drain = StepGate()
        let stop = Task {
            try await queue.run {
                await drain.enter()
                await drain.waitForRelease()
            }
        }
        await drain.waitUntilEntered()
        try await streamer.startSessions()
        #expect(await starts.count == 1)
        drain.release()
        try await stop.value
        await actor.completeStop()

        // Idle startup stays ordered behind other session commands.
        let command = StepGate()
        let other = Task {
            try await queue.run {
                await command.enter()
                await command.waitForRelease()
            }
        }
        await command.waitUntilEntered()
        let resume = Task { try await streamer.startSessions() }
        for _ in 0..<20 { await Task.yield() }
        #expect(await starts.count == 1)
        command.release()
        try await other.value
        try await resume.value
        #expect(await starts.count == 2)
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

    @Test func highlightsOnlyAddMP4PackagingWhenEnabled() throws {
        for (stream, record) in [(true, false), (true, true), (false, true)] {
            for enabled in [false, true] {
                let plan = try StreamOutputPlan.resolve(stream: stream, record: record,
                                                        highlightsEnabled: enabled)
                #expect(plan.highlightsEnabled == enabled)
                #expect(plan.producesMP4Fragments == (record || enabled))
                #expect(plan.recordsLocally == record)
                #expect(plan.remuxesToTransportStream == stream)
            }
        }
        #expect(throws: StreamStartError.noOutputSelected) {
            try StreamOutputPlan.resolve(stream: false, record: false, highlightsEnabled: true)
        }
    }

    @Test @MainActor
    func highlightChoiceIsFrozenInTheSessionOutputPlan() async throws {
        let app = AppState()
        let actor = StreamingActor()
        await actor.setAppState(app)
        try await actor.beginPreparing()
        await actor.setOutputPlan(.init(streamsToYouTube: true, recordsLocally: false, highlightsEnabled: true))
        try await actor.markLive()
        #expect(app.activitySession?.highlightsEnabled == true)
        #expect(await actor.activeOutputPlan()?.highlightsEnabled == true)
        #expect(await actor.beginStopping())
        await actor.completeStop()
        try await actor.beginPreparing()
        await actor.setOutputPlan(.init(streamsToYouTube: true, recordsLocally: false, highlightsEnabled: false))
        try await actor.markLive()
        #expect(app.activitySession?.highlightsEnabled == false)
        #expect(await actor.activeOutputPlan()?.producesMP4Fragments == false)
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
