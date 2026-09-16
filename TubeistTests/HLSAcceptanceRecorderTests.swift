//
//  HLSAcceptanceRecorderTests.swift
//  TubeistTests
//

import Foundation
import Testing
@testable import Tubeist

#if DEBUG
struct HLSAcceptanceRecorderTests {
    @Test func writesCompleteSchemaFourReportWithMonotonicElapsedTimes() async throws {
        let sessionIdentifier = "test_\(UUID().uuidString)"
        let documents = try #require(FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first)
        let sessionDirectory = documents
            .appendingPathComponent("TubeistDirectHLSAcceptance", isDirectory: true)
            .appendingPathComponent(sessionIdentifier, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sessionDirectory) }

        let recorder = HLSAcceptanceRecorder()
        await recorder.begin(sessionIdentifier: sessionIdentifier, enabled: true)
        await recorder.initializationParsed()
        await recorder.segmentAccepted(
            sequence: 0,
            duration: 2,
            queuedDuration: 0.25,
            retryCount: 1,
            httpStatus: 202,
            detail: "rate=1.500;pacingWait=0.500;videoTarget=15000000;mediaMbps=15.400"
        )
        await recorder.stopped()

        let reportURL = sessionDirectory.appendingPathComponent("acceptance.jsonl")
        let report = try String(contentsOf: reportURL, encoding: .utf8)
        let events = try report.split(separator: "\n").map { line in
            let object = try JSONSerialization.jsonObject(with: Data(line.utf8))
            return try #require(object as? [String: Any])
        }

        #expect(events.count == 5)
        #expect(events.first?["kind"] as? String == "prepared")
        #expect(events.first?["detail"] as? String == "schema=4")
        #expect(events[2]["kind"] as? String == "segmentAccepted")
        #expect(events[2]["httpStatus"] as? Int == 202)
        #expect(events[2]["queuedDuration"] as? Double == 0.25)
        #expect(events[2]["detail"] as? String == "rate=1.500;pacingWait=0.500;videoTarget=15000000;mediaMbps=15.400")
        #expect(events[3]["kind"] as? String == "stopped")
        #expect(events.last?["kind"] as? String == "summary")
        #expect(events.last?["detail"] as? String == "outcome=stopped;events=4")

        let elapsed = events.compactMap { $0["elapsed"] as? Double }
        #expect(elapsed.count == events.count)
        #expect(elapsed.allSatisfy { $0 >= 0 })
        #expect(zip(elapsed, elapsed.dropFirst()).allSatisfy { $0 <= $1 })
    }
}
#endif
