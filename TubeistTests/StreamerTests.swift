//
//  StreamerTests.swift
//  TubeistTests
//

import Foundation
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

        await actor.setYouTubeBroadcast(id: "next-broadcast", status: "ready")

        #expect(appState.youtubeBroadcastId == "next-broadcast")
        #expect(appState.youtubeStatus == "ready")
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
            (StreamOutputPlan(streamsToYouTube: false, recordsOriginalFMP4: true), false, true),
            (StreamOutputPlan(streamsToYouTube: true, recordsOriginalFMP4: false), true, false),
            (StreamOutputPlan(streamsToYouTube: true, recordsOriginalFMP4: true), true, true),
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
