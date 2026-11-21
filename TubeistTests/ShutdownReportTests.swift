//
//  ShutdownReportTests.swift
//  TubeistTests
//

import Testing
@testable import Tubeist

struct ShutdownReportTests {
    @Test func successfulStopNamesEveryRequestedComponent() {
        let report = StreamStopResult(
            outcome: .stopped,
            captureIntake: .completed,
            packaging: ContentPackagingShutdownReport(
                mediaEncoding: .completed,
                fragmentDispatch: .completed,
                recording: .completed
            ),
            youTubeUpload: .completed
        )

        #expect(report.succeeded)
        #expect(report.outcome == .stopped)
        #expect(report.packaging.recording == .completed)
        #expect(report.youTubeUpload == .completed)
    }

    @Test func youTubeStopWithoutDeliveredMediaIsNotSuccessful() throws {
        let empty = ShutdownComponentStatus.youTubeUpload(requested: true, finish: YouTubeOutputFinish())
        #expect(empty == .failed(ShutdownComponentStatus.noYouTubeMediaDelivered))
        // Manual ending mode never sends ENDLIST; delivery alone decides.
        let manual = YouTubeOutputFinish(endListAcknowledged: false, deliveredMedia: true)
        #expect(ShutdownComponentStatus.youTubeUpload(requested: true, finish: manual) == .completed)
        let automatic = YouTubeOutputFinish(endListAcknowledged: true, deliveredMedia: true)
        #expect(ShutdownComponentStatus.youTubeUpload(requested: true, finish: automatic) == .completed)
        #expect(ShutdownComponentStatus.youTubeUpload(requested: false, finish: YouTubeOutputFinish()) == .notRequested)

        let report = StreamStopResult(
            outcome: .stopped,
            captureIntake: .completed,
            packaging: ContentPackagingShutdownReport(
                mediaEncoding: .completed, fragmentDispatch: .completed, recording: .notRequested
            ),
            youTubeUpload: empty
        )
        #expect(!report.succeeded)
        let description = try #require(StreamShutdownError(report: report).errorDescription)
        #expect(description == "YouTube upload: No media segment reached YouTube before Stop")
    }

    @Test func failurePreservesAllSinkResultsAndNeverLooksSuccessful() throws {
        let report = StreamStopResult(
            outcome: .stopped,
            captureIntake: .failed("audio drain timed out"),
            packaging: ContentPackagingShutdownReport(
                mediaEncoding: .failed("writer timed out"),
                fragmentDispatch: .completed,
                recording: .failed("disk full")
            ),
            youTubeUpload: .failed("upload deadline expired")
        )
        let error = StreamShutdownError(report: report)
        let description = try #require(error.errorDescription)

        #expect(!report.succeeded)
        #expect(error.report == report)
        #expect(description.contains("Capture intake: audio drain timed out"))
        #expect(description.contains("Media encoding: writer timed out"))
        #expect(description.contains("Local recording: disk full"))
        #expect(description.contains("YouTube upload: upload deadline expired"))
    }

    @Test func alreadyIdleDoesNotPretendAnySinkWasFinalized() {
        let report = StreamStopResult.alreadyIdle

        #expect(report.succeeded)
        #expect(report.outcome == .alreadyIdle)
        #expect(report.captureIntake == .notRequested)
        #expect(report.packaging == .notRequested)
        #expect(report.youTubeUpload == .notRequested)
    }
}
