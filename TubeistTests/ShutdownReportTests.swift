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
                assetWriter: .completed,
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

    @Test func failurePreservesAllSinkResultsAndNeverLooksSuccessful() throws {
        let report = StreamStopResult(
            outcome: .stopped,
            captureIntake: .failed("audio drain timed out"),
            packaging: ContentPackagingShutdownReport(
                assetWriter: .failed("writer timed out"),
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
        #expect(description.contains("Media writer: writer timed out"))
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
